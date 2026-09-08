# A second oracle for generated code: instead of comparing declared types to
# the schema, it MAKES a response the schema says is legal and feeds it to the
# generated `from_h`. Anything that raises — or loses a value on the way in —
# is a defect, whatever the declared type says.
#
# The response builder follows the GraphQL spec's CollectFields /
# ExecuteSelectionSet / CompleteValue directly rather than reusing
# GraphWeaver::Selection, so the two never agree by construction.
module RoundTrip
  # A non-null field resolving to null: the error propagates up to the nearest
  # nullable position, which becomes null (spec: "Errors and Non-Nullability").
  Propagate = Class.new(StandardError)

  Failure = Struct.new(:kind, :path, :detail, keyword_init: true)

  # Builds one legal response for a query. Every choice it makes — a null where
  # nullability permits, a list length, which member of an abstract type is
  # live, whether a @skip/@include block ran — comes off the rng, so a seed
  # reproduces the response exactly.
  class Responder
    # tuning knobs, all probabilities except list_sizes
    DEFAULTS = {
      null: 0.3,            # null a nullable position
      propagate: 0.15,      # share of responses that null ONE non-null position
      list_sizes: [0, 1, 2, 3],
      unnamed_member: 0.25, # resolve an abstract to a type the query never named
    }.freeze

    # Chance per non-null position of being the one that fails, once a response
    # has been chosen to carry a propagating null. Small, so the failure lands
    # somewhere down the tree rather than always at the first root field —
    # where it would null `data` outright every time.
    PROPAGATE_HERE = 0.05

    def initialize(schema, query, rng:, **opts)
      @schema = schema
      @rng = rng
      @opts = DEFAULTS.merge(opts)
      document = GraphQL.parse(query)
      @fragments = document.definitions
        .grep(GraphQL::Language::Nodes::FragmentDefinition)
        .to_h { |fragment| [fragment.name, fragment] }
      @operation = document.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).first
      # every @skip/@include reads a variable; deciding them up front is what
      # makes the response self-consistent, the way a real server's would be
      @variables = @operation.variables.to_h { |var| [var.name, @rng.rand < 0.5] }
        .merge(@opts[:variables] || {})
      @failures_left = @rng.rand < @opts[:propagate] ? 1 : 0
    end

    # {"data" => ...} — data is nil when a null propagated all the way out.
    def response
      root = @operation.operation_type == "mutation" ? @schema.mutation : @schema.query
      { "data" => execute(@operation.selections, root) }
    rescue Propagate
      { "data" => nil, "errors" => [{ "message" => "null propagated to the root" }] }
    end

    private

    # spec: CollectFields. key => [field nodes], in selection order.
    def collect_fields(type, selections, visited = Set.new, out = {})
      selections.each do |selection|
        next if skipped?(selection)

        case selection
        when GraphQL::Language::Nodes::Field
          (out[selection.alias || selection.name] ||= []) << selection
        when GraphQL::Language::Nodes::InlineFragment
          next unless applies?(selection.type&.name, type)

          collect_fields(type, selection.selections, visited, out)
        when GraphQL::Language::Nodes::FragmentSpread
          next if visited.include?(selection.name)

          fragment = @fragments.fetch(selection.name)
          next unless applies?(fragment.type.name, type)

          collect_fields(type, fragment.selections, visited | [selection.name], out)
        end
      end
      out
    end

    # spec: DoesFragmentTypeApply — the runtime type is always concrete here,
    # so a condition applies when it names that type or an abstract it belongs to.
    def applies?(condition, type)
      return true if condition.nil? || condition == type.graphql_name

      abstract = @schema.get_type(condition)
      return false unless abstract && %w[INTERFACE UNION].include?(abstract.kind.name)

      @schema.possible_types(abstract).include?(type)
    end

    def skipped?(selection)
      selection.directives.any? do |directive|
        case directive.name
        when "skip" then directive_if(directive)
        when "include" then !directive_if(directive)
        else false
        end
      end
    end

    def directive_if(directive)
      value = directive.arguments.find { |a| a.name == "if" }&.value
      value.is_a?(GraphQL::Language::Nodes::VariableIdentifier) ? @variables.fetch(value.name, true) : !!value
    end

    # spec: ExecuteSelectionSet
    def execute(selections, type)
      collect_fields(type, selections).to_h do |key, nodes|
        name = nodes.first.name
        next [key, type.graphql_name] if name == "__typename"

        field = @schema.get_field(type.graphql_name, name)
        [key, complete(field.type, nodes.flat_map(&:selections))]
      end
    end

    # spec: CompleteValue
    def complete(type, selections)
      return complete_non_null(type.of_type, selections) if type.kind.name == "NON_NULL"
      return nil if @rng.rand < @opts[:null]

      begin
        complete_non_null(type, selections)
      rescue Propagate
        nil # a nullable position absorbs the propagating null
      end
    end

    def complete_non_null(type, selections)
      if @failures_left.positive? && @rng.rand < PROPAGATE_HERE
        @failures_left -= 1
        raise Propagate
      end

      case type.kind.name
      when "LIST" then Array.new(@opts[:list_sizes].sample(random: @rng)) { complete(type.of_type, selections) }
      when "SCALAR" then scalar_value(type.graphql_name)
      when "ENUM" then type.values.keys.sample(random: @rng)
      when "OBJECT" then execute(selections, type)
      when "UNION", "INTERFACE" then execute(selections, runtime_type(type, selections))
      else raise "unexpected kind #{type.kind.name}"
      end
    end

    # Which concrete type is actually live. Usually one the query named (so its
    # fields come back), sometimes one it didn't — the `Other` path a schema
    # takes the day it grows a member.
    def runtime_type(abstract, selections)
      possible = @schema.possible_types(abstract).to_a
      named = possible.select { |type| collect_fields(type, selections).keys != ["__typename"] }
      pool = named.empty? || @rng.rand < @opts[:unnamed_member] ? possible : named
      pool.sample(random: @rng)
    end

    # A wire value the registered cast will accept. Unregistered scalars are
    # T.untyped pass-through, so anything goes — send a hash, which is what an
    # unregistered scalar most often is.
    def scalar_value(name)
      case name
      when "ID", "String" then "s#{@rng.rand(1000)}"
      when "Int" then @rng.rand(10_000)
      # JSON has one number type, so a whole Float reaches Ruby as an Integer
      # from any encoder that drops the trailing zero — draw both shapes
      when "Float" then @rng.rand < 0.25 ? @rng.rand(100) : (@rng.rand * 100).round(3)
      when "Boolean" then @rng.rand < 0.5
      else
        LEAF_VALUES[GraphWeaver::Codegen.scalar(name).type] || { "unregistered" => name }
      end
    end

    # by the Ruby type a scalar is registered as, since that is what casts
    LEAF_VALUES = {
      "Date" => "2024-01-15",
      "Time" => "2024-01-15T10:20:30Z",
      "DateTime" => "2024-01-15T10:20:30Z",
      "String" => "wire",
      "Integer" => 7,
      "Float" => 1.5,
      "T::Boolean" => true,
    }.freeze
  end

  # Builds valid queries against an arbitrary schema, biased toward the shapes
  # that merge selections: one response key reached several times, through
  # fields, inline fragments and named spreads, with and without @skip/@include.
  class Fuzzer
    def initialize(schema, rng, depth: 3, width: 3)
      @schema = schema
      @rng = rng
      @depth = depth
      @width = width
    end

    # A query string, or nil when this draw found nothing selectable.
    def query
      @fragments = {}
      @guards = 0
      body = selection_set(@schema.query, @depth)
      return unless body

      vars = @guards.zero? ? "" : "($guard: Boolean!)"
      ([+"query Fuzz#{vars} { #{body} }"] + @fragments.values).join("\n\n")
    end

    private

    def selection_set(type, depth)
      parts = %w[UNION INTERFACE].include?(type.kind.name) ? abstract_parts(type, depth) : object_parts(type, depth)
      parts&.compact&.reject(&:empty?)&.then { |p| p.empty? ? nil : p.join(" ") }
    end

    def object_parts(type, depth)
      fields = sample(selectable(type), @width)
      return if fields.empty?

      parts = fields.filter_map { |field| render(field, depth) }
      return if parts.empty?

      # the shape that exercises selection merging: the same key again, usually
      # behind a guard, sometimes wrapped so it arrives through a fragment
      if @rng.rand < 0.5
        again = render(fields.first, depth, guard: @rng.rand < 0.7)
        parts << wrap(again, type) if again
      end
      parts
    end

    def abstract_parts(type, depth)
      members = @schema.possible_types(type).to_a
      return if members.empty?

      # a single `... on X` and nothing else — the narrowing shape
      if @rng.rand < 0.25
        member = sample(members, 1).first
        inner = selection_set(member, depth - 1)
        return ["... on #{member.graphql_name} { #{inner} }"] if inner
      end

      parts = ["__typename"]
      # An interface's own fields, spelled bare or inside a fragment on the
      # interface itself: GraphQL says those are the same selection, so the
      # generator has to agree — reading the fragment as a type condition
      # would narrow the field to one member and drop the rest.
      if type.kind.name == "INTERFACE"
        own = sample(selectable(type), 2).filter_map { |field| render(field, depth) }
        parts << (@rng.rand < 0.4 ? "... on #{type.graphql_name} { #{own.join(" ")} }" : own.join(" ")) if own.any?
      end
      # an interface fragment inside a UNION selection: the members that
      # implement it answer it, including ones the query never named
      shared_interfaces(type, members).each do |interface|
        inner = sample(selectable(interface), 2).filter_map { |field| render(field, depth) }
        next if inner.empty?

        parts << if @rng.rand < 0.3
          spread("on #{interface.graphql_name}", inner.join(" "), guard: guard?)
        else
          "... on #{interface.graphql_name} { #{inner.join(" ")} }"
        end
      end
      # sometimes exactly one condition: with shared fields selected alongside,
      # that is the shape a wrong narrowing would swallow
      sample(members, @rng.rand < 0.4 ? 1 : 2).each do |member|
        inner = selection_set(member, depth - 1)
        next unless inner

        parts << if @rng.rand < 0.3
          spread("on #{member.graphql_name}", inner, guard: guard?)
        else
          "... on #{member.graphql_name}#{guard_suffix(guard?)} { #{inner} }"
        end
      end
      parts
    end

    # An interface every member of this union implements — a condition that
    # narrows nothing, since whatever comes back answers it. At most one per
    # draw, kept rare.
    def shared_interfaces(type, members)
      return [] if type.kind.name == "INTERFACE" || @rng.rand >= 0.3

      sample(common_interfaces(members), 1)
    end

    def common_interfaces(members)
      sets = members.map { |member| member.interfaces.map(&:graphql_name).to_set }
      return [] if sets.empty?

      shared = sets.reduce(:&)
      members.first.interfaces.select { |i| shared.include?(i.graphql_name) }
    end

    # put a repeated selection behind a fragment so it reaches the key by
    # another road than a plain second field
    def wrap(text, type)
      case @rng.rand
      when ...0.4 then text
      when ...0.7 then "... on #{type.graphql_name}#{guard_suffix(guard?)} { #{text} }"
      else spread("on #{type.graphql_name}", text, guard: guard?)
      end
    end

    def spread(condition, body, guard: false)
      name = "F#{@fragments.size}"
      @fragments[name] = "fragment #{name} #{condition} { #{body} }"
      "...#{name}#{guard_suffix(guard)}"
    end

    def render(field, depth, guard: guard?)
      core = field.type.unwrap
      prefix = @rng.rand < 0.15 ? "k#{@rng.rand(10_000)}: " : ""
      suffix = guard_suffix(guard)

      case core.kind.name
      when "SCALAR", "ENUM" then "#{prefix}#{field.graphql_name}#{suffix}"
      else
        return if depth <= 0

        inner = selection_set(core, depth - 1)
        inner && "#{prefix}#{field.graphql_name}#{suffix} { #{inner} }"
      end
    end

    def guard? = @rng.rand < 0.25

    def guard_suffix(guard)
      return "" unless guard

      @guards += 1
      @rng.rand < 0.5 ? " @include(if: $guard)" : " @skip(if: $guard)"
    end

    # fields we can select without inventing argument literals
    def selectable(type)
      type.fields.each_value.reject { |field| field.graphql_name.start_with?("__") }.select do |field|
        field.arguments.each_value.none? { |arg| arg.type.kind.name == "NON_NULL" && !arg.default_value? }
      end
    end

    def sample(list, count) = list.to_a.shuffle(random: @rng).first(count)
  end

  # The input side of the same idea: build a Ruby value for a variable AND,
  # independently, the wire value it has to serialize to. Feeding the first to
  # the generated `execute` must produce the second.
  class Inputs
    def initialize(schema, rng)
      @schema = schema
      @rng = rng
    end

    # [ruby, wire]; wire == :omit means "leave this off entirely"
    def build(type, depth = 3)
      return build!(type.of_type, depth) if type.kind.name == "NON_NULL"
      return [nil, :omit] if depth <= 0 || @rng.rand < 0.3

      build!(type, depth)
    end

    def build!(type, depth = 3)
      case type.kind.name
      when "LIST"
        pairs = Array.new(@rng.rand(3)) { build(type.of_type, depth - 1) }
        [pairs.map(&:first), pairs.map { |_, wire| wire == :omit ? nil : wire }]
      when "SCALAR" then scalar(type.graphql_name)
      when "ENUM" then Array.new(2, type.values.keys.sample(random: @rng)) # kwargs take the wire value
      when "INPUT_OBJECT" then input_object(type, depth)
      else raise "unexpected input kind #{type.kind.name}"
      end
    end

    private

    def input_object(type, depth)
      ruby = {}
      wire = {}
      type.arguments.each_value do |argument|
        r, w = build(argument.type, depth - 1)
        if w == :omit
          # a non-null field with no default has to be there; anything else may
          # be left out, and then must not reach the wire at all
          next unless argument.type.kind.name == "NON_NULL" && !argument.default_value?

          r, w = build!(argument.type.of_type, depth - 1)
        end
        ruby[GraphWeaver::Inflect.underscore(argument.graphql_name).to_sym] = r
        wire[argument.graphql_name] = w
      end
      [ruby, wire]
    end

    def scalar(name)
      value =
        case name
        when "ID", "String" then "v#{@rng.rand(1000)}"
        when "Int" then @rng.rand(1000)
        when "Float" then (@rng.rand * 10).round(3)
        when "Boolean" then @rng.rand < 0.5
        else
          case GraphWeaver::Codegen.scalar(name).type
          when "Date" then return [Date.new(2024, 1, 15), "2024-01-15"]
          when "Time" then return [Time.utc(2024, 1, 15, 10, 20, 30), "2024-01-15T10:20:30Z"]
          when "Integer" then @rng.rand(1000)
          when "String" then "v#{@rng.rand(100)}"
          else { "raw" => name } # unregistered: T.untyped, straight through
          end
        end
      [value, value]
    end
  end

  # Stands in for a transport so a round trip can read what execute put on the
  # wire without a server.
  class Capture
    attr_reader :variables

    def execute(_query, variables:, operation_name: nil)
      @variables = variables
      { "data" => nil, "errors" => [{ "message" => "capture" }] }
    end
  end

  # One round trip. `refused` means codegen declined the query up front (a
  # documented refusal, not a defect); `failures` is empty on a clean trip.
  Trip = Struct.new(:query, :wire, :result, :failures, :refused, keyword_init: true)

  class << self
    # Generate, build a legal response, deserialize it, and check the values
    # survived.
    def check(schema:, query:, name: "RoundTrip", rng: Random.new(0), **opts)
      mod =
        begin
          GraphWeaver::Codegen.parse(schema:, query:, module_name: name)
        rescue GraphWeaver::Error, ArgumentError => e
          return Trip.new(query:, failures: [], refused: "#{e.class}: #{e.message}")
        end

      envelope = Responder.new(schema, query, rng:, **opts).response
      trip = Trip.new(query:, wire: envelope, failures: [])
      begin
        trip.result = mod.from_response(envelope).data
      rescue StandardError => e
        trip.failures = [Failure.new(kind: "raised", path: ["Result"], detail: "#{e.class}: #{e.message}")]
        return trip
      end

      trip.failures = envelope["data"].nil? ? [] : verify(trip.result, envelope["data"], ["Result"])
      trip
    end

    # The input half: a query taking one variable per argument of `field`, a
    # Ruby value for each, and the wire hash they must serialize to.
    def check_input(schema:, field:, mutation: false, name: "InputTrip", rng: Random.new(0))
      arguments = field.arguments.each_value.to_a
      return Trip.new(failures: [], refused: "no arguments") if arguments.empty?

      inputs = Inputs.new(schema, rng)
      # a variable default makes the kwarg optional even where the type is non-null
      defaults = arguments.to_h { |a| [a.graphql_name, rng.rand < 0.4 ? default_literal(a.type) : nil] }
      query = variable_query(schema, field, arguments, defaults, mutation:)
      return Trip.new(query:, failures: [], refused: "invalid draft") unless schema.validate(query).empty?

      mod =
        begin
          GraphWeaver::Codegen.parse(schema:, query:, module_name: name)
        rescue GraphWeaver::Error, ArgumentError => e
          return Trip.new(query:, failures: [], refused: "#{e.class}: #{e.message}")
        end

      kwargs = {}
      expected = {}
      arguments.each do |argument|
        ruby, wire = inputs.build(argument.type)
        required = argument.type.kind.name == "NON_NULL" && defaults[argument.graphql_name].nil?
        next if wire == :omit && !required

        ruby, wire = inputs.build!(argument.type.of_type) if wire == :omit
        kwargs[GraphWeaver::Inflect.underscore(argument.graphql_name).to_sym] = ruby
        expected[argument.graphql_name] = wire
      end

      trip = Trip.new(query:, failures: [])
      capture = Capture.new
      begin
        mod.execute(client: capture, **kwargs)
      rescue StandardError => e
        trip.failures = [Failure.new(kind: "raised", path: ["execute"], detail: "#{e.class}: #{e.message}")]
        return trip
      end

      trip.wire = capture.variables
      if capture.variables != expected
        trip.failures = [Failure.new(kind: "wire", path: ["variables"],
          detail: "expected #{expected.inspect}, sent #{capture.variables.inspect}")]
        return trip
      end

      # second opinion: would a real server's variable coercion take this?
      errors = GraphQL::Query.new(schema, query, variables: capture.variables).variables.errors
      unless errors.empty?
        trip.failures = [Failure.new(kind: "coercion", path: ["variables"], detail: errors.first.message)]
      end
      trip
    end

    # Walk the deserialized object beside the response that produced it: every
    # key the server sent must be readable back, with the same value.
    def verify(object, wire, path)
      # an unregistered scalar passes through by identity — whatever shape it
      # has (often a hash), it is a leaf, not something to descend into
      return [] if object.equal?(wire)

      case wire
      when Hash
        if object.nil?
          # a narrowing that filtered. Legitimate only when the server sent
          # nothing but the dispatch tag: a narrowing selection names no field
          # the other members answer, so anything else here was dropped.
          return [] if (wire.keys - ["__typename"]).empty?

          return [Failure.new(kind: "narrowed", path:, detail: "nil, dropping #{wire.keys.join(", ")}")]
        end

        unless object.is_a?(T::Struct)
          return [Failure.new(kind: "shape", path:, detail: "object #{object.inspect} for hash #{wire.inspect}")]
        end

        wire.flat_map do |key, value|
          prop = GraphWeaver::Inflect.underscore(key).to_sym
          unless object.class.props.key?(prop)
            next [Failure.new(kind: "unmapped", path: path + [key],
              detail: "#{object.class} has no prop for a key the server sent")]
          end

          verify(object.public_send(prop), value, path + [key])
        end
      when Array
        unless object.is_a?(Array) && object.size == wire.size
          return [Failure.new(kind: "list", path:, detail: "#{wire.size} elements in, #{object.is_a?(Array) ? object.size : object.inspect} out")]
        end

        object.each_with_index.flat_map { |element, i| verify(element, wire[i], path + [i]) }
      when nil
        object.nil? ? [] : [Failure.new(kind: "value", path:, detail: "null in, #{object.inspect} out")]
      else
        same_value?(object, wire) ? [] : [Failure.new(kind: "value", path:, detail: "#{wire.inspect} in, #{object.inspect} out")]
      end
    end

    private

    def variable_query(schema, field, arguments, defaults, mutation:)
      declarations = arguments.map do |argument|
        default = defaults[argument.graphql_name]
        "$#{argument.graphql_name}: #{argument.type.to_type_signature}#{" = #{default}" if default}"
      end
      uses = arguments.map { |argument| "#{argument.graphql_name}: $#{argument.graphql_name}" }
      "#{mutation ? "mutation" : "query"} Input(#{declarations.join(", ")}) " \
        "{ #{field.graphql_name}(#{uses.join(", ")})#{leaf_selection(field.type)} }"
    end

    # The smallest valid selection for a field's return type.
    def leaf_selection(type)
      core = type.unwrap
      case core.kind.name
      when "OBJECT"
        scalar = core.fields.each_value.find { |f| %w[SCALAR ENUM].include?(f.type.unwrap.kind.name) && f.arguments.empty? }
        scalar ? " { #{scalar.graphql_name} }" : " { __typename }"
      when "UNION", "INTERFACE" then " { __typename }"
      else ""
      end
    end

    # A literal for a variable default, or nil where none is worth spelling.
    def default_literal(type)
      return default_literal(type.of_type) if type.kind.name == "NON_NULL"

      core = type.kind.name == "LIST" ? type.of_type.unwrap : type
      inner =
        case core.kind.name
        when "ENUM" then core.values.keys.first
        when "SCALAR"
          case core.graphql_name
          when "Int" then "3"
          when "Float" then "1.5"
          when "Boolean" then "true"
          when "String", "ID" then '"d"'
          end
        end
      return unless inner

      type.kind.name == "LIST" ? "[#{inner}]" : inner
    end

    # A cast leaf comes back rich (a Date, a T::Enum); it survived when it
    # serializes back to what went in.
    def same_value?(object, wire)
      return true if object == wire
      return object.serialize == wire if object.is_a?(T::Enum)
      return object.iso8601 == wire if object.respond_to?(:iso8601)

      object.to_s == wire.to_s
    end
  end
end
