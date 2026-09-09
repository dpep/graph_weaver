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
# Split across: codegen/scalar_type.rb and codegen/enum_type.rb (the leaf
# registries), codegen/type_helpers.rb (extend_type and the alias/mixin
# registry), codegen/nodes.rb (the typed IR), codegen/aliases.rb (resolving
# registered alias paths against a node), codegen/emit.rb (source emission);
# this file holds the public API and the query walk.
require_relative "hints"
require_relative "input_struct"
require_relative "schema_loader"
require_relative "representation"
require_relative "inflect"
require_relative "selection"
require_relative "codegen/enum_type"
require_relative "codegen/scalar_type"
require_relative "codegen/nodes"
require_relative "codegen/aliases"
require_relative "codegen/emit"

class GraphWeaver::Codegen
  include GraphWeaver::Inflect
  include GraphWeaver::Selection
  include Aliases
  include Emit

  # How a directory of GraphQL documents is scanned: both extensions the rest of
  # the library already accepts, and nested — `queries/admin/pets.graphql` is
  # how anyone with sixty queries organizes them.
  DOCUMENT_GLOB = "**/*.{graphql,gql}"

  # Why every registration takes the constant and never its name. register_enum
  # and extend_type refuse a String for the same reason, so they say it in the
  # same words — a reword has to reach both or one starts giving worse advice.
  AUTOLOAD_HINT = "An autoloaded constant isn't resolvable while config/initializers " \
    "run; register from a Rails.application.config.to_prepare block, which generation " \
    "also runs first."

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
  # name). types_namespace: is the shared-types workflow (see
  # GraphWeaver.generate!): input types, schema enums, and unions hoisted from
  # shared fragments live once in that module and the query module aliases what
  # it uses. hoistable_unions: is the set of shared fragment names this query
  # may hoist (spreads it inlined, minus any it shadows locally) — a
  # whole-union field spread as one of them resolves to a canonical type in the
  # shared module (see used_union_names). path: is the file the query was read
  # from, named alongside line and column in validation errors.
  def initialize(schema:, query:, module_name: nil, client: nil, default_module_name: nil,
    types_namespace: nil, hoistable_unions: nil, path: nil)
    @schema = schema
    @query = query.strip
    @path = path
    @module_name = module_name
    @default_module_name = default_module_name
    @types_namespace = types_namespace
    @hoistable_unions = hoistable_unions || []
    @used_unions = []
    # scalars this generation had no registration for (see report_untyped_scalars)
    @untyped_scalars = []
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
  def self.generate(schema:, query:, module_name: nil, client: nil, path: nil)
    new(schema:, query:, module_name:, client:, path:).generate
  end

  # Development convenience: generate + eval in one step, no build
  # artifact or checked-in file. Same runtime semantics as the generated
  # file, but invisible to srb tc — use the build step for static typing.
  # Evaluates into an anonymous container, so no global constants leak;
  # client: additionally accepts a live object (set via .client=).
  def self.parse(schema:, query:, module_name: nil, client: nil, path: nil)
    client_const = client_const(client)

    codegen = new(schema:, query:, module_name:, client: client_const, path:,
      default_module_name: "Query")
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

  # Every registry back to its starting state — scalars (built-ins restored),
  # enum mappings, and type helpers. The clean slate between tests, and the
  # one call that stays right when a fourth kind of registration shows up.
  def self.reset_registrations!
    reset_scalars!
    reset_enums!
    reset_type_helpers!
    self
  end

  # The schema-level types this walk touched, by GraphQL name — the generate!
  # workflow unions these across queries to decide what the shared types module
  # must contain.
  def variable_type_names
    { inputs: @variable_inputs.keys, enums: @enums.keys, mapped: @mapped_enums.keys }
  end

  # The shared union fragments this query hoisted, by name — the generate!
  # workflow unions these across queries to decide what the shared types module
  # must contain.
  def used_union_names = @used_unions.dup

  # The shared types artifact: every type a schema shares across query modules,
  # emitted once as a manifest (types.rb) plus one file per type under types/,
  # so a schema migration diffs only the types it touched. Returns
  # { relative_filename => source }. Three kinds live here:
  #
  # - inputs: the named input types, plus everything they transitively
  #   reference (nested types stay unaliased — the query module names only the
  #   variable roots);
  # - enums: one Ruby type per schema enum a query touched — a generated
  #   T::Enum, or the wire tables for one mapped onto an app enum
  #   (register_enum) — so a value read out of one query's result hands
  #   straight back into another's variable;
  # - unions: each named shared fragment a query spread as a whole union field,
  #   so the same union across queries is one Ruby type family. `fragments` is
  #   the loaded shared-fragment table (nested spreads resolve through it).
  #
  # Unions are built first: a hoisted fragment's own selections are the one
  # place a query walk never reaches, so the enums they touch are only known
  # once the fragments are built.
  def generate_types(inputs:, enums:, unions:, fragments:)
    validate_module_name!("types module name")
    reset_walk_state!
    # nested spreads inside a shared fragment resolve through the whole table
    @fragments = fragments

    union_nodes = unions.uniq.sort.map { |name| hoisted_union(fragments, name) }
    inputs.sort.each { |name| input_node(@schema.get_type(name)) }
    enums.uniq.sort.each { |name| variable_core(@schema.get_type(name)) }
    check_shared_collisions!(unions)
    union_nodes.each { |union| check_shadowing!(union) }

    emit_types_files(union_nodes).tap { report_untyped_scalars }
  end

  # module-level constants every generated query module defines — a shared
  # type aliased to one of these would clash at load
  MODULE_RESERVED = %w[Result QUERY Representations].to_set.freeze

  # One hoisted shared fragment, built against the schema and named for the
  # fragment rather than the field that spread it.
  def hoisted_union(fragments, name)
    class_name = camelize(name)
    # the query module aliases <class_name> = <shared module>::<class_name>; a
    # name that camelizes to a generated module-level constant (the Result
    # struct, the QUERY heredoc) would collide with that alias at load
    if MODULE_RESERVED.include?(class_name)
      raise GraphWeaver::Error,
        "shared fragment #{name.inspect} hoists to #{class_name}, which collides with a generated constant — rename the fragment"
    end

    fragment = fragments.fetch(name)
    type = @schema.get_type(fragment.type.name)
    members = union_members(type, fragment.selections)
    UnionNode.new(class_name, members, catch_all_member(type, fragment.selections, members))
  end
  private :hoisted_union

  # Schema type names are unique, so an input and an enum can never land on the
  # same name — but a hoisted union is named for its FRAGMENT, which the schema
  # knows nothing about. One shared module means one namespace, so a fragment
  # named after a type it doesn't describe has to refuse rather than overwrite.
  def check_shared_collisions!(names)
    taken = {}
    @enums.each { |graphql_name, node| taken[node.class_name] = "the schema enum #{graphql_name}" }
    @mapped_enums.each_key { |graphql_name| taken[camelize(graphql_name)] = "the schema enum #{graphql_name}" }
    @variable_inputs.each { |graphql_name, node| taken[node.class_name] = "the input type #{graphql_name}" }

    names.each do |name|
      class_name = camelize(name)
      claim = taken[class_name] or next

      raise GraphWeaver::Error,
        "shared fragment #{name.inspect} hoists to #{@module_name}::#{class_name}, " \
        "where #{claim} already generates — rename the fragment"
    end
  end
  private :check_shared_collisions!

  # per-run walk state, cleared so one Codegen can generate more than once
  def reset_walk_state!
    @enums = {}
    @variable_inputs = {}
    @mapped_enums = {}
    @used_unions = []
    # requires the generated file needs (custom scalars, enum mappings,
    # type helpers all contribute)
    @requires = []
  end
  private :reset_walk_state!

  # generated source is eval'd by parse — never let a name inject code
  CONSTANT_NAME = /\A[A-Z]\w*(::[A-Z]\w*)*\z/

  def validate_module_name!(subject)
    return if @module_name&.match?(CONSTANT_NAME)

    problem = "#{subject} must be a constant name, got #{@module_name.inspect}"
    # An explicit module_name: is an argument wrong on its face. A derived one
    # is a verdict on a FILE — a numeric prefix (01_home.graphql) is the usual
    # way in — so it names the file, says the fix is a rename, and brands so
    # `rake graph_weaver:generate` aborts on it instead of burying it under a
    # backtrace through codegen.
    raise ArgumentError, problem unless @path

    raise GraphWeaver::Error, "#{@path}: #{problem} — it comes from the file name, so rename the " \
      "file to one a constant can spell (a letter first, then letters, digits or underscores)"
  end
  private :validate_module_name!

  VarDef = Struct.new(:kwarg, :wire, :node, :required)

  # Names generated Ruby can't spell bare — as a kwarg, a local, or a method
  # name. As a prop they're fine (`const :next`), since a prop is only ever
  # read off a receiver.
  RUBY_KEYWORDS = %w[
    alias and begin break case class def defined? do else elsif end
    ensure false for if in module next nil not or redo rescue retry
    return self super then true undef unless until when while yield
    BEGIN END __FILE__ __LINE__ __ENCODING__
  ].to_set.freeze
  GENERATED_METHODS = %w[serialize to_h].to_set.freeze
  # Names the generated `execute` body owns: the per-call client kwarg and the
  # variables hash it builds. A GraphQL variable by either name redeclares one
  # — `def self.execute(client:, client: nil)` doesn't even parse. No legal
  # Ruby local is unreachable by a GraphQL variable name, so this is a guard
  # rather than a rename.
  RESERVED_KWARGS = %w[client variables].to_set.freeze
  # Every method a struct instance already answers: T::Props refuses to redefine
  # those (`class`, `hash`, `send`, `to_s`), so the generated file would raise
  # ArgumentError at require time. Derived rather than listed, so it tracks
  # whatever the Ruby and sorbet-runtime in play actually define.
  STRUCT_METHODS = (GENERATED_METHODS + T::Struct.instance_methods.map(&:to_s)).freeze

  def generate
    begin
      errors = @schema.validate(@query)
    rescue GraphQL::ParseError => e
      # unparseable queries wrap like invalid ones — everything raised
      # here descends from GraphWeaver::Error
      raise GraphWeaver::ValidationError.new([detail(e.message, e.line, e.col)])
    end
    if errors.any?
      raise GraphWeaver::ValidationError.new(errors.map { |e| validation_detail(e) })
    end

    validate_registrations!
    reset_walk_state!

    operation = load_operation(@query)
    root_type = operation_root_type(operation)

    @module_name ||= operation.name || @default_module_name
    unless @module_name
      raise ArgumentError, "module_name: required for anonymous operations"
    end

    validate_module_name!("module_name:")

    variables = build_variables(operation)
    root = object_node(root_type, operation.selections, "Result")
    check_shadowing!(root)

    # An anonymous operation takes the module's name — declared in the document
    # AND sent as operationName, which have to agree (a server rejects an
    # operationName the document doesn't declare). The conventional .graphql
    # file names nothing, so without this every trace arrives anonymous.
    operation_name = operation.name || @module_name.split("::").last
    @query = declare_operation_name(operation, operation_name) unless operation.name

    emit_module(root, variables, representation_nodes(operation, root_type), operation_name)
      .tap { report_untyped_scalars }
  end

  private

  # Insert `name` into the operation's own declaration, leaving the rest of the
  # document exactly as written — re-printing the AST would reformat the query
  # the reader reviews. The module name is already constrained to
  # /[A-Z]\w*(::[A-Z]\w*)*/, so its last segment is always a legal GraphQL name.
  def declare_operation_name(operation, name)
    at = @query.lines.first(operation.line - 1).sum(&:length) + operation.col - 1
    keyword = @query[at..].to_s[/\A(?:query|mutation|subscription)\b/]
    return "#{@query[0, at]}query #{name} #{@query[at..]}" unless keyword # `{ ... }` shorthand

    "#{@query[0, at + keyword.length]} #{name}#{@query[(at + keyword.length)..]}"
  end

  # The operation's variables as execute's kwarg surface: one VarDef each,
  # typed from the AST. A variable is optional when nullable or defaulted —
  # optional kwargs default to nil and are omitted from the wire.
  def build_variables(operation)
    variables = operation.variables.map do |var|
      node = ast_type_ref(var.type)
      required = node.non_null? && var.default_value.nil?
      kwarg = underscore(var.name)
      # kwargs are declared and forwarded bare in generated source
      if RUBY_KEYWORDS.include?(kwarg)
        raise GraphWeaver::Error,
          "variable $#{var.name} would become the kwarg '#{kwarg}:', which generated code can't declare " \
          "(a Ruby keyword) — rename the variable"
      end
      if RESERVED_KWARGS.include?(kwarg)
        raise GraphWeaver::Error,
          "variable $#{var.name} would become the kwarg '#{kwarg}:', which generated execute already " \
          "uses — rename the variable (query($#{var.name}Id: ...))"
      end
      VarDef.new(kwarg, var.name, node, required)
    end

    # two variables that underscore to the same kwarg ($userId + $user_id) would
    # silently drop one on the wire — flag it like a prop collision
    collision = variables.group_by(&:kwarg).find { |_, vars| vars.size > 1 }
    if collision
      wire = collision.last.map { |var| "$#{var.wire}" }.join(", ")
      raise GraphWeaver::Error,
        "variables #{wire} both map to the kwarg '#{collision.first}:' — rename one"
    end

    variables
  end

  # Builders for the entity types this query's representation-taking fields
  # can return. The hook is the schema, not the field name: the subgraph spec
  # types a representation as `_Any`, so a field taking one is asking for
  # entity references, and the entity types are the @key'd members its
  # selection names. Query-driven like everything else — a subgraph with
  # fifty entities emits builders only for the ones the query reaches.
  def representation_nodes(operation, root_type)
    nodes = entity_types(operation, root_type).filter_map { |entity| representation_node(entity) }

    collision = nodes.group_by(&:method_name).find { |_, group| group.size > 1 }
    if collision
      types = collision.last.map(&:graphql_type).join(" and ")
      raise GraphWeaver::Error,
        "entities #{types} both build Representations.#{collision.first} — rename one, or drop it from the selection"
    end

    nodes
  end

  # The types a representation-taking field's selection names. `_entities` is
  # a root field and the spec defines it nowhere else, so this looks no deeper.
  def entity_types(operation, root_type)
    gather_conditional(root_type, operation.selections).each_value.flat_map { |occurrences|
      fields = occurrences.map(&:first)
      definition = @schema.get_field(root_type.graphql_name, fields.first.name)
      next [] unless definition && representation_field?(definition)

      core = definition.type.unwrap
      next [] unless %w[UNION INTERFACE].include?(core.kind.name)

      selected_members(core, fields.flat_map(&:selections))
    }.uniq(&:graphql_name)
  end

  # The subgraph spec's representation scalar. A field taking one is the
  # entity resolver, whatever it's called.
  REPRESENTATION_SCALAR = "_Any"

  def representation_field?(definition)
    definition.arguments.each_value.any? { |argument| argument.type.unwrap.graphql_name == REPRESENTATION_SCALAR }
  end

  # A `@key` this subgraph resolves. Matched by local name, since a fed-2
  # subgraph linking the spec under a namespace applies @federation__key;
  # `resolvable: false` declares a key the subgraph explicitly does NOT
  # answer for, so it can't stand behind a representation.
  def resolvable_keys(type)
    return [] unless type.respond_to?(:directives)

    type.directives.filter_map do |directive|
      name = directive.graphql_name
      next unless name == "key" || name.end_with?("__key")

      arguments = directive.arguments.keyword_arguments
      next if arguments[:resolvable] == false

      arguments[:fields]&.to_s
    end
  end

  # An entity's builder, or nil when the type isn't one (no resolvable @key).
  def representation_node(entity)
    key_fields = resolvable_keys(entity)
    key_sets = key_fields.map { |fields| key_paths(entity, fields) }
    return if key_sets.empty?

    method_name = underscore(entity.graphql_name)
    if RUBY_KEYWORDS.include?(method_name)
      raise GraphWeaver::Error,
        "entity #{entity.graphql_name} would build Representations.#{method_name}, which generated code can't declare (a Ruby keyword)"
    end

    RepresentationNode.new(method_name, entity.graphql_name, key_fields, key_sets,
      key_params(entity, key_sets, required: key_sets.one?))
  end

  # A @key field set is a GraphQL selection set — "upc sku", or a nested
  # "id organization { id }" — flattened to the dotted leaf paths the wire
  # hash needs. The same reading the routing table does of the same syntax,
  # so a supergraph and a subgraph SDL can't disagree about one key.
  def key_paths(entity, fields)
    GraphWeaver::SchemaLoader::RoutingTable.parse_field_set(fields)
  rescue GraphQL::ParseError => e
    raise GraphWeaver::Error, "#{entity.graphql_name} @key(fields: #{fields.inspect}) isn't a selection set: #{e.message}"
  end

  # The kwargs a builder takes: every key set's top-level field, once. Typed
  # from the schema — a leaf key field gets its registered scalar's Ruby
  # type, a nested one an open Hash whose shape the runtime checks.
  def key_params(entity, key_sets, required:)
    key_sets.flatten.map { |path| path.split(".").first }.uniq.map do |name|
      field = @schema.get_field(entity.graphql_name, name)
      unless field
        raise GraphWeaver::Error, "#{entity.graphql_name} @key names #{name.inspect}, which the type doesn't declare"
      end

      kwarg = underscore(name)
      if RUBY_KEYWORDS.include?(kwarg)
        raise GraphWeaver::Error,
          "#{entity.graphql_name} @key field #{name.inspect} would become the kwarg '#{kwarg}:', " \
          "which generated code can't declare (a Ruby keyword)"
      end

      core = field.type.unwrap
      if core.kind.name == "SCALAR"
        node = scalar_node(core.graphql_name, "#{entity.graphql_name}.#{name}")
        type = required ? node.bare_type : node.prop_type
        value = node.serialize_identity? ? kwarg : "#{kwarg}&.then { |v1| #{node.serialize("v1", 2)} }"
      else
        # a nested key set — or an enum/composite one — passes through as an
        # open hash, narrowed to the declared sub-paths by the runtime
        type = "T::Hash[T.untyped, T.untyped]"
        type = "T.nilable(#{type})" unless required
        value = kwarg
      end

      RepresentationNode::Param.new(kwarg, name, type, value, required)
    end
  end

  # What a registry's names must be in the schema. extend_type decorates
  # whatever composite a query reaches, so it demands no particular kind.
  REGISTERED_KIND = { "scalar" => "SCALAR", "enum" => "ENUM" }.freeze
  # the type registry is reached via extend_type; scalars/enums via register_*
  REGISTRATION_METHOD = { "type" => "extend_type", "scalar" => "register_scalar", "enum" => "register_enum" }.freeze
  private_constant :REGISTERED_KIND, :REGISTRATION_METHOD

  # One registry serves the whole graph, but a generation sees one schema — so
  # a registration fails generation only where THIS schema can disprove it (a
  # field its own type doesn't declare, a name of the wrong kind). A name it
  # doesn't have at all is indistinguishable from one meant for a sibling
  # subgraph, so it warns instead. Called at generation for every registration.
  def self.validate_registration!(schema, kind, name)
    method = REGISTRATION_METHOD.fetch(kind)
    # register_scalar("Type.field", ...) overrides one field's scalar — validate
    # the field, not that a type named "Type.field" exists.
    return validate_scalar_field!(schema, name, method) if kind == "scalar" && name.include?(".")

    type = schema.get_type(name)
    return unmatched(schema, method, name, kind == "type" ? "type" : kind) unless type

    expected = REGISTERED_KIND[kind]
    return if expected.nil? || type.kind.name == expected

    found = type.kind.name.downcase.tr("_", " ")
    other = REGISTERED_KIND.key(type.kind.name)
    raise GraphWeaver::Error,
      "#{method}(#{name.inspect}) names #{article(found)} #{found}, not #{article(expected)} " \
      "#{expected.downcase}#{other ? " — use #{REGISTRATION_METHOD.fetch(other)}" : ""}"
  end

  # A per-field override, register_scalar("Type.field", ...). The type has to
  # be here for the field to mean anything; once it is, the field is checkable.
  def self.validate_scalar_field!(schema, name, method)
    type_name, field_name = name.split(".", 2)
    type = field_name && schema.get_type(type_name)
    return unmatched(schema, method, name, "scalar field") unless type

    fields = type.respond_to?(:fields) ? type.fields : {}
    field = fields[field_name]
    unless field
      suggestion = GraphWeaver.did_you_mean(fields.keys, field_name)
      hint = suggestion ? " — did you mean '#{type_name}.#{suggestion}'?" : ""
      raise GraphWeaver::Error, "#{method}(#{name.inspect}) matches no scalar field on #{type_name}#{hint}"
    end
    return if field.type.unwrap.kind.name == "SCALAR"

    raise GraphWeaver::Error,
      "#{method}(#{name.inspect}): #{name} isn't a scalar field (it's #{field.type.unwrap.kind.name.downcase})"
  end
  private_class_method :validate_scalar_field!

  # A name this schema has nothing for. Registrations are graph-scoped —
  # federation composes by name, so one `Money` codec serves every subgraph
  # that declares it — which is exactly why this schema can't tell a typo from
  # a registration for the subgraph next door. Say both and carry on.
  def self.unmatched(schema, method, name, what)
    GraphWeaver.log(:warn) do
      suggestion = GraphWeaver.did_you_mean(schema.types.keys, name.split(".").first)
      hint = suggestion ? " (did you mean '#{suggestion}'?)" : ""
      "#{method}(#{name.inspect}) matches no #{what} in #{schema.name || "this schema"} " \
        "— a typo#{hint}, or a registration for another schema"
    end
  end
  private_class_method :unmatched

  def self.article(word) = word.downcase.start_with?(/[aeiou]/) ? "an" : "a"
  private_class_method :article

  # Parse every fragment file under `paths` into one { name => FragmentDefinition }
  # map — reusable fragments a query can spread. Fragment files hold only
  # fragments (no operations); names are unique across them.
  def self.load_fragments(paths)
    source = {} # fragment name => the file that defined it, for the collision message

    Array(paths).flat_map { |dir| Dir[File.join(dir, DOCUMENT_GLOB)].sort }.each_with_object({}) do |file, out|
      doc = parse_document(File.read(file), file)
      if doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).any?
        raise GraphWeaver::Error, "#{file}: fragment files define only fragments, no operations"
      end
      doc.definitions.grep(GraphQL::Language::Nodes::FragmentDefinition).each do |frag|
        if (earlier = source[frag.name])
          raise GraphWeaver::Error,
            "duplicate shared fragment '#{frag.name}' — defined in #{earlier} and #{file}; rename one"
        end
        source[frag.name] = file
        out[frag.name] = frag
      end
    end
  end

  # The shared fragments a query spreads (transitively), excluding any it
  # shadows with a local definition of the same name — the names
  # inline_fragments appends, and the set the generate! workflow may hoist
  # when they sit on a whole-union field.
  def self.shared_fragment_spreads(query, shared, path = nil)
    # parsed even with nothing to spread: this is the first look at the document
    # on the generate! path, so it's where a syntax error gets branded and
    # pinned to the file it came from
    doc = parse_document(query, path)
    return [] if shared.empty?

    local = doc.definitions.grep(GraphQL::Language::Nodes::FragmentDefinition).map(&:name)
    reachable_fragments(fragment_spreads(doc.definitions), shared, local)
  end

  # Parse a GraphQL document, branding graphql-ruby's ParseError under the
  # umbrella and naming the file it came from — its own location is a line and
  # column in a document the caller never sees. This runs on the generate! path
  # BEFORE Codegen#generate's rescue, so it needs its own guard.
  def self.parse_document(query, path = nil)
    GraphQL.parse(query)
  rescue GraphQL::ParseError => e
    prefix = [path, e.line, e.col].compact.join(":")
    raise GraphWeaver::ValidationError.new(
      [{ message: prefix.empty? ? e.message : "#{prefix} #{e.message}", line: e.line, column: e.col }],
    )
  end

  # Append the shared fragments a query spreads (transitively) to its source, so
  # the sent query is self-contained. Unused shared fragments are left out.
  def self.inline_fragments(query, shared, path = nil)
    used = shared_fragment_spreads(query, shared, path)
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
    detail(error.message, loc && loc["line"], loc && loc["column"])
  end

  # One ValidationError entry, its message prefixed "file:line:col" like a
  # compiler — the position is captured either way, and without it a project
  # with thirty query files leaves the reader hunting for the typo.
  def detail(message, line, column)
    prefix = [@path, line, column].compact.join(":")
    { message: prefix.empty? ? message : "#{prefix} #{message}", line:, column: }
  end

  # Every registration this generation could consult. The built-in scalars are
  # pre-registered entries in the same table rather than user intent, so
  # they're exempt — a schema with no Date scalar is not a mistake.
  def validate_registrations!
    {
      "enum" => GraphWeaver::Codegen.enum_registry,
      "scalar" => GraphWeaver::Codegen.scalar_registry.except(*BUILTIN_SCALARS),
      "type" => GraphWeaver::Codegen.type_registry,
    }.each do |kind, registry|
      registry.each_key { |name| self.class.validate_registration!(@schema, kind, name) }
    end
  end

  # The @include/@skip a fragment carries applies to what it guards, so it has
  # to travel with the selections into the child rather than being spent on the
  # key. Re-wrapping in a guarded inline fragment says that in the vocabulary
  # the walk already speaks, which is what keeps dispatchable_typename? and the
  # __typename refusal honest for free.
  GUARDED = [GraphQL::Language::Nodes::Directive.new(name: "include")].freeze
  private_constant :GUARDED

  # A key's merged sub-selections, keeping the conditionality of the occurrence
  # each child came from: `pets @include(if:) { name } pets { species }` answers
  # with `name` only when that occurrence ran, so those children have to admit
  # nil. One occurrence needs none of this — the key is there exactly when it
  # ran, and its own prop already says so.
  def merged_selections(occurrences)
    return occurrences.first.first.selections if occurrences.one?

    occurrences.flat_map do |node, conditional|
      next node.selections unless conditional || conditional?(node)

      [GraphQL::Language::Nodes::InlineFragment.new(type: nil, directives: GUARDED, selections: node.selections)]
    end
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
    props = {}

    gather_conditional(type, selections).each do |key, occurrences|
      field_nodes = occurrences.map(&:first)
      field_name = field_nodes.first.name
      prop = underscore(key)
      check_output_prop!(type, key, prop, props)

      child = if field_name == "__typename"
        NonNull.new(scalar_node("String"))
      else
        field_type = @schema.get_field(type.graphql_name, field_name).type
        sub_selections = merged_selections(occurrences)

        case (core = field_type.unwrap).kind.name
        when "OBJECT"
          name = pick_name(key, taken)
          type_ref(field_type) { object_node(core, sub_selections, name) }
        when "UNION", "INTERFACE"
          conditions = concrete_conditions(core, sub_selections)
          shared = abstract_level_fields(core, sub_selections)

          if conditions.empty?
            # abstract-level fields only — every member shares them, so one
            # struct suffices and no __typename dispatch is needed (for a
            # union that selection can only be __typename)
            name = pick_name(key, taken)
            type_ref(field_type) { object_node(core, sub_selections, name) }
          elsif conditions.size == 1 && shared.empty? &&
              (member = @schema.get_type(conditions.first)).kind.name == "OBJECT"
            # a single `... on X` condition: narrow to X's struct — nil
            # when the runtime type doesn't match (narrowing filters).
            # With `__typename` selected the match is read off the tag;
            # without one there is nothing to read but emptiness, and a
            # fragment whose every field hides behind @skip/@include would
            # make a real match indistinguishable from a miss ({} either
            # way) — refuse rather than guess.
            tag = member.graphql_name if dispatchable_typename?(core, sub_selections)
            unless tag || unconditional_field?(member, sub_selections)
              raise GraphWeaver::Error,
                "narrowed `... on #{member.graphql_name}` needs at least one field not under " \
                "@skip/@include (or a `__typename` to match on) — an all-conditional selection " \
                "makes a match indistinguishable from nil"
            end

            name = pick_name(key, taken)
            nilable_type_ref(field_type) { NarrowedNode.new(object_node(member, sub_selections, name), typename: tag) }
          elsif @types_namespace && (frag = lone_shared_spread(sub_selections)) &&
              @hoistable_unions.include?(frag)
            # a whole-union field spread as a named shared fragment: hoist to
            # the shared types module so the same union across queries is one
            # Ruby type family (one exhaustive `case ... T.absurd`).
            @used_unions << frag unless @used_unions.include?(frag)
            ref = UnionRefNode.new(camelize(frag))
            type_ref(field_type) { ref }
          else
            members = union_members(core, sub_selections)
            catch_all = catch_all_member(core, sub_selections, members)
            # reuse an identical sibling union — the shared type takes the
            # first of the sharing keys alphabetically, not in walk order
            signature = union_signature(members, catch_all)
            union = union_cache[signature]
            if union
              rename_union(union, key, taken) if camelize(key) < union.class_name
            else
              union = union_cache[signature] = UnionNode.new(pick_name(key, taken), members, catch_all)
            end
            type_ref(field_type) { union }
          end
        when "ENUM"
          # one schema enum is one Ruby type: module-level, named for the enum,
          # shared by every result field and variable that reaches it (and, on
          # the generate! path, by every query module — see types_namespace)
          type_ref(field_type) { variable_core(core) }
        when "SCALAR"
          coordinate = "#{type.graphql_name}.#{field_name}"
          type_ref(field_type) { scalar_node(core.graphql_name, coordinate, result: true) }
        else
          raise GraphWeaver::Error, "unsupported kind: #{core.kind.name}"
        end
      end

      # A field under @skip/@include — on the field itself, or on any fragment
      # it was reached through — may be absent from the response no matter what
      # the schema says, so its type must admit nil. One unconditional
      # selection of the same key still guarantees it, though.
      if occurrences.all? { |node, conditional| conditional || conditional?(node) }
        child = child.of if child.is_a?(NonNull)
      end

      node.fields << ObjectNode::Field.new(prop, key, child)
    end

    node.aliases = resolve_aliases(node)
    node
  end

  # A generated class name is only ever a name; Ruby resolves it lexically. So
  # a struct nesting `class Date < T::Struct` (from a result key `date`) turns
  # a sibling `Date` scalar prop into that struct, and `Date.iso8601` into a
  # NoMethodError — the file typechecks against itself and means something
  # else. Refuse instead, naming both keys: aliasing either one in the query
  # fixes it. `scope` is what enclosing structs have already introduced, since
  # a nested class shadows for everything lexically inside it too.
  def check_shadowing!(node, scope = {})
    case node
    when UnionNode
      members = node.members.each_value.to_a + [node.catch_all].compact
      inner = scope.merge(members.to_h { |m| [m.class_name, "the member struct #{m.class_name}"] })
      members.each { |member| check_shadowing!(member, inner) }
    when ObjectNode
      nested = node.fields.filter_map { |field|
        child = field.node.nested
        [child, field.key] if child && !module_level?(child)
      }.uniq(&:first)
      inner = scope.merge(nested.to_h { |child, key| [child.class_name, "the class result key #{key.inspect} generates"] })

      external_constants(node).each do |name, source|
        shadow = inner[name] or next

        raise GraphWeaver::Error,
          "#{source} resolves to #{name}, but #{shadow} is also named #{name} and shadows it " \
          "inside #{node.class_name} — alias one in the query to a distinct name"
      end

      nested.each { |child, _| check_shadowing!(child, inner) }
    end
  end

  # Constants a struct's body names but doesn't define: the runtimes it always
  # mentions, a registered scalar's Ruby type, a module-level enum, a hoisted
  # union's alias, an extend_type mixin. Keyed by the constant's first segment,
  # which is all Ruby resolves — `Money::Amount` goes through `Money`.
  def external_constants(node)
    refs = { "T" => "the Sorbet runtime", "GraphWeaver" => "the GraphWeaver runtime" }
    node.mixins.each { |mixin| refs[root_constant(mixin)] ||= "the mixin #{mixin} registered with extend_type" }

    node.fields.each do |field|
      child = field.node.nested
      name = if child
        next unless module_level?(child)

        child.class_name
      else
        root_constant(unwrapped(field.node).bare_type)
      end
      refs[name] ||= "result key #{field.key.inspect}"
    end
    refs
  end

  def root_constant(name) = name[/\A[A-Za-z_]\w*/]

  # a leaf node with its NON_NULL/LIST wrappers removed
  def unwrapped(node)
    node = T.let(node, T.untyped)
    node = node.of while node.is_a?(NonNull) || node.is_a?(List)
    node
  end

  # Both ways a result key can fail to become a prop — a name the struct
  # already answers, or a second key that underscores onto an earlier one.
  # Either emits a file that raises ArgumentError at require time, so refuse
  # here; an alias in the query fixes both. `props` accumulates prop => key.
  def check_output_prop!(type, key, prop, props)
    # Keywords are fine: `const :next` and `next: data["next"]` are legal, and
    # the one place a prop is read bare (an alias delegator) qualifies it.
    # `pageInfo { next }` and `filter { in }` are ordinary API shapes.
    if STRUCT_METHODS.include?(prop)
      raise GraphWeaver::Error,
        "#{type.graphql_name}.#{key} would become prop '#{prop}', which every generated struct " \
        "already defines — alias it in the query (`#{prop}Value: #{key}`)"
    end

    if (earlier = props[prop])
      raise GraphWeaver::Error,
        "result keys #{earlier.inspect} and #{key.inspect} on #{type.graphql_name} both map to the " \
        "prop '#{prop}' — alias one to a distinct name"
    end

    props[prop] = key
  end

  # The concrete type conditions a selection mentions, minus conditions naming
  # the abstract type itself — recursing into named-fragment and inline bodies,
  # so a `... on X` nested inside a spread (`{ ...NodeFields }` where NodeFields
  # holds `... on X`) still drives dispatch instead of being silently dropped.
  def concrete_conditions(core, selections, visiting = Set.new)
    selections.flat_map do |selection|
      case selection
      when GraphQL::Language::Nodes::InlineFragment
        [selection.type&.name, *concrete_conditions(core, selection.selections, visiting)]
      when GraphQL::Language::Nodes::FragmentSpread
        next [] if visiting.include?(selection.name)

        fragment = @fragments.fetch(selection.name)
        [fragment.type.name, *concrete_conditions(core, fragment.selections, visiting | [selection.name])]
      else
        []
      end
    end.compact.uniq - [core.graphql_name]
  end

  # Result keys the abstract type itself answers — every member carries them,
  # so their presence rules out narrowing to one. Walked as the type sees it,
  # not read off the top level: `... on Named { name }` under a Named field is
  # the same selection as a bare `name`, and treating it as a type condition
  # would narrow the field away and drop what the server sent for every other
  # member. `__typename` is excluded — it's the dispatch tag, not a field.
  def abstract_level_fields(core, selections)
    keys = gather_conditional(core, selections).keys
    # __typename is the dispatch tag rather than a field — but only where it can
    # actually be read. One behind @skip/@include still arrives for the member a
    # narrowing means to filter out, and then the object isn't empty and
    # "empty means no match" casts a Review into an Announcement.
    dispatchable_typename?(core, selections) ? keys - ["__typename"] : keys
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
    each_field(member, selections) do |_key, node, conditional|
      return true if !conditional && !conditional?(node)
    end
    false
  end

  # Is the response guaranteed to carry a plain "__typename" key for this
  # abstract selection? Every dispatch reads the tag unguarded, so an alias
  # (which files it under another key) or an @skip/@include (which may drop
  # it) means there is no tag to dispatch on.
  def dispatchable_typename?(type, selections)
    occurrences = gather_conditional(type, selections)["__typename"]
    !!occurrences&.any? do |node, conditional|
      node.name == "__typename" && !conditional && !conditional?(node)
    end
  end

  # rebuild LIST wrappers but drop NON_NULLs — a narrowed member is nil
  # whenever the runtime type doesn't match, whatever the schema promises
  def nilable_type_ref(type, &core)
    case type.kind.name
    when "NON_NULL"
      # only the NON_NULL around the narrowed member itself drops — `[Thing!]!`
      # narrowed is a guaranteed array of nilable members, not a nilable array
      inner = nilable_type_ref(type.of_type, &core)
      inner.is_a?(List) ? NonNull.new(inner) : inner
    when "LIST"
      List.new(nilable_type_ref(type.of_type, &core))
    else
      core.call
    end
  end

  # Abstract types (unions AND interfaces) whose selections vary by concrete
  # type: one member struct per type the selection NAMES (graphql type name =>
  # ObjectNode, sorted for deterministic output), never one per schema member —
  # a query against an interface with 278 implementations types the two it asked
  # about. Dispatch reads __typename, so the query must select it; for
  # interfaces the interface-level fields gather into every member.
  def union_members(type, selections)
    unless dispatchable_typename?(type, selections)
      raise ArgumentError,
        "select __typename on #{type.graphql_name} so the union can dispatch — unaliased and " \
        "not under @skip/@include, since from_h reads it on every response — or narrow to a " \
        "single `... on Type` condition (no dispatch needed)"
    end

    selected_members(type, selections).sort_by(&:graphql_name).to_h do |possible|
      [possible.graphql_name, object_node(possible, selections, camelize(possible.graphql_name))]
    end
  end

  # The concrete types a selection names through its type conditions, kept to
  # the abstract type's own members. A condition naming another abstract type
  # (`... on Named` inside a union) stands for the members it covers, since its
  # fields are typed per member.
  def selected_members(type, selections)
    possible = @schema.possible_types(type).to_h { |member| [member.graphql_name, member] }

    concrete_conditions(type, selections).flat_map { |name|
      condition = @schema.get_type(name)
      condition.kind.name == "OBJECT" ? [condition] : @schema.possible_types(condition)
    }.map(&:graphql_name).uniq.filter_map { |name| possible[name] }
  end

  # The one struct everything else deserializes into: a member the query didn't
  # name, and — the point — a member the schema grows AFTER this file was
  # generated, so a new upstream member bends the result rather than breaking
  # it. It carries what the abstract type itself guarantees, plus anything a
  # `... on SomeInterface` asked for, since an unnamed member may implement it.
  def catch_all_member(type, selections, members)
    node = object_node(type, selections, catch_all_name(members))
    taken = node.fields.map(&:key)

    # These are nilable whatever the schema promises: the member that arrives
    # need not implement the interface, and then the server sends nothing.
    sibling_conditions(type, selections).each do |condition, sub_selections|
      object_node(condition, sub_selections, node.class_name).fields.each do |field|
        next if taken.include?(field.key)

        taken << field.key
        child = field.node
        node.fields << ObjectNode::Field.new(field.prop, field.key, child.is_a?(NonNull) ? child.of : child)
      end
    end

    node.aliases = resolve_aliases(node)
    node
  end

  # The abstract type conditions inside an abstract selection that a member the
  # query never NAMED could still satisfy — `... on Named` under a union, or
  # under a different interface. Returns condition => merged selections, so the
  # same interface spread twice types once; concrete conditions are excluded,
  # since a member they'd match already has a struct of its own.
  def sibling_conditions(type, selections, visiting = Set.new, out = {})
    selections.each do |selection|
      case selection
      when GraphQL::Language::Nodes::InlineFragment
        sibling_condition(type, selection.type&.name, selection.selections, visiting, out)
      when GraphQL::Language::Nodes::FragmentSpread
        next if visiting.include?(selection.name)

        fragment = @fragments.fetch(selection.name)
        sibling_condition(type, fragment.type.name, fragment.selections, visiting | [selection.name], out)
      end
    end
    out
  end

  def sibling_condition(type, name, selections, visiting, out)
    condition = name ? @schema.get_type(name) : type
    return unless condition
    # same type condition restated — keep descending at this level
    return sibling_conditions(type, selections, visiting, out) if condition.graphql_name == type.graphql_name
    return unless condition.kind.abstract?

    (out[condition] ||= []).concat(selections)
    sibling_conditions(condition, selections, visiting, out)
  end

  # "Other", unless a real member already claims that name.
  def catch_all_name(members)
    taken = members.each_value.map(&:class_name)
    name = "Other"
    suffix = 2
    while taken.include?(name)
      name = "Other#{suffix}"
      suffix += 1
    end
    name
  end

  # A name-independent structural fingerprint of a union's members, so two
  # occurrences that generate identical structs collapse to one Ruby type.
  def union_signature(members, catch_all = nil)
    parts = members.map { |gname, member| "#{gname}=#{signature(member)}" }
    parts << "*=#{signature(catch_all)}" if catch_all
    parts.sort.join(",")
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
    when UnionNode then "u:(#{union_signature(node.members, node.catch_all)})"
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

  # The node for a core type, reached from a variable, an input-object field
  # or a result-side enum. All three share it so that one schema enum is one
  # Ruby type wherever it appears — see object_node's ENUM branch.
  def variable_core(core)
    case core.kind.name
    when "SCALAR"
      scalar_node(core.graphql_name)
    when "ENUM"
      mapped_enum_node(core) || (@enums[core.graphql_name] ||= enum_node(core))
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
    node.one_of = core.respond_to?(:one_of?) && core.one_of?
    # sorted so output is deterministic across schema sources
    core.arguments.values.sort_by(&:graphql_name).each do |argument|
      prop = underscore(argument.graphql_name)
      # Keywords are fine here: nothing reads an input prop bare (serialize goes
      # through public_send), and `const :in` is legal — which matters, since a
      # schema's field name is not the user's to rename. `Tricky.in` filters are
      # standard Hasura/Gatsby shape.
      if STRUCT_METHODS.include?(prop)
        raise GraphWeaver::Error,
          "input field #{core.graphql_name}.#{argument.graphql_name} would become prop '#{prop}', " \
          "which collides with a method every struct defines"
      end

      child = type_ref(argument.type) { variable_core(argument.type.unwrap) }
      required = child.non_null? && !argument.default_value?
      node.fields << InputNode::Field.new(prop, argument.graphql_name, child, required)
    end
    node
  end

  # The module-level T::Enum for a schema enum, named for the enum itself —
  # it is shared by every field and variable of that type.
  def enum_node(core)
    class_name = camelize(core.graphql_name)
    if MODULE_RESERVED.include?(class_name)
      raise GraphWeaver::Error,
        "enum #{core.graphql_name} generates #{class_name}, which collides with a generated " \
        "constant — map it onto one of yours: register_enum(#{core.graphql_name.inspect}, YourEnum)"
    end

    EnumNode.new(class_name, enum_values(core))
  end

  # A schema enum's wire values, sorted so output is deterministic across schema
  # sources (SDL round-trips reorder values alphabetically). Values that differ
  # only in case name the same T::Enum constant, which raises at LOAD time
  # ("Enum values must be assigned to constants") — catch it here instead.
  def enum_values(core)
    values = core.values.keys.sort
    # `_` and `__` are legal GraphQL enum values and camelize to nothing, so
    # the emitted `= new("_")` isn't even parseable — the file fails at load
    # with a syntax error pointing into generated source
    nameless = values.find { |value| !camelize(value.downcase).match?(/\A[A-Z]/) }
    if nameless
      raise GraphWeaver::Error,
        "enum #{core.graphql_name} value #{nameless} makes no constant name — map the enum onto " \
        "one of yours: register_enum(#{core.graphql_name.inspect}, YourEnum)"
    end

    collision = values.group_by { |value| camelize(value.downcase) }.find { |_, group| group.size > 1 }
    if collision
      raise GraphWeaver::Error,
        "enum #{core.graphql_name} values #{collision.last.join(" and ")} both become the constant " \
        "#{collision.first} — map the enum onto one of yours: " \
        "register_enum(#{core.graphql_name.inspect}, YourEnum)"
    end

    values
  end

  # Registered helper-module names for a GraphQL type, collecting their requires.
  def type_mixins(graphql_name)
    entry = GraphWeaver::Codegen.type_registry[graphql_name]
    return [] unless entry

    @requires.concat(entry[:requires])
    entry[:mixins].map(&:name)
  end

  # The MappedEnum node for a schema enum with a registered app-enum
  # mapping; nil when unregistered, falling back to a generated T::Enum.
  def mapped_enum_node(core)
    enum_type = GraphWeaver::Codegen.enum_registry[core.graphql_name]
    return unless enum_type

    @requires.concat(enum_type.requires)
    @mapped_enums[core.graphql_name] ||= MappedEnum.new(enum_type, core.values.keys.sort)
  end

  # A Scalar node, recording any requires its registered type needs so the
  # generated file can require them (collected across the whole query).
  # Resolution, most specific first: a per-field override (`Type.field`), then
  # the scalar-name registration.
  def scalar_node(name, coordinate = nil, result: false)
    registry = GraphWeaver::Codegen.scalar_registry
    @untyped_scalars << name.to_s unless (coordinate && registry[coordinate]) || registry[name.to_s]
    scalar = GraphWeaver::Codegen.scalar(name, coordinate)
    refuse_uncastable!(scalar, coordinate || name) if result
    @requires.concat(scalar.requires)
    Scalar.new(scalar)
  end

  # Everything JSON.parse can hand back. A registered type outside this set
  # has to be BUILT from one of them, which is what cast: is for.
  WIRE_CLASSES = [String, Integer, Float, Hash, Array, TrueClass, FalseClass].freeze
  private_constant :WIRE_CLASSES

  # A registered type nothing on the wire can be, with no cast to build one:
  # the prop is unsatisfiable, so every response fails — at runtime, a long
  # way from the registration that caused it. BigDecimal is the one people
  # reach for (it defines neither .parse nor .load, so inference finds no
  # codec and leaves the value untouched).
  def refuse_uncastable!(scalar, where)
    return if scalar.cast?

    klass = Object.const_get(scalar.type)
    return unless klass.is_a?(Class) && WIRE_CLASSES.none? { |native| native <= klass }

    raise GraphWeaver::Error,
      "register_scalar(#{scalar.graphql_name.inspect}, #{scalar.type}) has no cast, so nothing " \
      "builds a #{scalar.type} out of the JSON at #{where} — give it one (cast: :parse names a " \
      "class method, cast: ->(v) { \"#{scalar.type}(\#{v})\" } emits any expression), or register " \
      "a type the wire already parses into"
  rescue ::NameError
    nil # a type: given as a String names a class this process may not have
  end

  # An unregistered custom scalar passes through as T.untyped — legitimate
  # (nobody needs a codec for every scalar), but it's the one hole in an
  # otherwise exact result type, so name the holes rather than leave them
  # silent. Informational: not a warning, never an error.
  def report_untyped_scalars
    names = @untyped_scalars.uniq.sort
    return if names.empty?

    GraphWeaver.log(:info) do
      "#{names.size} unregistered custom scalar#{"s" unless names.one?} → T.untyped: " \
        "#{names.join(", ")} (register with GraphWeaver.register_scalar)"
    end
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

  # A generated type is named for the response key that selects it, camelized
  # (`stargazers` => Stargazers) — a function of the field's own position and
  # nothing else, so adding, removing, or reordering an unrelated selection can
  # never rename it. Generated code is app-code API; a name that shifts under
  # an unrelated edit is a silent break. `taken` is the names claimed in this
  # struct's scope, its first entry the struct itself.
  #
  # (Union members are the exception: they are named for the type condition
  # that produces them, which is equally position-determined.)
  def pick_name(key, taken)
    name = camelize(key)

    # a key that camelizes to no constant at all ("_", "_1") would emit
    # `class  < T::Struct`
    unless name.match?(/\A[A-Z]/)
      raise GraphWeaver::Error,
        "result key #{key.inspect} makes no class name (#{name.inspect}) — alias it to one starting with a letter"
    end

    if name == taken.first
      # would shadow the struct it nests in — the parent's own `returns(Name)`
      # resolves lexically and would find the child
      suffix = 2
      suffix += 1 while taken.include?("#{name}#{suffix}")
      name = "#{name}#{suffix}"
    elsif taken.include?(name)
      raise GraphWeaver::Error,
        "result keys on #{taken.first} both generate the class #{name} — alias one to a distinct name"
    end

    taken << name
    name
  end

  # Fields whose union selections are structurally identical share one Ruby
  # type; name it for the alphabetically first of their keys, so which field
  # the walk happened to reach first doesn't decide.
  def rename_union(union, key, taken)
    taken.delete(union.class_name)
    union.class_name = pick_name(key, taken)
  end
end
