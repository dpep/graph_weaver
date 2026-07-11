# typed: true
# frozen_string_literal: true

require "graphql"
require "json"

# An executor that fabricates schema-correct responses for whatever query
# arrives — the zero-setup way to test code built on generated modules:
#
#   fake = GraphWeaver::Testing::FakeExecutor.new(schema:)
#   result = PersonQuery.execute!(id: "1", executor: fake)
#   result.person.name  # => a plausible String, typed and castable
#
# Values are type-correct by construction (real enum values, valid
# __typename members for unions/interfaces, iso8601 for date scalars), so
# every fake response casts cleanly through the generated structs. See
# Values for value fabrication (mode: :faker / :literal).
#
# overrides: pin fields by GraphQL name — schema vocabulary, so keys
# survive query refactors. "Type.field" beats "field"; values are
# literals or zero-arg procs. (An override with a wrong-typed value is
# also the way to simulate a corrupt payload — casting raises
# GraphWeaver::TypeError.)
#
#   FakeExecutor.new(schema:, overrides: {
#     "Person.name" => "Daniel",
#     "email" => -> { "test@example.com" },
#   })
#
# Partial failures: fail_at simulates a field-level error with
# spec-correct null propagation — the field's error lands in the errors
# array (with its concrete path), the field becomes null, and nulls
# bubble past non-null positions to the nearest nullable ancestor, just
# like a real server:
#
#   FakeExecutor.new(schema:, fail_at: "person.pets.name")
#   FakeExecutor.new(schema:, fail_at: { path: "person.email", message: "hidden", code: "PRIVATE" })
#
# errors: appends verbatim top-level errors alongside the fake data.
#
# Type mismatches: corrupt: names fields ("Type.field") that should
# arrive wire-corrupted — a wrong-typed value derived from the schema,
# so casting raises GraphWeaver::TypeError. One spec checks the failure
# path; every other spec gets working data:
#
#   FakeExecutor.new(schema:, corrupt: "Person.birthday")
#
# seed: makes a run reproducible (also seeds faker). Per-executor options
# fall back to GraphWeaver::Testing.config.
class GraphWeaver::Testing::FakeExecutor
  # sentinel: a simulated failure bubbling up to the nearest nullable spot
  NULL_BUBBLE = Object.new.freeze

  def initialize(schema:, overrides: {}, seed: nil, mode: nil, list_size: nil, null_chance: nil,
    errors: nil, fail_at: nil, corrupt: nil)
    config = GraphWeaver::Testing.config
    @schema = schema
    @overrides = config.overrides.merge(overrides)
    @values = GraphWeaver::Testing::Values.new(seed:, mode:)
    @list_size = list_size || config.list_size
    @null_chance = null_chance || config.null_chance
    # NOT Array(): it would explode a bare Hash into key/value pairs
    @extra_errors = wrap(errors).map { |error| normalize_error(error) }
    @fail_at = wrap(fail_at).map { |spec| normalize_fail_spec(spec) }
    @corrupt = wrap(corrupt)
  end

  def execute(query, variables: {})
    doc = GraphQL.parse(query)
    @fragments = doc.definitions
      .grep(GraphQL::Language::Nodes::FragmentDefinition)
      .to_h { |fragment| [fragment.name, fragment] }

    operation = doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).first
    root_type = operation&.operation_type == "mutation" ? @schema.mutation : @schema.query

    @path = []
    @failures = []
    data = object_value(root_type, operation.selections)
    data = nil if data.equal?(NULL_BUBBLE) # total propagation, like a real server

    response = { "data" => data }
    errors = @failures + @extra_errors
    response["errors"] = errors unless errors.empty?
    response
  end

  private

  def rng = @values.rng

  def wrap(value)
    case value
    when nil then []
    when Array then value
    else [value]
    end
  end

  def normalize_error(error)
    error.is_a?(String) ? { "message" => error } : JSON.parse(JSON.generate(error))
  end

  def normalize_fail_spec(spec)
    spec.is_a?(String) ? { "path" => spec } : JSON.parse(JSON.generate(spec))
  end

  def object_value(type, selections)
    result = {}
    each_field(type, selections) do |key, node|
      @path.push(key)
      value = node.name == "__typename" ? type.graphql_name : field_value(type, node)
      @path.pop

      if value.equal?(NULL_BUBBLE)
        # bubble past non-null fields to the nearest nullable ancestor
        return NULL_BUBBLE if non_null_field?(type, node)

        value = nil
      end
      result[key] = value
    end

    result
  end

  def non_null_field?(type, node)
    return false if node.name == "__typename"

    @schema.get_field(type.graphql_name, node.name).type.kind.name == "NON_NULL"
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
    if (spec = matching_failure)
      @failures << {
        "message" => spec["message"] || "simulated failure",
        "path" => @path.dup,
      }.merge(spec["code"] ? { "extensions" => { "code" => spec["code"] } } : {})
      spec["triggered"] = true

      return NULL_BUBBLE
    end

    override = @overrides.fetch("#{parent_type.graphql_name}.#{node.name}") do
      @overrides[node.name]
    end
    return override.is_a?(Proc) ? override.call : override unless override.nil?

    field_type = @schema.get_field(parent_type.graphql_name, node.name).type
    if @corrupt.include?("#{parent_type.graphql_name}.#{node.name}")
      return corrupt_value(field_type)
    end

    type_value(field_type, node)
  end

  # a value casting can't accept, derived from the field's own type — and
  # wrapped per list layer so the corruption lands on the element cast
  def corrupt_value(type)
    case type.kind.name
    when "NON_NULL" then corrupt_value(type.of_type)
    when "LIST" then [corrupt_value(type.of_type)]
    when "SCALAR"
      case type.graphql_name
      when "Int", "Float" then "not-a-number"
      when "Boolean" then "not-a-boolean"
      else 123 # breaks String/ID props and every string-wire custom scalar
      end
    when "ENUM" then "__NOT_A_REAL_VALUE__"
    else [] # objects/unions: an Array fails Hash-shaped casting loudly
    end
  end

  # first untriggered fail_at spec whose field chain (indices stripped)
  # matches where we are
  def matching_failure
    chain = @path.reject { |segment| segment.is_a?(Integer) }.join(".")
    @fail_at.find { |spec| !spec["triggered"] && spec["path"] == chain }
  end

  def type_value(type, node, non_null: false)
    case type.kind.name
    when "NON_NULL"
      type_value(type.of_type, node, non_null: true)
    when "LIST"
      elements = Array.new(rng.rand(@list_size)) do |index|
        @path.push(index)
        element = type_value(type.of_type, node)
        @path.pop
        element
      end

      if elements.any? { |element| element.equal?(NULL_BUBBLE) }
        # non-null elements bubble the whole list; nullable ones go nil
        return NULL_BUBBLE if type.of_type.kind.name == "NON_NULL"

        elements.map! { |element| element.equal?(NULL_BUBBLE) ? nil : element }
      end
      elements
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
