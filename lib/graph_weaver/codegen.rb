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
  # name). scalars: is a client-scoped overlay ({name => ScalarType})
  # consulted before the global registry.
  def initialize(schema:, query:, module_name: nil, executor: nil, default_module_name: nil, scalars: nil)
    @schema = schema
    @query = query.strip
    @module_name = module_name
    @default_module_name = default_module_name
    @scalars = scalars || {}
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
  def self.generate(schema:, query:, module_name: nil, executor: nil, scalars: nil)
    new(schema:, query:, module_name:, executor:, scalars:).generate
  end

  # Development convenience: generate + eval in one step, no build
  # artifact or checked-in file. Same runtime semantics as the generated
  # file, but invisible to srb tc — use the build step for static typing.
  # Evaluates into an anonymous container, so no global constants leak;
  # executor: additionally accepts a live object (set via .executor=).
  def self.parse(schema:, query:, module_name: nil, executor: nil, scalars: nil)
    executor_const = executor_const(executor)

    codegen = new(schema:, query:, module_name:, executor: executor_const, default_module_name: "Query", scalars:)
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
    errors = @schema.validate(@query)
    if errors.any?
      raise GraphWeaver::ValidationError.new(errors.map { |e| validation_detail(e) })
    end

    @variable_enums = {}
    @variable_inputs = {}
    @inputs_in_progress = []
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
    @variable_enums.each_value do |enum|
      emit_enum(enum, out, 1)
      out << ""
    end
    @variable_inputs.each_value do |input|
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
          name = pick_name(core.graphql_name, key, taken)
          type_ref(field_type) { union_node(core, sub_selections, name) }
        when "ENUM"
          name = pick_name(core.graphql_name, key, taken)
          # sorted so output is deterministic across schema sources
          # (SDL round-trips reorder values alphabetically)
          type_ref(field_type) { EnumNode.new(name, core.values.keys.sort) }
        when "SCALAR"
          type_ref(field_type) { scalar_node(core.graphql_name) }
        else
          raise NotImplementedError, "unsupported kind: #{core.kind.name}"
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

  # Abstract types (unions AND interfaces): one member struct per
  # possible type; wire dispatch reads __typename, so the query must
  # select it. For interfaces, the interface's own field selections
  # gather into every member.
  def union_node(type, selections, class_name)
    unless gather(type, selections).key?("__typename")
      raise ArgumentError, "select __typename on #{type.graphql_name} so #{class_name} can dispatch"
    end

    # sorted so output is deterministic across schema sources
    members = @schema.possible_types(type).sort_by(&:graphql_name).to_h do |possible|
      [possible.graphql_name, object_node(possible, selections, possible.graphql_name)]
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
      raise NotImplementedError, "unsupported type node: #{ast_type.class}"
    end
  end

  # the input-side core kinds a variable (or input-object field) can have
  def variable_core(core)
    case core.kind.name
    when "SCALAR"
      scalar_node(core.graphql_name)
    when "ENUM"
      @variable_enums[core.graphql_name] ||=
        EnumNode.new(core.graphql_name, core.values.keys.sort)
    when "INPUT_OBJECT"
      input_node(core)
    else
      raise NotImplementedError, "unsupported variable kind: #{core.kind.name}"
    end
  end

  # A module-level T::Struct per input type, with a serialize method
  # producing the wire hash. Registered once per type; nested inputs
  # register their dependencies first (insertion order = emission order).
  def input_node(core)
    return @variable_inputs[core.graphql_name] if @variable_inputs.key?(core.graphql_name)

    if @inputs_in_progress.include?(core.graphql_name)
      raise NotImplementedError, "recursive input type: #{core.graphql_name}"
    end
    @inputs_in_progress << core.graphql_name

    node = InputNode.new(core.graphql_name)
    # sorted so output is deterministic across schema sources
    core.arguments.values.sort_by(&:graphql_name).each do |argument|
      child = type_ref(argument.type) { variable_core(unwrap(argument.type)) }
      required = child.non_null? && !argument.default_value?
      node.fields << InputNode::Field.new(
        underscore(argument.graphql_name), argument.graphql_name, child, required
      )
    end

    @inputs_in_progress.delete(core.graphql_name)
    @variable_inputs[core.graphql_name] = node
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

  def pick_name(type_name, key, taken)
    candidate = type_name
    candidate = "#{camelize(key)}#{type_name}" if taken.include?(candidate)
    raise NotImplementedError, "class name collision: #{candidate}" if taken.include?(candidate)

    taken << candidate
    candidate
  end

end
