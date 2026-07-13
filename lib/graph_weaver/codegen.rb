# typed: true
# frozen_string_literal: true

require "date"
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

  # An executor is anything responding to `execute(query, variables:)`
  # whose result `to_h`s into {"data" => ..., "errors" => ...}.
  #
  # executor: (a constant, or its name as a string) becomes the generated
  # module's default transport; when omitted, generated code falls back
  # to GraphWeaver.executor. module_name: defaults to the operation's
  # name; default_module_name: is parse's container-scoped fallback (file
  # generation stays strict — a checked-in file deserves a deliberate
  # name). scalars:/enums:/types: are client-scoped overlays consulted
  # before the global registries (ScalarType, EnumType, and arrays of
  # mixin modules, each keyed by GraphQL name).
  def initialize(schema:, query:, module_name: nil, executor: nil, default_module_name: nil,
    scalars: nil, enums: nil, types: nil)
    @schema = schema
    @query = query.strip
    @module_name = module_name
    @default_module_name = default_module_name
    @scalars = scalars || {}
    @enums = enums || {}
    @types = types || {}
    @executor_const = self.class.executor_const(executor)

    if executor && @executor_const.nil?
      # a live object can't be spelled in generated source — parse can
      # set one via the module's writer, but file generation cannot
      raise ArgumentError, "executor: must be a named constant or String (got #{executor.inspect}); pass live objects to parse"
    end
  end

  # The constant name an executor can be referenced by in generated
  # source — nil when it can't be (live objects, anonymous modules).
  def self.executor_const(executor)
    case executor
    when String then executor
    when Module then executor.name
    end
  end

  # one-step shorthand
  def self.generate(schema:, query:, module_name: nil, executor: nil, scalars: nil, enums: nil, types: nil)
    new(schema:, query:, module_name:, executor:, scalars:, enums:, types:).generate
  end

  # Development convenience: generate + eval in one step, no build
  # artifact or checked-in file. Same runtime semantics as the generated
  # file, but invisible to srb tc — use the build step for static typing.
  # Evaluates into an anonymous container, so no global constants leak;
  # executor: additionally accepts a live object (set via .executor=).
  def self.parse(schema:, query:, module_name: nil, executor: nil, scalars: nil, enums: nil, types: nil)
    executor_const = executor_const(executor)

    codegen = new(schema:, query:, module_name:, executor: executor_const, default_module_name: "Query",
      scalars:, enums:, types:)
    source = codegen.generate

    container = Module.new
    container.module_eval(source, "(graph_weaver)", 1)
    mod = container.const_get(codegen.module_name)
    # live objects (or anonymous modules) can't be referenced from
    # generated source — set them via the module's writer instead
    mod.executor = executor if executor && executor_const.nil?
    mod
  end

  VarDef = Struct.new(:kwarg, :wire, :node, :required)

  def generate
    begin
      errors = @schema.validate(@query)
    rescue GraphQL::ParseError => e
      # unparseable queries wrap like invalid ones — everything raised
      # here descends from GraphWeaver::Error (or ArgumentError)
      raise GraphWeaver::ValidationError.new([{ message: e.message, line: nil, column: nil }])
    end
    if errors.any?
      raise GraphWeaver::ValidationError.new(errors.map { |e| validation_detail(e) })
    end

    validate_registrations!

    @variable_enums = {}
    @variable_inputs = {}
    @mapped_enums = {}
    # requires contributed by the custom scalars this query actually uses
    @scalar_requires = []

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
      VarDef.new(underscore(var.name), var.name, node, required)
    end

    root = object_node(root_type, operation.selections, "Result")

    out = []
    out << "# typed: strict"
    out << "# frozen_string_literal: true"
    out << ""
    out << "# Generated by GraphWeaver — do not edit."
    out << ""
    requires = @scalar_requires.uniq.sort
    if requires.any?
      requires.each { |req| out << "require #{req.inspect}" }
      out << ""
    end
    out << "module #{@module_name}"
    out << "  extend T::Sig"
    out << ""
    # a GraphQL block string could contain a bare GRAPHQL line, which
    # would terminate the heredoc early — pick a delimiter the query
    # can't collide with
    delimiter = "GRAPHQL"
    delimiter += "_" while @query.match?(/^\s*#{delimiter}\s*$/)
    out << "  QUERY = T.let(<<~'#{delimiter}', String)"
    @query.each_line { |line| out << "    #{line}".rstrip }
    out << "  #{delimiter}"
    out << ""
    @mapped_enums.each_value do |mapped|
      emit_mapped_enum(mapped, out, 1)
      out << ""
    end
    @variable_enums.each_value do |enum|
      emit_enum(enum, out, 1)
      out << ""
    end
    inputs, cyclic = ordered_inputs
    if cyclic
      # Recursive input types (Hasura bool_exp et al) reference each other,
      # so no definition order satisfies the runtime — forward-declare every
      # class empty, then let the full definitions below reopen with props.
      # eval'd so srb sees only the full bodies (reopening a T::Struct to
      # add props is a static error; adding them at runtime is fine).
      out << "  # runtime-only forward declarations: these input types reference"
      out << "  # each other, so the full definitions below need the constants"
      out << "  eval(<<~RUBY, binding, __FILE__, __LINE__ + 1)"
      inputs.each { |input| out << "    class #{input.class_name} < T::Struct; end" }
      out << "  RUBY"
      out << ""
    end
    inputs.each do |input|
      emit_input(input, out, 1)
      out << ""
    end
    emit_nested(root, out, 1)
    out << ""
    emit_execute(out, variables, flatten: flatten_input(variables))
    out << "end"

    out.join("\n") + "\n"
  end

  private

  # Client-scoped registrations name types in THIS schema — a typo'd
  # name would otherwise be a silent no-op, the most confusing failure
  # mode available. (Global registrations skip this: they may target a
  # different client's server.)
  def validate_registrations!
    { "enum" => @enums, "type" => @types }.each do |kind, registry|
      registry.each_key do |name|
        next if @schema.get_type(name)

        suggestion = defined?(DidYouMean::SpellChecker) &&
          DidYouMean::SpellChecker.new(dictionary: @schema.types.keys).correct(name).first
        hint = suggestion ? " — did you mean '#{suggestion}'?" : ""
        raise GraphWeaver::Error, "register_#{kind}(#{name.inspect}) matches no type in this schema#{hint}"
      end
    end
  end

  # The Relay convention — an operation whose only variable is a required
  # input object — reads better flattened: the input's fields become
  # execute's kwargs directly, and the wrapping level is rebuilt on the
  # wire. Multi-variable (or nullable-input) operations keep the
  # variable-per-kwarg surface; "executor" is a reserved kwarg.
  def flatten_input(variables)
    return unless variables.size == 1

    var = variables.first
    return unless var.required && var.node.is_a?(NonNull)

    input = var.node.of
    return unless input.is_a?(InputNode)
    return if input.fields.any? { |field| field.prop == "executor" }

    input
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
            # when the runtime type doesn't match (narrowing filters)
            name = pick_name(member.graphql_name, key, taken)
            nilable_type_ref(field_type) { NarrowedNode.new(object_node(member, sub_selections, name)) }
          else
            name = pick_name(core.graphql_name, key, taken)
            type_ref(field_type) { union_node(core, sub_selections, name) }
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
          type_ref(field_type) { scalar_node(core.graphql_name) }
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

    node
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
  def union_node(type, selections, class_name)
    unless gather(type, selections).key?("__typename")
      raise ArgumentError,
        "select __typename on #{type.graphql_name} so #{class_name} can dispatch — " \
        "or narrow to a single `... on Type` condition (no dispatch needed)"
    end

    # sorted so output is deterministic across schema sources
    members = @schema.possible_types(type).sort_by(&:graphql_name).to_h do |possible|
      [possible.graphql_name, object_node(possible, selections, camelize(possible.graphql_name))]
    end

    UnionNode.new(class_name, members)
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
      child = type_ref(argument.type) { variable_core(unwrap(argument.type)) }
      required = child.non_null? && !argument.default_value?
      node.fields << InputNode::Field.new(
        underscore(argument.graphql_name), argument.graphql_name, child, required
      )
    end
    node
  end

  # The InputNodes a struct's fields reference, through NON_NULL/LIST
  # wrappers — the edges of the input dependency graph.
  def input_references(node)
    node.fields.filter_map do |field|
      child = field.node
      child = child.of while child.respond_to?(:of)
      child if child.is_a?(InputNode)
    end
  end

  # Input structs in dependency order (referenced types before their
  # referrers) so each emitted const names an already-defined class.
  # Cycles make that impossible — flagged so emission can forward-declare
  # every input class first, then reopen each to add its props.
  def ordered_inputs
    ordered = []
    visiting = []
    cyclic = T.let(false, T::Boolean)

    visit = lambda do |node|
      next if ordered.include?(node)

      if visiting.include?(node)
        cyclic = true
        next
      end

      visiting << node
      input_references(node).each(&visit)
      visiting.delete(node)
      ordered << node
    end
    @variable_inputs.each_value(&visit)

    [ordered, cyclic]
  end

  # Registered helper-module names for a GraphQL type (additive: global
  # registrations plus this client's), collecting their requires.
  def type_mixins(graphql_name)
    entries = [GraphWeaver::Codegen.type_registry[graphql_name], @types[graphql_name]].compact
    entries.each { |entry| @scalar_requires.concat(entry[:requires]) }
    entries.flat_map { |entry| entry[:mixins].map(&:name) }
  end

  # The MappedEnum node for a schema enum with a registered app-enum
  # mapping (client overlay first, then the global registry); nil when
  # unregistered, falling back to a generated T::Enum.
  def mapped_enum_node(core)
    enum_type = @enums[core.graphql_name] || GraphWeaver::Codegen.enum_registry[core.graphql_name]
    return unless enum_type

    @scalar_requires.concat(enum_type.requires)
    @mapped_enums[core.graphql_name] ||= MappedEnum.new(enum_type, core.values.keys.sort)
  end

  # A Scalar node, recording any requires its registered type needs so the
  # generated file can require them (collected across the whole query).
  # Resolution: the client-scoped overlay first, then the global registry.
  def scalar_node(name)
    scalar = @scalars[name.to_s] || GraphWeaver::Codegen.scalar(name)
    @scalar_requires.concat(scalar.requires)
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
