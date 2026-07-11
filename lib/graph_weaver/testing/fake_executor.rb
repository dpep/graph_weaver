# typed: true
# frozen_string_literal: true

require "graphql"

# An executor that fabricates schema-correct responses for whatever query
# arrives — the zero-setup way to test code built on generated modules:
#
#   fake = GraphWeaver::Testing::FakeExecutor.new(schema:)
#   result = PersonQuery.execute!(id: "1", executor: fake)
#   result.person.name  # => a plausible String, typed and castable
#
# Values are type-correct by construction (real enum values, valid
# __typename members for unions/interfaces, iso8601 for date scalars), so
# every fake response casts cleanly through the generated structs. With
# the faker gem loaded, string and numeric fields get semantic values
# matched on the field name (name/email/url/age/price/...) — see Values.
#
# overrides: pin fields by GraphQL name — schema vocabulary, so keys
# survive query refactors. "Type.field" beats "field"; values are
# literals or zero-arg procs:
#
#   FakeExecutor.new(schema:, overrides: {
#     "Person.name" => "Daniel",
#     "email" => -> { "test@example.com" },
#   })
#
# seed: makes a run reproducible (also seeds faker). Per-executor options
# fall back to GraphWeaver::Testing.config.
class GraphWeaver::Testing::FakeExecutor
  def initialize(schema:, overrides: {}, seed: nil, faker: nil, list_size: nil, null_chance: nil)
    config = GraphWeaver::Testing.config
    @schema = schema
    @overrides = config.overrides.merge(overrides)
    @values = GraphWeaver::Testing::Values.new(seed:, faker:)
    @list_size = list_size || config.list_size
    @null_chance = null_chance || config.null_chance
  end

  def execute(query, variables: {})
    doc = GraphQL.parse(query)
    @fragments = doc.definitions
      .grep(GraphQL::Language::Nodes::FragmentDefinition)
      .to_h { |fragment| [fragment.name, fragment] }

    operation = doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).first
    root_type = operation&.operation_type == "mutation" ? @schema.mutation : @schema.query

    { "data" => object_value(root_type, operation.selections) }
  end

  private

  def rng = @values.rng

  def object_value(type, selections)
    result = {}
    each_field(type, selections) do |key, node|
      result[key] = node.name == "__typename" ? type.graphql_name : field_value(type, node)
    end

    result
  end

  # walk a selection set as seen by `type`, flattening fragments — the
  # same rules codegen applies
  def each_field(type, selections, &block)
    selections.each do |selection|
      case selection
      when GraphQL::Language::Nodes::Field
        yield(selection.alias || selection.name, selection)
      when GraphQL::Language::Nodes::InlineFragment
        each_field(type, selection.selections, &block) if applies?(selection.type&.name, type)
      when GraphQL::Language::Nodes::FragmentSpread
        fragment = @fragments.fetch(selection.name)
        each_field(type, fragment.selections, &block) if applies?(fragment.type.name, type)
      end
    end
  end

  def applies?(condition, type)
    return true if condition.nil? || condition == type.graphql_name

    condition_type = @schema.get_type(condition)
    return false unless condition_type

    kind = condition_type.kind.name
    (kind == "INTERFACE" || kind == "UNION") &&
      @schema.possible_types(condition_type).include?(type)
  end

  def field_value(parent_type, node)
    override = @overrides.fetch("#{parent_type.graphql_name}.#{node.name}") do
      @overrides[node.name]
    end
    return override.is_a?(Proc) ? override.call : override unless override.nil?

    type_value(@schema.get_field(parent_type.graphql_name, node.name).type, node)
  end

  def type_value(type, node, non_null: false)
    case type.kind.name
    when "NON_NULL"
      type_value(type.of_type, node, non_null: true)
    when "LIST"
      Array.new(rng.rand(@list_size)) { type_value(type.of_type, node) }
    else
      return if !non_null && rng.rand < @null_chance

      core_value(type, node)
    end
  end

  def core_value(type, node)
    case type.kind.name
    when "SCALAR"
      @values.scalar(type.graphql_name, node.name)
    when "ENUM"
      type.values.keys.sort.sample(random: rng)
    when "OBJECT"
      object_value(type, node.selections)
    when "UNION", "INTERFACE"
      member = @schema.possible_types(type).sort_by(&:graphql_name).sample(random: rng)
      object_value(member, node.selections)
    else
      raise NotImplementedError, "cannot fake kind: #{type.kind.name}"
    end
  end
end
