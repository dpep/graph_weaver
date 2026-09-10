# typed: ignore — RouterGraph's subgraphs are `typed: ignore` themselves
# A property test over the two directions generated code has to survive:
# a legal response deserializing into the structs, and a Ruby input
# serializing onto the wire. Both oracles derive what is legal from the
# SCHEMA (see spec/support/round_trip.rb), not from graph_weaver.
#
# Bounded and seeded so it runs on every suite. bin/round-trip is the same
# machinery, unbounded, for real schemas and corpora.
describe "round trip" do
  # Bump to re-roll the corpus; every failure names the case seed it came
  # from, so one case can be re-run on its own.
  ROUND_TRIP_SEED = Integer(ENV.fetch("ROUND_TRIP_SEED", "20260907"))
  ROUND_TRIP_CASES = Integer(ENV.fetch("ROUND_TRIP_CASES", "60"))

  ROUND_TRIP_SCHEMAS = {
    "Demo" => Demo::Schema,                      # enums, a union, an interface, a custom + an unregistered scalar
    "Products" => RouterGraph::Products::Schema, # an interface whose members differ
    "Reviews" => RouterGraph::Reviews::Schema,   # unions whose members cross subgraphs
  }.freeze

  # Shapes worth holding onto by name: each one is a bug this suite has seen,
  # or a corner the fuzzer would only reach by luck.
  ROUND_TRIP_FIXED = {
    "a child reached both behind a guard and not" => <<~GQL,
      query Fixed($g: Boolean!) { people { pets @include(if: $g) { name } pets { species } } }
    GQL
    "a narrowing inside a non-null list" => <<~GQL,
      query Fixed { search(term: "a") { ... on Pet { name species } } }
    GQL
    "a union member the query never named" => <<~GQL,
      query Fixed { search(term: "a") { __typename ... on Pet { species } } }
    GQL
    "an interface field beside a member fragment" => <<~GQL,
      query Fixed { named(name: "x") { __typename name ... on Pet { species } } }
    GQL
    "one key aliased three ways" => <<~GQL,
      query Fixed { a: people { id } b: people { name } people { id name } }
    GQL
    "a key merged through a fragment and a field" => <<~GQL,
      query Fixed { people { ...F pets { name } } }
      fragment F on Person { pets { species } }
    GQL
    "nullable everything, so nulls and empty lists are legal throughout" => <<~GQL,
      query Fixed { person(id: "1") { id name email birthday pets { name metadata } } }
    GQL
    "a guarded fragment spread over a whole selection" => <<~GQL,
      query Fixed($g: Boolean!) { people { name ...F @skip(if: $g) } }
      fragment F on Person { birthday pets { species } }
    GQL
  }.freeze

  ROUND_TRIP_FIXED.each do |what, query|
    it "deserializes every response the schema permits for #{what}" do
      failures = (0...12).flat_map do |draw|
        seed = ROUND_TRIP_SEED + draw
        trip = RoundTrip.check(schema: Demo::Schema, query:, name: "Fixed#{draw}", rng: Random.new(seed))
        trip.failures.map { |failure| report(failure, trip, seed) }
      end

      expect(failures).to be_empty, -> { failures.join("\n\n") }
    end
  end

  ROUND_TRIP_SCHEMAS.each do |label, schema|
    it "deserializes every response #{label} permits, for #{ROUND_TRIP_CASES} generated queries" do
      failures = []
      generated = checked = 0

      ROUND_TRIP_CASES.times do |i|
        seed = ROUND_TRIP_SEED + i
        rng = Random.new(seed)
        query = RoundTrip::Fuzzer.new(schema, rng).query
        next unless query && schema.validate(query).empty?

        generated += 1
        trip = RoundTrip.check(schema:, query:, name: "Case#{i}", rng:)
        checked += 1 unless trip.refused
        failures.concat(trip.failures.map { |failure| report(failure, trip, seed) })
      end

      # a fuzzer that stopped producing queries would pass this vacuously — and
      # so would a codegen that refused every one of them, since the harness
      # counts any raise as a refusal and checks nothing
      expect(generated).to be > ROUND_TRIP_CASES / 2
      expect(checked).to be > generated / 2
      expect(failures).to be_empty, -> { failures.join("\n\n") }
    end

    it "refuses, by name, a #{label} wire value the scalar can't mean" do
      failures = []
      ROUND_TRIP_CASES.times do |i|
        seed = ROUND_TRIP_SEED + i
        rng = Random.new(seed)
        query = RoundTrip::Fuzzer.new(schema, rng).query
        next unless query && schema.validate(query).empty?

        trip = RoundTrip.check_hostile(schema:, query:, name: "Hostile#{i}", rng:)
        failures.concat(trip.failures.map { |failure| report(failure, trip, seed) })
      end

      expect(failures).to be_empty, -> { failures.join("\n\n") }
    end

    it "puts #{label} inputs on the wire in the shape the schema wants" do
      fields = [[schema.query, false], [schema.mutation, true]].reject { |root, _| root.nil? }
        .flat_map { |root, mutation| root.fields.each_value.reject { |f| f.arguments.empty? }.map { |f| [f, mutation] } }
      skip "#{label} takes no arguments anywhere" if fields.empty?

      failures = (0...ROUND_TRIP_CASES).flat_map do |i|
        seed = ROUND_TRIP_SEED + i
        rng = Random.new(seed)
        # off the seed, not the index, so re-running one seed picks the same field
        field, mutation = fields[seed % fields.size]
        trip = RoundTrip.check_input(schema:, field:, mutation:, name: "Input#{i}", rng:)
        trip.failures.map { |failure| report(failure, trip, seed) }
      end

      expect(failures).to be_empty, -> { failures.join("\n\n") }
    end
  end

  # Everything a failure needs to be acted on without re-deriving it.
  def report(failure, trip, seed)
    [
      "seed #{seed} (ROUND_TRIP_SEED=#{seed} ROUND_TRIP_CASES=1)",
      "  #{failure.kind} at #{failure.path.join(".")}: #{failure.detail}",
      "  query: #{trip.query.to_s.gsub(/\s+/, " ").strip}",
      "  wire:  #{trip.wire.inspect}",
    ].join("\n")
  end
end
