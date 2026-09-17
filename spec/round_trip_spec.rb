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

  # Not a fixture anyone generates from: the three schemas below take no list
  # of LEAVES anywhere, which is exactly the shape an input refusal used to
  # lose the index for — so the input half would have passed vacuously on it.
  ROUND_TRIP_LISTS = GraphQL::Schema.from_definition(<<~GRAPHQL)
    enum Colour { RED GREEN }
    input Tagging { ids: [ID!], names: [String!], colour: Colour, nested: Tagging }
    type Thing { id: ID! name: String colour: Colour }
    type Query {
      things: [Thing!]
      pick(ids: [Int!], colours: [Colour!], grid: [[Int!]!], tagging: Tagging, flag: Boolean): [Thing!]
    }
  GRAPHQL

  # The reserved-name rename has nothing else here that exercises it: no schema
  # above, and no real schema in the repo, has a field whose prop would shadow a
  # method — so every oracle in this file would agree with a codegen that never
  # renamed anything. Both halves matter: `class` is a result key AND an input
  # field, and only the input side can lose a value through the wire name.
  #
  # `find`'s arguments are the third place such a name lands, and the one the
  # rename does NOT reach: a variable becomes an execute KWARG, where `hash:`
  # is legal Ruby and stays as it is spelled. Linear's `Query.comment(hash:)`
  # is the real one. (`class` is absent here on purpose — a Ruby keyword is
  # refused as a kwarg, which is a different rule with its own spec.)
  ROUND_TRIP_RESERVED = GraphQL::Schema.from_definition(<<~GRAPHQL)
    input RowFilter { class: String, hash: Int, display: Boolean, to_json: String, each: [String!], nested: RowFilter }
    type Row { id: ID! class: String hash: Int display: Boolean to_json: String each: [String!] nested: Row }
    type Query {
      row(filter: RowFilter): Row
      rows(filter: RowFilter): [Row!]
      find(hash: Int, display: Boolean, to_json: String, each: [String!]): Row
    }
    type Mutation { save(input: RowFilter!): Row }
  GRAPHQL

  ROUND_TRIP_SCHEMAS = {
    "Demo" => Demo::Schema,                      # enums, a union, an interface, a custom + an unregistered scalar
    "Products" => RouterGraph::Products::Schema, # an interface whose members differ
    "Reviews" => RouterGraph::Reviews::Schema,   # unions whose members cross subgraphs
    "Lists" => ROUND_TRIP_LISTS,                 # lists of leaves, a list of lists, lists inside an input
    "Reserved" => ROUND_TRIP_RESERVED,           # fields whose props take a trailing underscore
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
        checked += 1 if trip.checked?
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
      fields = argument_fields(schema)
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

    it "refuses a bad #{label} input value, saying where it was and what was wrong" do
      fields = argument_fields(schema)
      skip "#{label} takes no arguments anywhere" if fields.empty?

      checked = 0
      failures = (0...ROUND_TRIP_CASES).flat_map do |i|
        seed = ROUND_TRIP_SEED + i
        rng = Random.new(seed)
        field, mutation = fields[seed % fields.size]
        trip = RoundTrip.check_hostile_input(schema:, field:, mutation:, name: "HostileInput#{i}", rng:)
        checked += 1 if trip.checked?
        trip.failures.map { |failure| report(failure, trip, seed) }
      end

      # a draw that found nothing to corrupt asserts nothing, and enough of
      # those in a row would pass this vacuously
      expect(checked).to be > ROUND_TRIP_CASES / 4
      expect(failures).to be_empty, -> { failures.join("\n\n") }
    end
  end

  # The scalar names public schemas actually declare, and that neither fixture
  # nor cached dump had: GitLab and universe both declare `scalar Time`, Linear
  # a `DateTimeOrDuration` beside the conventional `DateTime`. Both oracles
  # tripped on them in the corpus sweep, in opposite directions.
  describe "custom scalars a public schema declares" do
    CORPUS_SCALARS = GraphQL::Schema.from_definition(<<~GRAPHQL)
      scalar Time
      scalar DateTimeOrDuration
      input Between { gt: DateTimeOrDuration, lt: DateTimeOrDuration }
      type Event { at: Time! }
      type Query { event(at: DateTimeOrDuration, between: Between): Event }
    GRAPHQL

    after { GraphWeaver::Codegen.reset_registrations! }

    it "leaves one nobody has registered alone, whatever it is named" do
      trip = RoundTrip.check_hostile(schema: CORPUS_SCALARS, query: "{ event { at } }",
        name: "UnregisteredTime", rng: Random.new(1))

      # unregistered means T.untyped pass-through, so there is nothing the
      # generated code could refuse — spoiling it blames codegen for a contract
      # the user declined to give it
      expect(trip.barren).to eq("no spoilable leaf")
      expect(trip.failures).to be_empty
    end

    # GitLab spells its dates ISO8601Date/ISO8601DateTime — built-in names the
    # tables above have no row of their own for, so they are only reachable
    # through the Ruby type they cast to
    it "sends a legal value for a built-in spelled by its long name" do
      schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
        scalar ISO8601Date
        scalar ISO8601DateTime
        type Query { on: ISO8601Date at: ISO8601DateTime }
      GRAPHQL
      failures = (0...20).flat_map do |i|
        trip = RoundTrip.check(schema:, query: "{ on at }", name: "Long#{i}", rng: Random.new(i))
        trip.failures.map { |failure| report(failure, trip, i) }
      end

      expect(failures).to be_empty, -> { failures.join("\n\n") }
    end

    # A scalar registered as a wire class reads through the library's own rule
    # for that class, so unlike an unregistered one it HAS a contract to
    # refuse against — and a decimal string is legal, the server's own scalar
    # being free to write one.
    it "reads and refuses a scalar registered as a wire class" do
      schema = GraphQL::Schema.from_definition("scalar Count\ntype Query { n: Count }")
      GraphWeaver.register_scalar("Count", Integer)

      failures = (0...20).flat_map do |i|
        [RoundTrip.check(schema:, query: "{ n }", name: "Count#{i}", rng: Random.new(i)),
          RoundTrip.check_hostile(schema:, query: "{ n }", name: "HostileCount#{i}", rng: Random.new(i))]
          .flat_map { |trip| trip.failures.map { |failure| report(failure, trip, i) } }
      end

      expect(failures).to be_empty, -> { failures.join("\n\n") }
    end

    it "keeps sub-second precision through a registered one" do
      RoundTrip.register_scalars!(CORPUS_SCALARS)
      failures = (0...40).flat_map do |i|
        trip = RoundTrip.check_input(schema: CORPUS_SCALARS, field: CORPUS_SCALARS.query.fields["event"],
          name: "TimeInput#{i}", rng: Random.new(i))
        trip.failures.map { |failure| report(failure, trip, i) }
      end

      expect(failures).to be_empty, -> { failures.join("\n\n") }
    end
  end

  # every root field that takes an argument, paired with whether it's a mutation
  def argument_fields(schema)
    [[schema.query, false], [schema.mutation, true]].reject { |root, _| root.nil? }
      .flat_map { |root, mutation| root.fields.each_value.reject { |f| f.arguments.empty? }.map { |f| [f, mutation] } }
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
