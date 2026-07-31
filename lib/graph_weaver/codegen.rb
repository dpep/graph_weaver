# typed: true
# frozen_string_literal: true

require "graphql"
require "sorbet-runtime"

# Generates plain, statically-typecheckable Ruby from a GraphQL query +
# schema: nested T::Structs, from_h casting code, and a sig'd execute
# method. The output is source on disk, so srb tc sees the exact result
# type of each query.
#
# Supports queries and mutations; plain fields, inline fragments, named
# fragment spreads (including interface type conditions), union- and
# interface-typed fields (dispatch on __typename), enums (generated
# T::Enum), and typed variables (kwargs on execute). Subscriptions are
# still open.
#
# Split across: codegen/scalar_type.rb (the scalar registry),
# codegen/nodes.rb (the typed IR), codegen/emit.rb (source emission);
# this file holds the public API and the query walk.
require_relative "hints"
require_relative "input_struct"
require_relative "inflect"
require_relative "selection"
require_relative "codegen/enum_type"
require_relative "codegen/scalar_type"
require_relative "codegen/nodes"
require_relative "codegen/emit"

class GraphWeaver::Codegen
  include GraphWeaver::Inflect
  include GraphWeaver::Selection
  include Emit

  attr_reader :module_name

  # A client is anything responding to `execute(query, variables:)`
  # whose result `to_h`s into {"data" => ..., "errors" => ...} — a
  # GraphWeaver::Client, a transport, a schema class, a fake.
  #
  # client: (a constant, or its name as a string) becomes the generated
  # module's baked default; when omitted, generated code falls back to
  # the app default (GraphWeaver.client=). module_name:
  # defaults to the operation's
  # name; default_module_name: is parse's container-scoped fallback (file
  # generation stays strict — a checked-in file deserves a deliberate
  # name). scalars:/enums:/types: are client-scoped overlays consulted
  # before the global registries (ScalarType, EnumType, and arrays of
  # mixin modules, each keyed by GraphQL name). inputs_namespace: is the
  # shared-inputs workflow (see GraphWeaver.generate!): variable types
  # live once in that module and the query module aliases what it uses.
  # unions_namespace:/hoistable_unions: are the parallel shared-unions
  # workflow — a whole-union field spread as a named shared fragment resolves
  # to one canonical type in that module (see used_union_names).
  def initialize(schema:, query:, module_name: nil, client: nil, default_module_name: nil,
    scalars: nil, enums: nil, types: nil, inputs_namespace: nil, unions_namespace: nil,
    hoistable_unions: nil)
    @schema = schema
    @query = query.strip
    @module_name = module_name
    @default_module_name = default_module_name
    @scalars = scalars || {}
    @enums = enums || {}
    @types = types || {}
    @inputs_namespace = inputs_namespace
    # the shared-unions workflow: unions_namespace names the module hoisted
    # unions live in; hoistable_unions is the set of shared fragment names this
    # query may hoist (spreads it inlined, minus any it shadows locally)
    @unions_namespace = unions_namespace
    @hoistable_unions = hoistable_unions || []
    @used_unions = []
    @client_const = self.class.client_const(client)

    if client && @client_const.nil?
      # a live object can't be spelled in generated source — parse can
      # set one via the module's writer, but file generation cannot
      raise ArgumentError, "client: must be a named constant or String (got #{client.inspect}); pass live objects to parse"
    end
  end

  # The constant name a client can be referenced by in generated
  # source — nil when it can't be (live objects, anonymous modules).
  def self.client_const(client)
    case client
    when String then client
    when Module then client.name
    end
  end

  # one-step shorthand
  def self.generate(schema:, query:, module_name: nil, client: nil, scalars: nil, enums: nil, types: nil)
    new(schema:, query:, module_name:, client:, scalars:, enums:, types:).generate
  end

  # Development convenience: generate + eval in one step, no build
  # artifact or checked-in file. Same runtime semantics as the generated
  # file, but invisible to srb tc — use the build step for static typing.
  # Evaluates into an anonymous container, so no global constants leak;
  # client: additionally accepts a live object (set via .client=).
  def self.parse(schema:, query:, module_name: nil, client: nil, scalars: nil, enums: nil, types: nil)
    client_const = client_const(client)

    codegen = new(schema:, query:, module_name:, client: client_const, default_module_name: "Query",
      scalars:, enums:, types:)
    source = codegen.generate

    container = Module.new
    container.module_eval(source, "(graph_weaver)", 1)
    mod = container.const_get(codegen.module_name)
    GraphWeaver.log(:debug) { "parsed #{codegen.module_name} (dynamic module, #{source.bytesize} bytes)" }
    # live objects (or anonymous modules) can't be referenced from
    # generated source — set them via the module's writer instead
    mod.client = client if client && client_const.nil?
    mod
  end

  # The schema-level variable types this query touched, by GraphQL
  # name — the generate! workflow unions these across queries to decide
  # what the shared inputs module must contain.
  def variable_type_names
    { inputs: @variable_inputs.keys, enums: @variable_enums.keys, mapped: @mapped_enums.keys }
  end

  # The shared union fragments this query hoisted, by name — the generate!
  # workflow unions these across queries to decide what the shared unions
  # module must contain.
  def used_union_names = @used_unions.dup

  # The shared inputs artifact: the named input/enum types — plus
  # everything they transitively reference — emitted once per schema as
  # a manifest (inputs.rb) plus one file per type under inputs/, so a
  # schema migration diffs only the types it touched. Returns
  # { relative_filename => source }.
  def self.generate_inputs(schema:, module_name:, input_types: [], enum_types: [],
    scalars: nil, enums: nil, types: nil)
    codegen = new(schema:, query: "", module_name:, scalars:, enums:, types:)
    codegen.generate_inputs(input_types, enum_types)
  end

  def generate_inputs(input_types, enum_types)
    unless @module_name&.match?(/\A[A-Z]\w*(::[A-Z]\w*)*\z/)
      raise ArgumentError, "inputs module name must be a constant name, got #{@module_name.inspect}"
    end

    @variable_enums = {}
    @variable_inputs = {}
    @mapped_enums = {}
    @requires = []

    enum_types.sort.each { |name| variable_core(@schema.get_type(name)) }
    input_types.sort.each { |name| input_node(@schema.get_type(name)) }

    emit_inputs_files
  end

  # The shared unions artifact: each named shared fragment a query hoisted,
  # built once against the schema as <module_name>::<Name>, so the same union
  # across queries resolves to one Ruby type family. `fragments` is the loaded
  # shared-fragment table (nested spreads resolve through it); `names` the
  # fragments to build. Returns { "unions.rb" => source }.
  def self.generate_unions(schema:, module_name:, fragments:, names:,
    scalars: nil, enums: nil, types: nil)
    codegen = new(schema:, query: "", module_name:, scalars:, enums:, types:)
    codegen.generate_unions(fragments, names)
  end

  def generate_unions(fragments, names)
    unless @module_name&.match?(/\A[A-Z]\w*(::[A-Z]\w*)*\z/)
      raise ArgumentError, "unions module name must be a constant name, got #{@module_name.inspect}"
    end

    @requires = []
    @mapped_enums = {}
    # nested spreads inside a shared fragment resolve through the whole table
    @fragments = fragments

    unions = names.uniq.sort.map do |name|
      fragment = fragments.fetch(name)
      type = @schema.get_type(fragment.type.name)
      UnionNode.new(camelize(name), union_members(type, fragment.selections))
    end

    emit_unions_file(unions)
  end

  VarDef = Struct.new(:kwarg, :wire, :node, :required)

  # Names that cannot appear bare in generated Ruby: keywords aren't
  # valid identifiers, and the struct's own generated methods would be
  # silently replaced by a same-named prop reader.
  RUBY_KEYWORDS = %w[
    alias and begin break case class def defined? do else elsif end
    ensure false for if in module next nil not or redo rescue retry
    return self super then true undef unless until when while yield
    BEGIN END __FILE__ __LINE__ __ENCODING__
  ].to_set.freeze
  GENERATED_METHODS = %w[serialize to_h].to_set.freeze

  def generate
    begin
      errors = @schema.validate(@query)
    rescue GraphQL::ParseError => e
      # unparseable queries wrap like invalid ones — everything raised
      # here descends from GraphWeaver::Error
      raise GraphWeaver::ValidationError.new([{ message: e.message, line: nil, column: nil }])
    end
    if errors.any?
      raise GraphWeaver::ValidationError.new(errors.map { |e| validation_detail(e) })
    end

    validate_registrations!

    @variable_enums = {}
    @variable_inputs = {}
    @mapped_enums = {}
    @used_unions = []
    # requires the generated file needs (custom scalars, enum mappings,
    # type helpers all contribute)
    @requires = []

    operation = load_operation(@query)
    root_type = operation_root_type(operation)

    @module_name ||= operation.name || @default_module_name
    unless @module_name
      raise ArgumentError, "module_name: required for anonymous operations"
    end

    # generated source is eval'd by parse — never let a name inject code
    unless @module_name.match?(/\A[A-Z]\w*(::[A-Z]\w*)*\z/)
      raise ArgumentError, "module_name: must be a constant name, got #{@module_name.inspect}"
    end

    variables = operation.variables.map do |var|
      node = ast_type_ref(var.type)
      # a variable is optional when nullable or defaulted; optional kwargs
      # default to nil and are omitted from the wire
      required = node.non_null? && var.default_value.nil?
      kwarg = underscore(var.name)
      # kwargs are declared and forwarded bare in generated source
      if RUBY_KEYWORDS.include?(kwarg)
        raise GraphWeaver::Error,
          "variable $#{var.name} would become the kwarg '#{kwarg}:', which generated code can't declare " \
          "(a Ruby keyword) — rename the variable"
      end
      VarDef.new(kwarg, var.name, node, required)
    end

    root = object_node(root_type, operation.selections, "Result")

    emit_module(root, variables)
  end

  private

  # A client-scoped registration names a type in a specific schema — a
  # typo'd name would otherwise be a silent no-op, the most confusing
  # failure mode available. Called eagerly by Client#register_* when the
  # schema is already loaded, and again at generation (covers clients
  # whose schema introspects lazily). Global registrations skip this:
  # they may target a different client's server.
  def self.validate_registration!(schema, kind, name)
    # register_scalar("Type.field", ...) overrides one field's scalar — validate
    # the field exists and is a scalar, not that a type named "Type.field" exists.
    if kind == "scalar" && name.include?(".")
      return if scalar_field?(schema, name)

      raise GraphWeaver::Error, "register_scalar(#{name.inspect}) matches no scalar field in this schema"
    end

    return if schema.get_type(name)

    suggestion = GraphWeaver.did_you_mean(schema.types.keys, name)
    hint = suggestion ? " — did you mean '#{suggestion}'?" : ""
    # the type registry is reached via extend_type; scalars/enums via register_*
    method = kind == "type" ? "extend_type" : "register_#{kind}"
    raise GraphWeaver::Error, "#{method}(#{name.inspect}) matches no type in this schema#{hint}"
  end

  # Whether `coordinate` ("Type.field") names an existing scalar field — the
  # validation for a per-field register_scalar override.
  def self.scalar_field?(schema, coordinate)
    type_name, field_name = coordinate.split(".", 2)
    return false unless field_name

    field = schema.get_field(type_name, field_name)
    !!field && field.type.unwrap.kind.name == "SCALAR"
  rescue StandardError
    false
  end

  # Parse every fragment file under `paths` into one { name => FragmentDefinition }
  # map — reusable fragments a query can spread. Fragment files hold only
  # fragments (no operations); names are unique across them.
  def self.load_fragments(paths)
    Array(paths).flat_map { |dir| Dir[File.join(dir, "*.graphql")].sort }.each_with_object({}) do |file, out|
      doc = GraphQL.parse(File.read(file))
      if doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).any?
        raise GraphWeaver::Error, "#{file}: fragment files define only fragments, no operations"
      end
      doc.definitions.grep(GraphQL::Language::Nodes::FragmentDefinition).each do |frag|
        raise GraphWeaver::Error, "duplicate shared fragment '#{frag.name}' (#{file})" if out.key?(frag.name)
        out[frag.name] = frag
      end
    end
  end

  # The shared fragments a query spreads (transitively), excluding any it
  # shadows with a local definition of the same name — the names
  # inline_fragments appends, and the set the generate! workflow may hoist
  # when they sit on a whole-union field.
  def self.shared_fragment_spreads(query, shared)
    return [] if shared.empty?

    doc = GraphQL.parse(query)
    local = doc.definitions.grep(GraphQL::Language::Nodes::FragmentDefinition).map(&:name)
    reachable_fragments(fragment_spreads(doc.definitions), shared, local)
  end

  # Append the shared fragments a query spreads (transitively) to its source, so
  # the sent query is self-contained. Unused shared fragments are left out.
  def self.inline_fragments(query, shared)
    used = shared_fragment_spreads(query, shared)
    return query if used.empty?

    "#{query.rstrip}\n\n#{used.sort.map { |name| shared.fetch(name).to_query_string }.join("\n\n")}\n"
  end

  # BFS over spreads, following shared fragments into their own spreads; a
  # locally-defined or unknown spread is left for schema validation to judge.
  def self.reachable_fragments(spreads, shared, local)
    needed = []
    queue = spreads.dup
    until queue.empty?
      name = queue.shift
      next if needed.include?(name) || local.include?(name) || !shared.key?(name)

      needed << name
      queue.concat(fragment_spreads([shared.fetch(name)]))
    end
    needed
  end
  private_class_method :reachable_fragments

  # Names of every fragment spread reachable in these AST nodes.
  def self.fragment_spreads(nodes, acc = [])
    nodes.each do |node|
      acc << node.name if node.is_a?(GraphQL::Language::Nodes::FragmentSpread)
      fragment_spreads(node.selections, acc) if node.respond_to?(:selections)
    end
    acc
  end
  private_class_method :fragment_spreads

  # Structured shape for a schema-validation error: message plus its first
  # source location, so ValidationError#errors is inspectable.
  def validation_detail(error)
    loc = (error.to_h["locations"]&.first if error.respond_to?(:to_h))
    { message: error.message, line: loc && loc["line"], column: loc && loc["column"] }
  end

  def validate_registrations!
    { "enum" => @enums, "scalar" => @scalars, "type" => @types }.each do |kind, registry|
      registry.each_key { |name| self.class.validate_registration!(@schema, kind, name) }
    end
  end


  # Selection#each_field, collected by result key (codegen groups
  # repeated selections of one field so it can merge them)
  def gather(type, selections)
    out = {}
    each_field(type, selections) { |key, node| (out[key] ||= []) << node }
    out
  end

  def object_node(type, selections, class_name)
    node = ObjectNode.new(class_name)
    node.graphql_type = type.graphql_name
    node.mixins = type_mixins(type.graphql_name)
    taken = [class_name]
    # Dedup structurally-identical dispatch-union fields on this struct: the
    # same union selected two ways (unblockOptions vs selectedOption) shares
    # one Ruby type, so consumers get one exhaustive `case ... T.absurd`.
    union_cache = {}

    gather(type, selections).each do |key, field_nodes|
      field_name = field_nodes.first.name
      prop = underscore(key)

      child = if field_name == "__typename"
        NonNull.new(scalar_node("String"))
      else
        field_type = @schema.get_field(type.graphql_name, field_name).type
        sub_selections = field_nodes.flat_map(&:selections)

        case (core = unwrap(field_type)).kind.name
        when "OBJECT"
          name = pick_name(core.graphql_name, key, taken)
          type_ref(field_type) { object_node(core, sub_selections, name) }
        when "UNION", "INTERFACE"
          conditions = concrete_conditions(core, sub_selections)
          bare = bare_fields(sub_selections) - ["__typename"]

          if conditions.empty? && core.kind.name == "INTERFACE"
            # interface-level fields only — every member shares them, so
            # one struct suffices and no __typename dispatch is needed
            name = pick_name(core.graphql_name, key, taken)
            type_ref(field_type) { object_node(core, sub_selections, name) }
          elsif conditions.size == 1 && bare.empty? &&
              (member = @schema.get_type(conditions.first)).kind.name == "OBJECT"
            # a single `... on X` condition: narrow to X's struct — nil
            # when the runtime type doesn't match (narrowing filters).
            # Narrowing reads "no fields came back" as "type didn't
            # match", so a fragment whose every field hides behind
            # @skip/@include would make a real match indistinguishable
            # from a miss ({} either way) — refuse rather than guess.
            unless unconditional_field?(member, sub_selections)
              raise GraphWeaver::Error,
                "narrowed `... on #{member.graphql_name}` needs at least one field not under " \
                "@skip/@include — an all-conditional selection makes a match indistinguishable from nil"
            end

            name = pick_name(member.graphql_name, key, taken)
            nilable_type_ref(field_type) { NarrowedNode.new(object_node(member, sub_selections, name)) }
          elsif @unions_namespace && (frag = lone_shared_spread(sub_selections)) &&
              @hoistable_unions.include?(frag)
            # a whole-union field spread as a named shared fragment: hoist to
            # the shared unions module so the same union across queries is one
            # Ruby type family (one exhaustive `case ... T.absurd`).
            @used_unions << frag unless @used_unions.include?(frag)
            ref = UnionRefNode.new(camelize(frag))
            type_ref(field_type) { ref }
          else
            members = union_members(core, sub_selections)
            # reuse an identical sibling union (pick_name/name only on a miss)
            union = (union_cache[union_signature(members)] ||=
              UnionNode.new(pick_name(core.graphql_name, key, taken), members))
            type_ref(field_type) { union }
          end
        when "ENUM"
          if (mapped = mapped_enum_node(core))
            type_ref(field_type) { mapped }
          else
            name = pick_name(core.graphql_name, key, taken)
            # sorted so output is deterministic across schema sources
            # (SDL round-trips reorder values alphabetically)
            type_ref(field_type) { EnumNode.new(name, core.values.keys.sort) }
          end
        when "SCALAR"
          coordinate = "#{type.graphql_name}.#{field_name}"
          type_ref(field_type) { scalar_node(core.graphql_name, coordinate) }
        else
          raise GraphWeaver::Error, "unsupported kind: #{core.kind.name}"
        end
      end

      # a field under @skip/@include may be absent from the response no
      # matter what the schema says — its type must admit nil
      if field_nodes.any? { |n| n.directives.any? { |d| %w[skip include].include?(d.name) } }
        child = child.of if child.is_a?(NonNull)
      end

      node.fields << ObjectNode::Field.new(prop, key, child)
    end

    node.aliases = resolve_aliases(node)
    node
  end

  # Resolve each registered alias (extend_type alias:) for this struct's type
  # against its actual selection — path -> a typed delegator emitted into the
  # struct body. Validated here, per query, so an unselected or untraversable
  # path fails at generation with a pointed message.
  def resolve_aliases(node)
    type_aliases(node.graphql_type).filter_map do |name, spec|
      resolve_alias(node, name, spec[:segments])
    rescue GraphWeaver::Error
      # an optional alias that doesn't fit this query's selection is simply
      # omitted; a strict one (the default) surfaces the error
      raise unless spec[:optional]
    end
  end

  # Registered aliases for a GraphQL type: global registry plus this client's
  # overlay (client-scoped wins on a name clash).
  def type_aliases(graphql_name)
    global = GraphWeaver::Codegen.type_registry[graphql_name]&.dig(:aliases) || {}
    (global.merge(@types[graphql_name]&.dig(:aliases) || {}))
  end

  ALIAS_RESERVED = (%w[from_h serialize to_h].to_set + RUBY_KEYWORDS).freeze
  # list selectors — pick one element out of a list-typed hop, always nilable
  # (the list may be empty). Everything else is a field prop.
  LIST_SELECTORS = %w[first last].freeze

  # Walk a dotted path through this struct's selected shape, building the
  # delegator expression (`meta&.tag`, `_entities.first&.name`) and its return
  # type. A segment is a field prop, or `first`/`last` to pick a list element.
  # Everything is checked against the node tree: a field on a non-object, a
  # selector on a non-list, or an unselected segment raises. Any nilable hop
  # (a nullable field, or a list element) makes the accessor nilable.
  def resolve_alias(node, name, segments)
    if node.fields.any? { |f| f.prop == name } || ALIAS_RESERVED.include?(name)
      raise GraphWeaver::Error,
        "alias #{name.inspect} on #{node.graphql_type} collides with an existing field or method"
    end

    cur = T.let(node, T.untyped)           # the node the path has reached
    cur_nilable = T.let(false, T::Boolean) # is the expression so far nilable
    nilable = T.let(false, T::Boolean)     # is the accessor overall nilable
    expr = +""

    segments.each do |seg|
      connector = expr.empty? ? "" : (cur_nilable ? "&." : ".")

      if LIST_SELECTORS.include?(seg)
        list = list_of(cur)
        unless list
          raise GraphWeaver::Error,
            "alias #{name.inspect} on #{node.graphql_type}: .#{seg} needs a list, but the path so far isn't one"
        end
        expr << connector << seg
        cur = list.of
        cur_nilable = true # first/last is nil on an empty list
        nilable = true
      else
        obj = object_of(cur)
        unless obj
          hint = list_of(cur) ? " — use .first or .last to pick an element" : ""
          raise GraphWeaver::Error,
            "alias #{name.inspect} on #{node.graphql_type}: '#{seg}' can't be read here (not an object)#{hint}"
        end
        field = obj.fields.find { |f| f.prop == seg }
        unless field
          props = obj.fields.map(&:prop)
          suggestion = GraphWeaver.did_you_mean(props, seg)
          hint = suggestion ? " — did you mean '#{suggestion}'?" : " (have: #{props.join(", ")})"
          raise GraphWeaver::Error,
            "alias #{name.inspect} on #{node.graphql_type}: '#{seg}' is not a selected field#{hint}"
        end
        expr << connector << seg
        cur = field.node
        cur_nilable = !field.node.non_null?
        nilable ||= cur_nilable
      end
    end

    leaf = cur.bare_type
    type = nilable && leaf != "T.untyped" ? "T.nilable(#{leaf})" : leaf
    ObjectNode::Alias.new(name, expr, type)
  end

  # the List a node wraps (through NON_NULL), or nil
  def list_of(node)
    node = T.let(node, T.untyped)
    node = node.of while node.is_a?(NonNull)
    node if node.is_a?(List)
  end

  # the ObjectNode a node resolves to for field access (through NON_NULL and a
  # narrowed abstract member), or nil — unions/scalars/lists can't be read into
  def object_of(node)
    node = T.let(node, T.untyped)
    node = node.of while node.is_a?(NonNull)
    node = node.nested if node.is_a?(NarrowedNode)
    node if node.is_a?(ObjectNode)
  end

  # The concrete type conditions a selection mentions (inline fragments
  # and named spreads), minus conditions naming the abstract type itself.
  def concrete_conditions(core, selections)
    selections.filter_map do |selection|
      case selection
      when GraphQL::Language::Nodes::InlineFragment
        selection.type&.name
      when GraphQL::Language::Nodes::FragmentSpread
        @fragments.fetch(selection.name).type.name
      end
    end.uniq - [core.graphql_name]
  end

  # result keys selected as plain fields (outside any type condition)
  def bare_fields(selections)
    selections.grep(GraphQL::Language::Nodes::Field).map { |field| field.alias || field.name }
  end

  # The fragment name when a selection is exactly one bare fragment spread
  # (`{ ...F }`) — the shape a union field must have to hoist into the shared
  # unions module. A spread carrying directives (@skip/@include), or mixed with
  # other fields, stays a locally-emitted union.
  def lone_shared_spread(selections)
    return unless selections.size == 1

    spread = selections.first
    spread.name if spread.is_a?(GraphQL::Language::Nodes::FragmentSpread) && spread.directives.empty?
  end

  # does the flattened selection (as seen by member) include at least one
  # field guaranteed to be present in a matching response?
  def unconditional_field?(member, selections)
    each_field(member, selections) do |_key, node|
      return true if node.directives.none? { |d| %w[skip include].include?(d.name) }
    end
    false
  end

  # rebuild LIST wrappers but drop NON_NULLs — a narrowed member is nil
  # whenever the runtime type doesn't match, whatever the schema promises
  def nilable_type_ref(type, &core)
    case type.kind.name
    when "NON_NULL"
      nilable_type_ref(type.of_type, &core)
    when "LIST"
      List.new(nilable_type_ref(type.of_type, &core))
    else
      core.call
    end
  end

  # Abstract types (unions AND interfaces) whose selections vary by
  # concrete type: one member struct per possible type; wire dispatch
  # reads __typename, so the query must select it. For interfaces, the
  # interface's own field selections gather into every member.
  # The union's member structs (graphql type name => ObjectNode), sorted for
  # deterministic output. Dispatch reads __typename, so the query must select
  # it; for interfaces the interface-level fields gather into every member.
  def union_members(type, selections)
    unless gather(type, selections).key?("__typename")
      raise ArgumentError,
        "select __typename on #{type.graphql_name} so the union can dispatch — " \
        "or narrow to a single `... on Type` condition (no dispatch needed)"
    end

    @schema.possible_types(type).sort_by(&:graphql_name).to_h do |possible|
      [possible.graphql_name, object_node(possible, selections, camelize(possible.graphql_name))]
    end
  end

  # A name-independent structural fingerprint of a union's members, so two
  # occurrences that generate identical structs collapse to one Ruby type.
  def union_signature(members)
    members.map { |gname, member| "#{gname}=#{signature(member)}" }.sort.join(",")
  end

  # Structural signature of a node — ignores the generated class name (which
  # varies per occurrence), keying on GraphQL type, selection shape, and
  # nullability so only genuinely-identical shapes collapse.
  def signature(node)
    case node
    when NonNull then "!#{signature(node.of)}"
    when List then "[#{signature(node.of)}]"
    when NarrowedNode then "?#{signature(node.nested)}"
    when Scalar then "s:#{node.bare_type}"
    when EnumNode then "e:#{node.values.sort.join("|")}"
    when MappedEnum then "m:#{node.graphql_name}"
    when ObjectNode
      inner = node.fields.map { |f| "#{f.prop}=#{signature(f.node)}" }.sort.join(",")
      "o:#{node.graphql_type}(#{inner})"
    when UnionNode then "u:(#{union_signature(node.members)})"
    when UnionRefNode then "ur:#{node.class_name}" # hoisted — identity is its shared name
    else "x:#{node.object_id}" # unknown node kind — never collapse
    end
  end

  # Build a node from an AST type reference (variable definitions), where
  # only the type NAME is known — resolve the core through the schema.
  def ast_type_ref(ast_type)
    case ast_type
    when GraphQL::Language::Nodes::NonNullType
      NonNull.new(ast_type_ref(ast_type.of_type))
    when GraphQL::Language::Nodes::ListType
      List.new(ast_type_ref(ast_type.of_type))
    when GraphQL::Language::Nodes::TypeName
      variable_core(@schema.get_type(ast_type.name))
    else
      raise GraphWeaver::Error, "unsupported type node: #{ast_type.class}"
    end
  end

  # the input-side core kinds a variable (or input-object field) can have
  def variable_core(core)
    case core.kind.name
    when "SCALAR"
      scalar_node(core.graphql_name)
    when "ENUM"
      mapped_enum_node(core) || (@variable_enums[core.graphql_name] ||=
        EnumNode.new(camelize(core.graphql_name), core.values.keys.sort))
    when "INPUT_OBJECT"
      input_node(core)
    else
      raise GraphWeaver::Error, "unsupported variable kind: #{core.kind.name}"
    end
  end

  # A module-level T::Struct per input type, with a serialize method
  # producing the wire hash. Registered once per type — and registered
  # BEFORE its fields walk, so recursive references (Hasura's bool_exp
  # _and/_or/_not) resolve to the same node instead of looping.
  def input_node(core)
    return @variable_inputs[core.graphql_name] if @variable_inputs.key?(core.graphql_name)

    node = @variable_inputs[core.graphql_name] = InputNode.new(camelize(core.graphql_name))
    # sorted so output is deterministic across schema sources
    core.arguments.values.sort_by(&:graphql_name).each do |argument|
      prop = underscore(argument.graphql_name)
      # prop readers are bare method calls in the generated struct
      if RUBY_KEYWORDS.include?(prop) || GENERATED_METHODS.include?(prop)
        raise GraphWeaver::Error,
          "input field #{core.graphql_name}.#{argument.graphql_name} would become prop '#{prop}', " \
          "which collides with #{RUBY_KEYWORDS.include?(prop) ? "a Ruby keyword" : "the struct's generated ##{prop}"}"
      end

      child = type_ref(argument.type) { variable_core(unwrap(argument.type)) }
      required = child.non_null? && !argument.default_value?
      node.fields << InputNode::Field.new(prop, argument.graphql_name, child, required)
    end
    node
  end

  # The InputNodes a struct's fields reference, through NON_NULL/LIST
  # wrappers — the edges of the input dependency graph.


  # Registered helper-module names for a GraphQL type (additive: global
  # registrations plus this client's), collecting their requires.
  def type_mixins(graphql_name)
    entries = [GraphWeaver::Codegen.type_registry[graphql_name], @types[graphql_name]].compact
    entries.each { |entry| @requires.concat(entry[:requires]) }
    entries.flat_map { |entry| entry[:mixins].map(&:name) }
  end

  # The MappedEnum node for a schema enum with a registered app-enum
  # mapping (client overlay first, then the global registry); nil when
  # unregistered, falling back to a generated T::Enum.
  def mapped_enum_node(core)
    enum_type = @enums[core.graphql_name] || GraphWeaver::Codegen.enum_registry[core.graphql_name]
    return unless enum_type

    @requires.concat(enum_type.requires)
    @mapped_enums[core.graphql_name] ||= MappedEnum.new(enum_type, core.values.keys.sort)
  end

  # A Scalar node, recording any requires its registered type needs so the
  # generated file can require them (collected across the whole query).
  # Resolution, most specific first: a per-field override (`Type.field`), then
  # the scalar-name registration — each checked client-scoped, then global.
  def scalar_node(name, coordinate = nil)
    scalar =
      (coordinate && (@scalars[coordinate] || GraphWeaver::Codegen.scalar_registry[coordinate])) ||
      @scalars[name.to_s] ||
      GraphWeaver::Codegen.scalar(name)
    @requires.concat(scalar.requires)
    Scalar.new(scalar)
  end

  # rebuild the NON_NULL/LIST wrappers around the core node
  def type_ref(type, &core)
    case type.kind.name
    when "NON_NULL"
      NonNull.new(type_ref(type.of_type, &core))
    when "LIST"
      List.new(type_ref(type.of_type, &core))
    else
      core.call
    end
  end

  def unwrap(type)
    type = type.of_type while type.kind.name == "NON_NULL" || type.kind.name == "LIST"
    type
  end

  # GraphQL type names become struct names — camelized, because schemas
  # in the wild use snake_case type names (Hasura, PostGraphile) and a
  # verbatim lowercase name is not a Ruby constant
  def pick_name(type_name, key, taken)
    candidate = camelize(type_name)
    candidate = "#{camelize(key)}#{candidate}" if taken.include?(candidate)
    raise GraphWeaver::Error, "class name collision: #{candidate}" if taken.include?(candidate)

    taken << candidate
    candidate
  end

end
