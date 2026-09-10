# typed: true
# frozen_string_literal: true

require "graphql"
require "json"

require_relative "../parsing"

# A fake client that fabricates schema-correct responses for whatever query
# arrives — the zero-setup way to test code built on generated modules:
#
#      fake = GraphWeaver::Testing::FakeClient.new
#      result = PersonQuery.execute!(client: fake, id: "1")
#      result.person.name  # => a plausible String, typed and castable
#
# Values are type-correct by construction (real enum values, valid
# __typename members for unions/interfaces, iso8601 for date scalars), so
# every fake response casts cleanly through the generated structs.
#
# values: how they're written — :faker (semantic, matched on the field
# name), :literal (plain type-derived), or nil to use faker when the gem is
# loaded. Per fake: which reads better is one example's question.
#
# overrides: pin fields by GraphQL name — schema vocabulary, so keys
# survive query refactors. "Type.field" beats "field"; values are
# literals or zero-arg procs. Keys are checked against the schema, since
# a typo'd one would pin nothing and leave the test green. (An override
# with a wrong-typed value is also the way to simulate a corrupt
# payload — casting raises GraphWeaver::TypeError.)
#
#      FakeClient.new(schema:, overrides: {
#        "Person.name" => "Daniel",
#        "email" => -> { "test@example.com" },
#      })
#
# An override pins a whole subtree as readily as a leaf, and **merges**
# rather than replaces: name the fields the test is about and the rest of
# the selection is still fabricated. A list pins its own length, so "two
# orders, the first one paid" is the literal thing you write:
#
#      FakeClient.new(schema:, overrides: {
#        "Reader.name" => "Ada",
#        "Reader.orders" => [{ "status" => "PAID" }, {}],
#      })
#
# Keys inside a pinned subtree are response keys — what comes back on the
# wire, aliases included — and one the query doesn't select is refused,
# for the same reason a typo'd coordinate is.
#
# requests: every execute, in order ({ query:, variables:, operation_name: })
# — "did we send the right variables", and "did we call it at all".
#
# Partial failures: fail_at simulates a field-level error with
# spec-correct null propagation — the field's error lands in the errors
# array (with its concrete path), the field becomes null, and nulls
# bubble past non-null positions to the nearest nullable ancestor, just
# like a real server:
#
#      FakeClient.new(schema:, fail_at: "person.pets.name")
#      FakeClient.new(schema:, fail_at: { path: "person.email", message: "hidden", code: "PRIVATE" })
#
# errors: appends verbatim top-level errors alongside the fake data.
#
# Type mismatches: corrupt: names fields ("Type.field") that should
# arrive wire-corrupted — a wrong-typed value derived from the schema,
# so casting raises GraphWeaver::TypeError. One spec checks the failure
# path; every other spec gets working data:
#
#      FakeClient.new(schema:, corrupt: "Person.birthday")
#
# null_chance: how often a nullable field comes back null — 0 by default,
# and per fake only: "does this render with no email" is one example's
# question, and a suite-wide answer would sprinkle nils through every other
# example instead.
#
#      FakeClient.new(schema:, null_chance: 1.0)   # everything nullable, null
#
# seed: makes a run reproducible (also seeds faker). schema:, overrides:
# and list_size: fall back to GraphWeaver::Testing.config — and the
# config's schema falls back to the committed dump.
class GraphWeaver::Testing::FakeClient
  include GraphWeaver::Parsing
  include GraphWeaver::Internal::Selection

  # sentinel: a simulated failure bubbling up to the nearest nullable spot
  NULL_BUBBLE = Object.new.freeze
  private_constant :NULL_BUBBLE

  # sentinel: no override here — distinct from an override OF nil, which
  # pins the field null
  UNPINNED = Object.new.freeze
  private_constant :UNPINNED

  # the schema responses are fabricated against — the way to reach it from
  # a graphql: :fake spec, where GraphWeaver.client is one of these
  attr_reader :schema

  # Every execute, in order: { query:, variables:, operation_name: }.
  #
  #      expect(fake.requests.size).to eq 1          # memoized, then
  #      expect(fake.requests.last[:variables]).to eq({ "id" => "1" })
  attr_reader :requests

  # Everything a fake takes, with its default. This IS the signature — a
  # keyword list can only refuse what reaches it, and two of the three doors
  # onto a fake (graphql_fake, a router's fake:) forward a hash, so a
  # misspelled key arrived as a bare "unknown keyword" from inside the
  # fabricator, naming neither the accepted options nor the one you meant.
  OPTIONS = {
    schema: nil, overrides: {}, seed: nil, values: nil, list_size: nil,
    null_chance: nil, errors: nil, fail_at: nil, corrupt: nil,
  }.freeze
  private_constant :OPTIONS

  def initialize(**options)
    options = check_options!(options)
    config = GraphWeaver::Testing.config
    @schema = options[:schema] || config.schema || raise(GraphWeaver::Error,
      "no schema to fake against — set GraphWeaver::Testing.config.schema, pass schema:, " \
      "or commit a schema dump at #{GraphWeaver.schema_path}")
    @overrides = config.overrides.merge(options[:overrides]).transform_keys(&:to_s)
    GraphWeaver::Internal::Overrides.validate!(@schema, @overrides)
    @values = GraphWeaver::Internal::Values.new(seed: options[:seed], values: options[:values])
    @list_size = options[:list_size] || config.list_size
    @null_chance = options[:null_chance] || 0.0
    # NOT Array(): it would explode a bare Hash into key/value pairs
    @extra_errors = wrap(options[:errors]).map { |error| normalize_error(error) }
    @fail_at = wrap(options[:fail_at]).map { |spec| normalize_fail_spec(spec) }
    @corrupt = wrap(options[:corrupt])
    @requests = []
    @variables = nil # unknown until an execute says; see #object
  end

  # operation_name: is accepted for contract parity and ignored — one
  # document holds one operation, so there is nothing to select between
  # (see Selection#load_operation).
  def execute(query, variables: {}, operation_name: nil)
    # recorded before validation: "we never called it" and "we called it with
    # a query that doesn't compile" are different failures
    @requests << { query:, variables:, operation_name: }.freeze

    # Validate first, as the other clients in the slot do: a field the schema
    # doesn't have would otherwise walk into `get_field(...).type` on nil, and
    # a NoMethodError from inside the fabricator is undiagnosable next to the
    # "Did you mean" a real server gives. This is the commonest mistake there
    # is — a query drifting ahead of the dump, or a typo in an ad-hoc one.
    invalid = @schema.validate(GraphQL.parse(query))
    return { "data" => nil, "errors" => invalid.map(&:to_h) } if invalid.any?

    operation = load_operation(query)
    root_type = operation_root_type(operation)
    @variables = variable_values(operation, variables)

    @path = []
    @failures = []
    # fail_at fires once per execute, not once per client lifetime
    @fail_at.each { |spec| spec.delete("triggered") }
    data = object_value(root_type, operation.selections)
    data = nil if data.equal?(NULL_BUBBLE) # total propagation, like a real server

    response = { "data" => data }
    errors = @failures + @extra_errors
    response["errors"] = errors unless errors.empty?
    response
  end

  # One fabricated object of `type_name` for these selections — the seam
  # {FakeSubgraph} answers a federation `_entities` fetch through, where the
  # representation names the type and the document only ever reached it
  # through an inline fragment.
  #
  # variables: are what @skip/@include read. Left unsaid they are *unknown*,
  # not empty, and the directives go unevaluated: the router has already
  # decided them for the fetch it is sending, and reading an unpassed
  # variable as absent would drop the field it just asked for.
  # operation: is the definition the selections came from — a faked subgraph
  # passes it so @skip/@include see the defaults it declares, as graphql-ruby
  # would. Without it, or variables:, directives stay unevaluated.
  # failures: an array any simulated field error (fail_at:) is appended to,
  # paths relative to this object. Left unsaid, a fail_at here only nulls the
  # field — a null with no error is a response no server gives.
  def object(type_name, selections, fragments: {}, variables: nil, operation: nil, failures: nil)
    type = @schema.get_type(type_name) or
      raise GraphWeaver::Error, "#{type_name} is not a type of this schema"

    @fragments = fragments
    @variables = variables && variable_values(operation, variables)
    @path = []
    @failures = []
    value = object_value(type, selections)
    failures&.concat(@failures)
    value.equal?(NULL_BUBBLE) ? nil : value
  end

  # The Selection mixin's walk is machinery, not interface: a developer who
  # types `.methods` on a fake should find execute, schema, requests, object
  # and parse, not the twelve steps behind them.
  private :load_operation, :operation_root_type, :each_field, :gather,
    :gather_conditional, :applies?, :conditional?

  private

  # A misspelled option pins nothing and leaves the example green — the same
  # silent pass a typo'd override key is refused for.
  def check_options!(options)
    unknown = options.keys - OPTIONS.keys
    return OPTIONS.merge(options) if unknown.empty?

    suggestion = GraphWeaver::Internal::Util.did_you_mean(OPTIONS.keys.map(&:to_s), unknown.first.to_s)
    hint = suggestion ? " — did you mean #{suggestion}:?" : "."
    raise ArgumentError, "a fake doesn't take #{unknown.first}:#{hint} It takes " \
      "#{OPTIONS.keys.map { |name| "#{name}:" }.join(", ")}"
  end

  def rng = @values.rng

  # Codegen has to type a @skip/@include field as maybe-absent because it
  # can't know the variable; a fake was handed it, so it can answer the way
  # the server would — and the way {Router} already does, or one query would
  # carry a key under :fake and not under :router. Selection's walk recurses
  # through this method, so filtering here filters at every depth.
  def each_field(type, selections, visiting = Set.new, conditional: false, &block)
    selections = selections.reject { |selection| omitted?(selection) } if @variables
    super(type, selections, visiting, conditional:, &block)
  end

  # A variable with neither a value nor a declared default reads as absent,
  # which excludes under @include and includes under @skip — as graphql-ruby
  # resolves it.
  def omitted?(selection)
    selection.directives.any? do |directive|
      next false unless GraphWeaver::Internal::Selection::CONDITIONAL_DIRECTIVES.include?(directive.name)

      argument = directive.arguments.find { |arg| arg.name == "if" } or next false
      value = argument_value(argument)
      (directive.name == "skip") ? !!value : value.nil? || value == false
    end
  end

  def argument_value(argument)
    value = argument.value
    value.is_a?(GraphQL::Language::Nodes::VariableIdentifier) ? @variables&.[](value.name) : value
  end

  # An operation's declared defaults are part of the variables graphql-ruby
  # runs with, so @skip/@include and a `first:` have to see them too.
  def variable_values(operation, variables)
    defaults = (operation&.variables || []).each_with_object({}) do |definition, out|
      out[definition.name] = definition.default_value unless definition.default_value.nil?
    end
    defaults.merge(variables.to_h { |name, value| [name.to_s, value] })
  end

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

  # pins: the response keys an override pinned at this object, merged in as
  # the walk reaches them — everything it doesn't name is fabricated.
  def object_value(type, selections, pins: nil, source: nil)
    # gather (not each_field) so a field selected twice — `a { x } a { y }` —
    # fabricates the MERGED shape codegen's struct expects, not last-writer-wins
    fields = gather(type, selections)
    check_pins!(fields, pins, source) if pins

    result = {}
    fields.each do |key, nodes|
      node = nodes.first
      pin = (pins && pins.key?(key)) ? pins[key] : UNPINNED
      @path.push(key)
      value = if node.name == "__typename"
        type.graphql_name
      else
        field_value(type, node, nodes.flat_map(&:selections), pin, source)
      end
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

  def field_value(parent_type, node, selections, pin = UNPINNED, source = nil)
    if (spec = matching_failure)
      @failures << {
        "message" => spec["message"] || "simulated failure",
        "path" => @path.dup,
      }.merge(spec["code"] ? { "extensions" => { "code" => spec["code"] } } : {})
      spec["triggered"] = true

      return NULL_BUBBLE
    end

    coordinate = "#{parent_type.graphql_name}.#{node.name}"
    if pin.equal?(UNPINNED)
      # most specific key wins; #fetch (not #[]) so an override OF nil pins null
      pin = @overrides.fetch(coordinate) { @overrides.fetch(node.name, UNPINNED) }
      source = @overrides.key?(coordinate) ? coordinate : node.name unless pin.equal?(UNPINNED)
    end

    field_type = @schema.get_field(parent_type.graphql_name, node.name).type
    return pinned_value(field_type, node, selections, pin, source) unless pin.equal?(UNPINNED)
    return corrupt_value(field_type) if @corrupt.include?(coordinate)

    type_value(field_type, node, selections, coordinate:)
  end

  # What an override pins here. A leaf takes the value outright; a composite
  # MERGES — the keys it names are pinned and the rest of the selection is
  # fabricated, so pinning one nested field never means hand-writing the
  # subtree around it. A pinned list is exactly as long as it is written.
  def pinned_value(type, node, selections, value, source)
    value = value.call if value.is_a?(Proc)

    case type.kind.name
    when "NON_NULL" then pinned_value(type.of_type, node, selections, value, source)
    when "LIST"
      return value unless value.is_a?(Array)

      value.each_with_index.map do |element, index|
        @path.push(index)
        begin
          pinned_value(type.of_type, node, selections, element, source)
        ensure
          @path.pop
        end
      end
    when "OBJECT", "UNION", "INTERFACE"
      return value unless value.is_a?(Hash)

      object_value(pinned_type(type, value, source), selections, pins: value, source:)
    else
      value
    end
  end

  # The concrete type a pinned object is fabricated as. At a union or
  # interface the pin has to say: picking a member at random would fabricate
  # a shape the pinned keys don't fit, in whichever fraction of runs the
  # seed lands there.
  def pinned_type(type, value, source)
    named = value["__typename"]
    return type if named == type.graphql_name

    members = (type.kind.name == "OBJECT") ? [type] : @schema.possible_types(type)
    if named.nil?
      return type if members.one?

      raise GraphWeaver::Error, "override #{source.inspect} pins an object at #{location}, where " \
        "the query can return #{members.map(&:graphql_name).sort.join(" or ")} — name the one you " \
        "mean with \"__typename\"."
    end

    found = members.find { |member| member.graphql_name == named }
    return found if found

    raise GraphWeaver::Error, "override #{source.inspect} pins __typename #{named.inspect} at " \
      "#{location}, where the query can only return #{members.map(&:graphql_name).sort.join(" or ")}"
  end

  # A pinned key the query doesn't select would fabricate the field anyway
  # and quietly leave the pin unread — the same silent-green failure a typo'd
  # coordinate is validated against, one level down.
  def check_pins!(fields, pins, source)
    # __typename in a pin names the type to fabricate (see #pinned_type); it
    # is an instruction, not a field the query has to have selected
    unknown = pins.keys.reject { |key| key == "__typename" || fields.key?(key) }
    return if unknown.empty?

    suggestion = GraphWeaver::Internal::Util.did_you_mean(fields.keys, unknown.first.to_s)
    hint = suggestion ? " — did you mean #{suggestion.inspect}?" : "."
    raise GraphWeaver::Error, "override #{source.inspect} supplies #{unknown.first.inspect} at " \
      "#{location}, which this query doesn't select#{hint} An override's keys are response keys, " \
      "exactly as they arrive on the wire (#{fields.keys.join(", ")})."
  end

  # where the walk is, for a message: "reader.orders.0"
  def location = @path.empty? ? "the root" : @path.join(".")

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

  # honor pagination-ish arg semantics: first/last/limit caps the fabricated
  # list length, whether it arrives as a literal or as a variable
  def list_length(node)
    argument = node.arguments.find { |arg| %w[first last limit].include?(arg.name) }
    capped = argument && argument_value(argument)
    # Array.new(-1) is "negative array size" out of the fabricator's guts; a
    # cap below zero asks for nothing, which is what a page of none is
    return [capped, 0].max if capped.is_a?(Integer)

    # an Integer list_size means exactly that many; a Range randomizes within it
    @list_size.is_a?(Range) ? rng.rand(@list_size) : @list_size
  end

  def type_value(type, node, selections, coordinate: nil, non_null: false)
    if type.kind.name == "NON_NULL"
      return type_value(type.of_type, node, selections, coordinate:, non_null: true)
    end
    # every nullable position, a list included — null_chance is about the
    # nilable props codegen emitted, and it emits one for `[Thing!]` too
    return if !non_null && rng.rand < @null_chance

    case type.kind.name
    when "LIST"
      elements = Array.new(list_length(node)) do |index|
        @path.push(index)
        element = type_value(type.of_type, node, selections, coordinate:)
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
      core_value(type, node, selections, coordinate)
    end
  end

  def core_value(type, node, selections, coordinate = nil)
    case type.kind.name
    when "SCALAR"
      @values.scalar(type.graphql_name, node.name, coordinate)
    when "ENUM"
      type.values.keys.sort.sample(random: rng)
    when "OBJECT"
      object_value(type, selections)
    when "UNION", "INTERFACE"
      member = @schema.possible_types(type).sort_by(&:graphql_name).sample(random: rng)
      object_value(member, selections)
    else
      raise NotImplementedError, "cannot fake kind: #{type.kind.name}"
    end
  end
end
