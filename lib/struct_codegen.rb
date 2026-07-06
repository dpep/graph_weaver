# typed: true
# frozen_string_literal: true

require "active_support/inflector"
require "graphql"
require "sorbet-runtime"

# Generates plain, statically-typecheckable Ruby from a GraphQL query +
# schema: nested T::Structs, from_h casting code, and a sig'd execute
# method. Unlike StructTypes (which builds classes at parse time, visible
# only at runtime), the output is source on disk — srb tc sees the exact
# result type of each query.
#
# Supports plain fields, inline fragments, named fragment spreads
# (including interface type conditions), unions (dispatch on __typename),
# and enums (generated T::Enum). Interface-typed *fields* are still open.
class StructCodegen
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

  def generate
    errors = @schema.validate(@query)
    if errors.any?
      raise ArgumentError, "invalid query: #{errors.map(&:message).join("; ")}"
    end

    doc = GraphQL.parse(@query)
    @fragments = doc.definitions
      .grep(GraphQL::Language::Nodes::FragmentDefinition)
      .to_h { |fragment| [fragment.name, fragment] }

    operation = doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).first
    unless operation&.operation_type == "query"
      raise ArgumentError, "expected a query operation"
    end

    root = object_node(@schema.query, operation.selections, "Result")

    out = []
    out << "# typed: strict"
    out << "# frozen_string_literal: true"
    out << ""
    out << "# Generated by StructCodegen — do not edit."
    out << ""
    out << "module #{@module_name}"
    out << "  extend T::Sig"
    out << ""
    out << "  QUERY = T.let(<<~'GRAPHQL', String)"
    @query.each_line { |line| out << "    #{line}".rstrip }
    out << "  GRAPHQL"
    out << ""
    emit_nested(root, out, 1)
    out << ""
    out << "  sig { params(variables: T::Hash[String, T.untyped], executor: T.untyped).returns(Result) }"
    out << "  def self.execute(variables = {}, executor: #{@executor_const})"
    out << "    result = executor.execute(QUERY, variables: variables).to_h"
    out << "    if (errors = result[\"errors\"])"
    out << "      raise \"query failed: \#{errors.inspect}\""
    out << "    end"
    out << ""
    out << "    Result.from_h(result.fetch(\"data\"))"
    out << "  end"
    out << "end"

    out.join("\n") + "\n"
  end

  private

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
      prop = ActiveSupport::Inflector.underscore(key)

      child = if field_name == "__typename"
        NonNull.new(Scalar.new("String"))
      else
        field_type = @schema.get_field(type.graphql_name, field_name).type
        sub_selections = field_nodes.flat_map(&:selections)

        case (core = unwrap(field_type)).kind.name
        when "OBJECT"
          name = pick_name(core.graphql_name, key, taken)
          type_ref(field_type) { object_node(core, sub_selections, name) }
        when "UNION"
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

  # One member struct per possible type; wire dispatch reads __typename,
  # so the query must select it on the union.
  def union_node(type, selections, class_name)
    unless gather(type, selections).key?("__typename")
      raise ArgumentError, "select __typename on #{type.graphql_name} so #{class_name} can dispatch"
    end

    members = @schema.possible_types(type).to_h do |possible|
      [possible.graphql_name, object_node(possible, selections, possible.graphql_name)]
    end

    UnionNode.new(class_name, members)
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
    candidate = "#{ActiveSupport::Inflector.camelize(key)}#{type_name}" if taken.include?(candidate)
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
      out << "#{pad}    #{ActiveSupport::Inflector.camelize(value.downcase)} = new(#{value.inspect})"
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
