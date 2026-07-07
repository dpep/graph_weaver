# typed: true
# frozen_string_literal: true

require "graphql"
require "sorbet-runtime"

# Generates plain, statically-typecheckable Ruby from a GraphQL query +
# schema: nested T::Structs, from_h casting code, and a sig'd execute
# method. Unlike StructTypes (which builds classes at parse time, visible
# only at runtime), the output is source on disk — srb tc sees the exact
# result type of each query.
#
# Supports queries and mutations; plain fields, inline fragments, named
# fragment spreads (including interface type conditions), union- and
# interface-typed fields (dispatch on __typename), enums (generated
# T::Enum), and typed variables (kwargs on execute). Input objects and
# subscriptions are still open.
class GraphWeaver::Codegen
  # sorbet types for scalars
  SCALARS = {
    "ID" => "String",
    "String" => "String",
    "Int" => "Integer",
    "Float" => "Float",
    "Boolean" => "T::Boolean",
    "Date" => "Date",
  }.freeze

  # deserialization for scalars whose wire format differs from their Ruby
  # type; anything absent passes through untouched
  SCALAR_CASTS = {
    "Date" => ->(expr) { "Date.iso8601(#{expr})" },
  }.freeze

  # the inverse, for serializing variables onto the wire
  SCALAR_SERIALIZERS = {
    "Date" => ->(expr) { "#{expr}.iso8601" },
  }.freeze

  class Scalar
    def initialize(name)
      @name = name
    end

    def bare_type
      SCALARS.fetch(@name, "T.untyped")
    end

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, _depth)
      SCALAR_CASTS.fetch(@name) { return expr }.call(expr)
    end

    def identity?
      !SCALAR_CASTS.key?(@name)
    end

    def serialize(expr, _depth)
      SCALAR_SERIALIZERS.fetch(@name) { return expr }.call(expr)
    end

    def serialize_identity?
      !SCALAR_SERIALIZERS.key?(@name)
    end

    def non_null? = false
    def nested = nil
  end

  class NonNull
    def initialize(of)
      @of = of
    end

    def bare_type = @of.bare_type
    def prop_type = bare_type
    def cast(expr, depth) = @of.cast(expr, depth)
    def identity? = @of.identity?
    def serialize(expr, depth) = @of.serialize(expr, depth)
    def serialize_identity? = @of.serialize_identity?
    def non_null? = true
    def nested = @of.nested
  end

  class List
    def initialize(of)
      @of = of
    end

    def bare_type
      "T::Array[#{@of.prop_type}]"
    end

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, depth)
      var = "v#{depth}"
      element = if @of.non_null? || @of.identity?
        @of.identity? ? var : @of.cast(var, depth + 1)
      else
        "#{var}&.then { |v#{depth + 1}| #{@of.cast("v#{depth + 1}", depth + 2)} }"
      end

      "#{expr}.map { |#{var}| #{element} }"
    end

    def identity? = @of.identity?

    def serialize(expr, depth)
      var = "v#{depth}"
      element = if @of.non_null? || @of.serialize_identity?
        @of.serialize_identity? ? var : @of.serialize(var, depth + 1)
      else
        "#{var}&.then { |v#{depth + 1}| #{@of.serialize("v#{depth + 1}", depth + 2)} }"
      end

      "#{expr}.map { |#{var}| #{element} }"
    end

    def serialize_identity? = @of.serialize_identity?
    def non_null? = false
    def nested = @of.nested
  end

  class ObjectNode
    Field = Struct.new(:prop, :key, :node)

    attr_reader :class_name, :fields

    def initialize(class_name)
      @class_name = class_name
      @fields = []
    end

    def bare_type = class_name

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, _depth)
      "#{class_name}.from_h(#{expr})"
    end

    def identity? = false
    def non_null? = false
    def nested = self
  end

  class EnumNode
    attr_reader :class_name, :values

    def initialize(class_name, values)
      @class_name = class_name
      @values = values
    end

    def bare_type = class_name

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, _depth)
      "#{class_name}.deserialize(#{expr})"
    end

    def identity? = false

    def serialize(expr, _depth)
      "#{expr}.serialize"
    end

    def serialize_identity? = false
    def non_null? = false
    def nested = self
  end

  class UnionNode
    attr_reader :class_name, :members # graphql type name => ObjectNode

    def initialize(class_name, members)
      @class_name = class_name
      @members = members
    end

    def bare_type = "#{class_name}::Type"

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, _depth)
      "#{class_name}.from_h(#{expr})"
    end

    def identity? = false
    def non_null? = false
    def nested = self
  end

  # executor_const names anything responding to
  # `execute(query, variables:)` whose result `to_h`s into
  # {"data" => ..., "errors" => ...} — a Schema class for in-process
  # execution, or an HttpExecutor for a remote endpoint. The generated
  # execute also accepts an executor: override at runtime.
  def initialize(schema:, executor_const:, query:, module_name:)
    @schema = schema
    @executor_const = executor_const
    @query = query.strip
    @module_name = module_name
  end

  # Development convenience: generate + eval in one step, no build
  # artifact or checked-in file. Same runtime semantics as the generated
  # file, but invisible to srb tc — use the build step for static typing.
  def self.load(schema:, executor_const:, query:, module_name:)
    source = new(schema:, executor_const:, query:, module_name:).generate
    Object.class_eval(source, "(struct_codegen)", 1)
    Object.const_get(module_name)
  end

  VarDef = Struct.new(:kwarg, :wire, :node, :required)

  def generate
    errors = @schema.validate(@query)
    if errors.any?
      raise ArgumentError, "invalid query: #{errors.map(&:message).join("; ")}"
    end

    doc = GraphQL.parse(@query)
    @fragments = doc.definitions
      .grep(GraphQL::Language::Nodes::FragmentDefinition)
      .to_h { |fragment| [fragment.name, fragment] }
    @variable_enums = {}

    operation = doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).first
    root_type = case operation&.operation_type
    when "query", nil then @schema.query
    when "mutation" then @schema.mutation
    else raise NotImplementedError, "unsupported operation: #{operation.operation_type}"
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
    out << "module #{@module_name}"
    out << "  extend T::Sig"
    out << ""
    out << "  QUERY = T.let(<<~'GRAPHQL', String)"
    @query.each_line { |line| out << "    #{line}".rstrip }
    out << "  GRAPHQL"
    out << ""
    @variable_enums.each_value do |enum|
      emit_enum(enum, out, 1)
      out << ""
    end
    emit_nested(root, out, 1)
    out << ""
    emit_execute(out, variables)
    out << "end"

    out.join("\n") + "\n"
  end

  private

  # GraphQL names are plain camelCase/SCREAMING_SNAKE — no acronym edge
  # cases, so minimal inflection beats an activesupport dependency
  def underscore(name)
    name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
  end

  def camelize(name)
    name.split("_").map { |part| "#{part[0].upcase}#{part[1..]}" }.join
  end

  # Flatten a selection set as seen by `type`: plain fields collect
  # directly; inline fragments and named spreads recurse when their type
  # condition matches (exact name match — interface conditions are out of
  # scope for this spike).
  def gather(type, selections, out = {})
    selections.each do |selection|
      case selection
      when GraphQL::Language::Nodes::Field
        (out[selection.alias || selection.name] ||= []) << selection
      when GraphQL::Language::Nodes::InlineFragment
        gather(type, selection.selections, out) if applies?(selection.type&.name, type)
      when GraphQL::Language::Nodes::FragmentSpread
        fragment = @fragments.fetch(selection.name) do
          raise ArgumentError, "unknown fragment: #{selection.name}"
        end
        gather(type, fragment.selections, out) if applies?(fragment.type.name, type)
      else
        raise NotImplementedError, "unsupported selection: #{selection.class}"
      end
    end

    out
  end

  # A fragment's type condition applies when it names this type exactly,
  # or an interface/union this type belongs to (`... on Named { ... }`).
  def applies?(condition, type)
    return true if condition.nil? || condition == type.graphql_name

    condition_type = @schema.get_type(condition)
    return false unless condition_type

    kind = condition_type.kind.name
    (kind == "INTERFACE" || kind == "UNION") &&
      @schema.possible_types(condition_type).include?(type)
  end

  def object_node(type, selections, class_name)
    node = ObjectNode.new(class_name)
    taken = [class_name]

    gather(type, selections).each do |key, field_nodes|
      field_name = field_nodes.first.name
      prop = underscore(key)

      child = if field_name == "__typename"
        NonNull.new(Scalar.new("String"))
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
          type_ref(field_type) { Scalar.new(core.graphql_name) }
        else
          raise NotImplementedError, "unsupported kind: #{core.kind.name}"
        end
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
      core = @schema.get_type(ast_type.name)
      case core.kind.name
      when "SCALAR"
        Scalar.new(core.graphql_name)
      when "ENUM"
        @variable_enums[core.graphql_name] ||=
          EnumNode.new(core.graphql_name, core.values.keys.sort)
      else
        raise NotImplementedError, "unsupported variable kind: #{core.kind.name}"
      end
    else
      raise NotImplementedError, "unsupported type node: #{ast_type.class}"
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

  def emit_nested(node, out, indent)
    case node
    when UnionNode then emit_union(node, out, indent)
    when EnumNode then emit_enum(node, out, indent)
    else emit_object(node, out, indent)
    end
  end

  def emit_enum(node, out, indent)
    pad = "  " * indent

    out << "#{pad}class #{node.class_name} < T::Enum"
    out << "#{pad}  enums do"
    node.values.each do |value|
      out << "#{pad}    #{camelize(value.downcase)} = new(#{value.inspect})"
    end
    out << "#{pad}  end"
    out << "#{pad}end"
  end

  def emit_object(node, out, indent)
    pad = "  " * indent

    out << "#{pad}class #{node.class_name} < T::Struct"
    out << "#{pad}  extend T::Sig"
    out << ""

    node.fields.filter_map { |field| field.node.nested }.each do |child|
      emit_nested(child, out, indent + 1)
      out << ""
    end

    node.fields.each do |field|
      out << "#{pad}  const :#{field.prop}, #{field.node.prop_type}"
    end

    out << ""
    out << "#{pad}  sig { params(data: T::Hash[String, T.untyped]).returns(#{node.class_name}) }"
    out << "#{pad}  def self.from_h(data)"
    out << "#{pad}    new("
    node.fields.each do |field|
      out << "#{pad}      #{field.prop}: #{field_cast(field)},"
    end
    out << "#{pad}    )"
    out << "#{pad}  end"
    out << "#{pad}end"
  end

  def emit_union(node, out, indent)
    pad = "  " * indent

    out << "#{pad}module #{node.class_name}"
    out << "#{pad}  extend T::Sig"
    out << ""

    node.members.each_value do |member|
      emit_object(member, out, indent + 1)
      out << ""
    end

    member_names = node.members.values.map(&:class_name)
    type_alias = member_names.size == 1 ? member_names.first : "T.any(#{member_names.join(", ")})"
    out << "#{pad}  Type = T.type_alias { #{type_alias} }"
    out << ""
    out << "#{pad}  sig { params(data: T::Hash[String, T.untyped]).returns(Type) }"
    out << "#{pad}  def self.from_h(data)"
    out << "#{pad}    case (typename = data.fetch(\"__typename\"))"
    node.members.each do |graphql_name, member|
      out << "#{pad}    when #{graphql_name.inspect} then #{member.class_name}.from_h(data)"
    end
    out << "#{pad}    else raise \"unexpected __typename: \#{typename}\""
    out << "#{pad}    end"
    out << "#{pad}  end"
    out << "#{pad}end"
  end

  def emit_execute(out, variables)
    sig_params = variables.map do |var|
      kwarg_type = var.required ? var.node.prop_type : "T.nilable(#{var.node.bare_type})"
      "#{var.kwarg}: #{kwarg_type}"
    end
    sig_params << "executor: T.untyped"

    kwargs = variables.map { |var| var.required ? "#{var.kwarg}:" : "#{var.kwarg}: nil" }
    kwargs << "executor: #{@executor_const}"

    out << "  sig { params(#{sig_params.join(", ")}).returns(Result) }"
    out << "  def self.execute(#{kwargs.join(", ")})"

    required, optional = variables.partition(&:required)
    if required.empty?
      out << "    variables = {}"
    else
      out << "    variables = {"
      required.each do |var|
        out << "      #{var.wire.inspect} => #{variable_serialize(var)},"
      end
      out << "    }"
    end
    optional.each do |var|
      out << "    variables[#{var.wire.inspect}] = #{variable_serialize(var)} unless #{var.kwarg}.nil?"
    end

    out << ""
    out << "    result = executor.execute(QUERY, variables: variables).to_h"
    out << "    if (errors = result[\"errors\"])"
    out << "      raise \"query failed: \#{errors.inspect}\""
    out << "    end"
    out << ""
    out << "    Result.from_h(result.fetch(\"data\"))"
    out << "  end"
  end

  def variable_serialize(var)
    var.node.serialize_identity? ? var.kwarg : var.node.serialize(var.kwarg, 1)
  end

  def field_cast(field)
    node = field.node

    if node.non_null?
      raw = "data.fetch(#{field.key.inspect})"
      node.identity? ? raw : node.cast(raw, 1)
    else
      raw = "data[#{field.key.inspect}]"
      node.identity? ? raw : "#{raw}&.then { |v1| #{node.cast("v1", 2)} }"
    end
  end
end
