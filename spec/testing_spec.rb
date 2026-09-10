require "graph_weaver/testing"
require_relative "generated/person_query"
require_relative "generated/search_query"
require_relative "generated/add_pet_mutation"

describe GraphWeaver::Testing do
  after { GraphWeaver::Testing.reset! }

  let(:fake) { GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 42) }

  describe GraphWeaver::Testing::FakeClient do
    it "fabricates responses that cast cleanly through generated structs" do
      person = PersonQuery.execute!(client: fake, id: "1").person

      expect(person&.name).to be_a String
      expect(person&.pets).to all(be_a(PersonQuery::Result::Person::Pets))
      expect(person&.birthday).to be_a(Date).or be_nil
    end

    it "samples real enum values and valid union members" do
      results = SearchQuery.execute!(client: fake, term: "x").search

      results.each do |member|
        expect(%w[Person Pet]).to include(member.__typename)
      end

      pet = AddPetMutation.execute!(client: fake, name: "Rex", species: AddPetMutation::Species::Dog).add_pet
      expect([AddPetMutation::Species::Dog, AddPetMutation::Species::Cat])
        .to include(pet.species)
    end

    it "is reproducible with a seed" do
      one = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 7)
      two = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 7)
      query = "query { people { name pets { name species } } }"

      expect(one.execute(query, variables: {})).to eq two.execute(query, variables: {})
    end

    it "generates semantic values from field names (faker)" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        query: "query { person(id: 1) { name email } }",
        client: fake,
      )

      person = mod.execute!.person
      expect(person&.email).to match(/@/)
      expect(person&.name).not_to be_empty
    end

    it "pins fields via overrides, most-specific key first" do
      executor = GraphWeaver::Testing::FakeClient.new(
        schema: Demo::Schema,
        seed: 1,
        overrides: {
          "Person.name" => "Daniel",
          "name" => "generic",
          "email" => -> { "me@example.com" },
        },
      )

      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        query: "query { person(id: 1) { name email pets { name } } }",
        client: executor,
      )

      person = mod.execute!.person
      expect(person&.name).to eq "Daniel"                # Type.field wins
      expect(person&.email).to eq "me@example.com"       # proc override
      expect(person&.pets&.map(&:name)).to all(eq "generic") # field-name fallback
    end

    it "exposes the schema it fabricates against" do
      expect(fake.schema).to be Demo::Schema
    end

    it "records every request, so a call count is assertable" do
      PersonQuery.execute!(client: fake, id: "1")
      fake.execute("query { nope }")

      expect(fake.requests.map { |request| request[:variables] })
        .to eq [{ "id" => "1" }, {}]
      expect(fake.requests.last[:query]).to eq "query { nope }" # invalid, still sent
    end

    # the second test anyone writes: fabricated data is fine until the
    # example is ABOUT the data. Pinning must not mean hand-writing the
    # whole subtree in wire casing.
    describe "pinning a subtree" do
      def pets(overrides)
        mod = GraphWeaver.parse(schema: Demo::Schema, name: "Pinned",
          query: "query { person(id: 1) { name pets { name species } } }")
        mod.execute!(client: GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1, overrides:))
          .person
      end

      it "pins a list's length and merges each element" do
        person = pets("Person.name" => "Ada", "Person.pets" => [{ "name" => "Shelby" }, {}])

        expect(person&.name).to eq "Ada"
        expect(person&.pets&.size).to eq 2
        expect(person&.pets&.first&.name).to eq "Shelby"
        expect(person&.pets&.last&.name).to be_a(String).and(satisfy { |name| name != "Shelby" })
        expect(person&.pets&.map(&:species)).to all(be_truthy) # fabricated, still a real enum
      end

      it "refuses a key the query doesn't select, spellchecked" do
        expect { pets("Person.pets" => [{ "speceis" => "DOG" }]) }
          .to raise_error(GraphWeaver::Error,
            /"Person\.pets" supplies "speceis" at person\.pets\.0.*did you mean "species".*response keys/m)
      end

      it "names the response keys when nothing is close" do
        expect { pets("Person.pets" => [{ "id" => "1" }]) }
          .to raise_error(GraphWeaver::Error, /doesn't select\. .*\(name, species\)/m)
      end
    end

    # A pin says what the fake uses instead of inventing a value, keyed by a
    # scalar type, an object type, or a field. The object form is what lets
    # a FactoryBot build be the fixture: the selected fields are read off it
    # and the rest is fabricated.
    describe "pins" do
      # what FactoryBot's looks like from here: a `build` that hands back
      # an object answering the fields
      let(:factory) do
        Module.new do
          def self.build(_name, **attributes) = Struct.new(*attributes.keys).new(*attributes.values)
        end
      end

      def person(pins = {}, query: "query { person(id: 1) { name email birthday pets { name species } } }", **options)
        client = GraphWeaver::Testing::FakeClient.new(pins, schema: Demo::Schema, seed: 1, **options)
        GraphWeaver.parse(schema: Demo::Schema, name: "Pinned", query:).execute!(client:).person
      end

      describe "keyed by a scalar type" do
        let(:schema) do
          GraphQL::Schema.from_definition("scalar Money type Query { reader: Reader } " \
            "type Reader { orders: [Order!]! } type Order { total: Money! }")
        end

        let(:money) do
          Class.new do
            def self.name = "Money"
            def self.parse(wire) = new(wire)
            def initialize(amount) = @amount = amount
          end
        end

        before do
          stub_const("Money", money) # the generated cast names it
          GraphWeaver.register_scalar("Money", money, cast: :parse, serialize: :to_s)
        end

        after { GraphWeaver::Codegen.reset_scalars! }

        def totals(pins)
          GraphWeaver::Testing::FakeClient.new(pins, schema:, seed: 1, list_size: 2)
            .execute("{ reader { orders { total } } }").dig("data", "reader", "orders").map { |order| order["total"] }
        end

        it "pins every field of that scalar, however deep" do
          expect(totals("Money" => "12.00")).to eq %w[12.00 12.00]
        end

        it "loses to a pin on the field" do
          expect(totals("Money" => "12.00", "Order.total" => "999.00")).to eq %w[999.00 999.00]
        end
      end

      it "pins every value of an enum" do
        expect(person("Species" => "CAT", list_size: 3).pets.map { |pet| pet.species.serialize }).to eq %w[CAT CAT CAT]
      end

      describe "keyed by an object type" do
        it "reads the selected fields off the object and fabricates the rest" do
          result = person("Person" => factory.build(:person, name: "Ada"))

          expect(result.name).to eq "Ada"
          expect(result.email).to be_a String
          expect(result.pets).not_to be_empty
        end

        it "fabricates a field the object doesn't answer" do
          require "ostruct"
          result = person("Person" => OpenStruct.new(name: "Ada"))

          expect(result.name).to eq "Ada"
          expect(result.email).to match(/@/)
        end

        it "recurses into nested objects and arrays of them" do
          pets = [factory.build(:pet, name: "Shelby", species: AddPetMutation::Species::Dog), factory.build(:pet, name: "Rex")]
          result = person("Person" => factory.build(:person, name: "Ada", pets:))

          expect(result.pets.map(&:name)).to eq %w[Shelby Rex]
          expect(result.pets.first.species.serialize).to eq "DOG" # a T::Enum, put on the wire
          expect(result.pets.last.species).to be_truthy # fabricated
        end

        # the object holds Ruby values where the wire holds what the
        # registration serializes them to — resolved per field, as codegen does
        it "serializes a Ruby value through the scalar registry" do
          GraphWeaver.register_scalar("Person.email", Time, cast: :iso8601, serialize: :iso8601, requires: "time")
          at = Time.utc(2024, 1, 2, 3, 4, 5)
          result = person("Person" => factory.build(:person, email: at, birthday: Date.new(1990, 6, 15)))

          expect(result.email).to eq at
          expect(result.birthday).to eq Date.new(1990, 6, 15)
        ensure
          GraphWeaver::Codegen.reset_scalars!
        end

        it "takes a wire value the object already holds as written" do
          expect(person("Person" => factory.build(:person, birthday: "1990-06-15")).birthday).to eq Date.new(1990, 6, 15)
        end

        # every Ruby object answers `hash`, and a Struct answers `count`
        it "leaves a field only Ruby answers to be fabricated" do
          schema = GraphQL::Schema.from_definition("type Query { order: Order } type Order { hash: String! count: Int! }")
          order = GraphWeaver::Testing::FakeClient.new({ "Order" => Struct.new(:total).new(1) }, schema:, seed: 1)
            .execute("{ order { hash count } }").dig("data", "order")

          expect(order["hash"]).to be_a String
          expect(order["count"]).to be_an Integer
        end

        it "is read wherever the walk reaches that type, a union member included" do
          mod = GraphWeaver.parse(schema: Demo::Schema, name: "PinnedMembers",
            query: 'query { search(term: "x") { __typename ... on Named { name } } }')
          pinned = GraphWeaver::Testing::FakeClient.new({ "Person" => factory.build(:person, name: "Ada"),
            "Pet" => factory.build(:pet, name: "Rex") }, schema: Demo::Schema, seed: 1, list_size: 6)

          result = mod.execute!(client: pinned).search
          expect(result.size).to eq 6
          expect(result.map { |member| [member.__typename, member.name] })
            .to all(eq(%w[Person Ada]).or(eq(%w[Pet Rex])))
        end

        it "reproduces a proc's object under the seed" do
          pins = { "Person" => ->(rng) { factory.build(:person, name: "ada-#{rng.rand(1_000)}") } }

          expect(person(pins).name).to eq person(pins).name
        end

        it "says to pin by type when a field pin's object lands at an abstract position" do
          fake = GraphWeaver::Testing::FakeClient.new({ "Query.search" => [factory.build(:person, name: "Ada")] },
            schema: Demo::Schema, seed: 1)

          expect { fake.execute('query { search(term: "x") { ... on Named { name } } }') }
            .to raise_error(GraphWeaver::Error, /pins an object at search\.0.*pin it by type instead — \{ "Person" => \.\.\. \}/m)
        end
      end

      it "refuses a key on an abstract type, naming the members" do
        expect { person("Named" => factory.build(:person, name: "Ada")) }
          .to raise_error(GraphWeaver::Error, /"Named" names interface Named.*pin the concrete type — "Person", "Pet"/)
      end

      describe "how pins and options are told apart" do
        it "merges the positional hash over overrides:, and both over the suite's" do
          GraphWeaver::Testing.configure { |config| config.overrides = { "Person.email" => "suite@example.com", "Person.name" => "Suite" } }
          result = person({ "Person.name" => "Positional" }, overrides: { "Person.name" => "Keyword", "Person.email" => "keyword@example.com" })

          expect(result.name).to eq "Positional"
          expect(result.email).to eq "keyword@example.com"
        end

        it "routes a quoted-symbol key to the pins" do
          expect(GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, "Person.name": "Ada")
            .execute("{ person(id: 1) { name } }").dig("data", "person", "name")).to eq "Ada"
        end

        it "tells an unknown option from an unknown pin" do
          expect { GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, overides: {}) }
            .to raise_error(ArgumentError, /a fake doesn't take overides:.*did you mean overrides:/)
          expect { GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, Persn: "Ada") }
            .to raise_error(GraphWeaver::Error, /override key "Persn" matches no type or field.*did you mean 'Person'/)
        end

        it "refuses a proc it couldn't call" do
          expect { person("Person.name" => ->(rng, extra) { [rng, extra] }) }
            .to raise_error(GraphWeaver::Error, /pin for "Person.name" takes no arguments, or one/)
        end
      end
    end

    it "picks a union member from the pinned __typename" do
      mod = GraphWeaver.parse(schema: Demo::Schema, name: "PinnedUnion",
        query: 'query { search(term: "x") { __typename ... on Person { name } ... on Pet { species } } }')
      pinned = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1,
        overrides: { "Query.search" => [{ "__typename" => "Person", "name" => "Ada" }] })

      result = mod.execute!(client: pinned).search
      expect(result.map(&:__typename)).to eq %w[Person]
      expect(result.first.name).to eq "Ada"
    end

    it "says to name __typename when the position is abstract" do
      pinned = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1,
        overrides: { "Query.search" => [{ "name" => "Ada" }] })

      expect { pinned.execute('query { search(term: "x") { ... on Named { name } } }') }
        .to raise_error(GraphWeaver::Error, /pins an object at search\.0.*Person or Pet.*__typename/m)
    end

    it "pins a field null" do
      mod = GraphWeaver.parse(schema: Demo::Schema, name: "PinnedNull",
        query: "query { person(id: 1) { name email } }", client: fake)

      expect(mod.execute!(client: GraphWeaver::Testing::FakeClient.new(
        schema: Demo::Schema, overrides: { "Person.email" => nil },
      )).person&.email).to be_nil
    end

    describe "override key validation" do
      def fake_with(overrides)
        GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, overrides:)
      end

      it "rejects a typo'd field, spellchecked" do
        expect { fake_with("Person.nmae" => "Daniel") }
          .to raise_error(GraphWeaver::Error, /"Person.nmae" is not a field of Person — did you mean 'name'\?/)
        expect { fake_with("nmae" => "Daniel") }
          .to raise_error(GraphWeaver::Error, /matches no type or field in this schema — did you mean 'name'\?/)
      end

      it "rejects a key whose type isn't in the schema" do
        expect { fake_with("Persn.name" => "Daniel") }
          .to raise_error(GraphWeaver::Error, /names no object type in this schema — did you mean 'Person'\?/)
      end

      it "accepts both key forms, and introspection fields" do
        expect { fake_with("Person.name" => "a", "name" => "b", "__typename" => "c") }.not_to raise_error
      end

      it "validates config overrides against the schema in play" do
        GraphWeaver::Testing.configure { |config| config.overrides = { "Person.nmae" => "Daniel" } }

        expect { fake_with({}) }.to raise_error(GraphWeaver::Error, /"Person.nmae"/)
      end
    end

    it "honors first/last/limit args when fabricating lists" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: fake,
        query: 'query Capped { search(term: "x", first: 3) { __typename ... on Named { name } } }',
      )

      expect(mod.execute!.search.size).to eq 3
    end

    it "honors null_chance and list_size" do
      always_nil = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1, null_chance: 1.0)
      # person is itself nullable, so it nils at the root
      expect(PersonQuery.execute!(client: always_nil, id: "1").person).to be_nil

      never_nil = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1, list_size: 2..2)
      person = PersonQuery.execute!(client: never_nil, id: "1").person
      expect(person&.birthday).to be_a Date # default null_chance 0: nullable but present
      expect(person&.pets&.size).to eq 2
    end
  end

  describe GraphWeaver::Internal::Values do
    let(:values) { GraphWeaver::Internal::Values.new(seed: 3) }

    it "gives numbers field-name semantics too" do
      expect(values.scalar("Int", "age")).to be_between(1, 99)
      expect(values.scalar("Float", "price")).to be_between(1.0, 10_000.0)
      expect(values.scalar("Int", "count")).to be_between(0, 100)
      expect(values.scalar("Float", "latitude")).to be_between(-90, 90)
    end

    it "falls back to type-based values for unmatched names" do
      expect(values.scalar("Int", "widget")).to be_a Integer
      expect(values.scalar("String", "widget")).to match(/widget/)
    end

    it "values: :literal skips semantics even with faker loaded" do
      literal = GraphWeaver::Internal::Values.new(seed: 3, values: :literal)

      expect(literal.scalar("String", "email")).to match(/^email-\d+$/)
    end

    it "rejects an unknown value style" do
      expect {
        GraphWeaver::Internal::Values.new(values: :chaos)
      }.to raise_error(ArgumentError, /:faker, :literal/)
    end

    # a suite-wide value style made every example's data someone else's
    # setting; the auto-detect (faker when loaded) is the only global left
    it "no longer takes a suite-wide value style" do
      expect { GraphWeaver::Testing.configure { |config| config.mode = :literal } }
        .to raise_error(NoMethodError)
    end

    it "keeps values: and the client mode apart" do
      expect {
        GraphWeaver::Testing.configure { |config| config.default_mode = :faker }
      }.to raise_error(ArgumentError, /default_mode: must be one of \[:fake, :in_process, :router\]/)
    end

    it "applies values: to what a fake fabricates" do
      GraphWeaver::Testing.configure { |config| config.schema = Demo::Schema }

      email = GraphWeaver::Testing::FakeClient.new(values: :literal)
        .execute("{ people { email } }").dig("data", "people", 0, "email")
      expect(email).to match(/\Aemail-\d+\z/)
    end
  end

  describe "rspec integration" do
    # capture the hooks install registers, then run them by hand
    let(:hooks) { Hash.new { |h, k| h[k] = [] } }
    let(:rspec_config) do
      recorder = hooks
      Class.new do
        define_method(:before) { |scope, &block| recorder[[:before, scope]] << block }
        define_method(:after) { |scope, &block| recorder[[:after, scope]] << block }
        define_method(:include) { |_mod| } # the graphql_context helper
      end.new
    end
    let(:context) { Object.new }

    def run(scope_key)
      hooks[scope_key].each { |block| context.instance_exec(&block) }
    end

    before do
      require "graph_weaver/rspec"
      GraphWeaver::Testing::RSpecIntegration.install(rspec_config)
    end

    it "defaults the seed to rspec's seed" do
      run([:before, :suite])

      expect(GraphWeaver::Testing.config.seed).to eq RSpec.configuration.seed
    end

    it "installs a client per example and restores the prior one" do
      GraphWeaver::Testing.configure do |config|
        config.schema = Demo::Schema
        config.default_mode = :fake
      end

      run([:before, :each])
      expect(GraphWeaver.client).to be_a GraphWeaver::Testing::FakeClient
      expect(PersonQuery.execute!(id: "1").person&.name).to be_a String

      run([:after, :each])
      expect { GraphWeaver.client! }.to raise_error(GraphWeaver::Error, /no client/)
    end

    # spec/support/federation_router_graph.rb composes it; naming the path
    # rather than its constant keeps this file type-checked
    let(:supergraph) { File.expand_path("support/federation/supergraph.graphql", __dir__) }

    # parsing a supergraph per example is real time; a context set by one
    # example leaking into the next is a real bug
    it "builds the router once, and resets its context every example" do
      GraphWeaver::Testing.configure do |config|
        config.router = { supergraph: }
        config.context = { current_user_id: "2" }
        config.default_mode = :router
      end

      run([:before, :each])
      router = GraphWeaver.client
      expect(router.execute("{ me { username } }").dig("data", "me", "username")).to eq "ada"
      router.context = { current_user_id: "1" }
      run([:after, :each])

      run([:before, :each])
      expect(GraphWeaver.client).to be router
      expect(GraphWeaver.client.execute("{ me { username } }").dig("data", "me", "username")).to eq "ada"
      run([:after, :each])
    end

    # the refusal names the modes, and is the one thing that says what to
    # fix — a NameError out of the cleanup reports a second failure over it
    it "cleans up after a tag it refused" do
      allow(RSpec).to receive(:current_example).and_return(double(metadata: { graphql: :fkae }))

      expect { run([:before, :each]) }.to raise_error(GraphWeaver::Error, /:fkae is not a mode/)
      expect { run([:after, :each]) }.not_to raise_error
    end

    it "defaults OFF — an untagged example keeps the app's client" do
      expect(GraphWeaver::Testing.config.default_mode).to be_nil

      run([:before, :each])
      expect { GraphWeaver.client! }.to raise_error(GraphWeaver::Error, /no client/)
    end

    it "derives the schema from the conventional dump" do
      Dir.mktmpdir do |dir|
        GraphWeaver.schema_path = File.join(dir, "schema.graphql")
        File.write(GraphWeaver.schema_path, Demo::Schema.to_definition)

        GraphWeaver::Testing.configure { |config| config.default_mode = :fake }

        run([:before, :each])
        expect(GraphWeaver.client).to be_a GraphWeaver::Testing::FakeClient
        run([:after, :each])
      ensure
        GraphWeaver.schema_path = nil
      end
    end
  end

  describe "#schema=" do
    # it serves two masters — the fakes' reference schema and the class
    # :in_process runs — and only a federated app makes them want different
    # objects. Setting a subgraph so :in_process had a live class silently
    # repointed :fake at a fraction of the graph.
    # The install generator always commits a dump, and a dump loads as an
    # anonymous GraphQL::Schema subclass — which looks runnable and has no
    # resolvers. Falling back to it produced a graphql-ruby 500 blaming the
    # user's own resolver.
    it "prefers the client's live class over a committed dump" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "schema.graphql")
        File.write(path, Demo::Schema.to_definition)
        GraphWeaver.schema_path = path
        GraphWeaver.client = GraphWeaver::InProcess.new(Demo::Schema)

        expect(described_class.config.schema_class!).to be Demo::Schema
      end
    ensure
      GraphWeaver.schema_path = nil
      GraphWeaver.client = nil
    end

    it "runs config.schema when it is a live class" do
      described_class.config.schema = Demo::Schema

      expect(described_class.config.schema_class!).to eq Demo::Schema
    end

    it "takes an ordinary schema class" do
      described_class.config.schema = Demo::Schema

      expect(described_class.config.explicit_schema).to be Demo::Schema
    end
  end

  describe "#router=" do
    let(:supergraph) { File.expand_path("support/federation/supergraph.graphql", __dir__) }

    # marking a remote subgraph :fake is the commonest federated config there
    # is, and it used to refuse unless you also restated where the supergraph
    # was — the case the docs call "no config at all"
    it "takes subgraphs alone, deriving the supergraph from the dump" do
      GraphWeaver.schema_path = supergraph
      described_class.configure { |config| config.router = { subgraphs: { "reviews" => :fake } } }

      expect(described_class.config.built_router.faked).to eq %w[reviews]
    ensure
      GraphWeaver.schema_path = nil
    end

    it "says what it takes when it isn't the arguments to build one" do
      expect { described_class.config.router = supergraph }
        .to raise_error(ArgumentError, /supergraph: .*subgraphs: /m)
    end
  end

  describe "#schema_class!" do
    around do |example|
      prior = GraphWeaver.client
      example.run
    ensure
      GraphWeaver.client = prior
    end

    it "takes the configured schema" do
      described_class.configure { |config| config.schema = Demo::Schema }

      expect(described_class.config.schema_class!).to be Demo::Schema
    end

    it "borrows the class the client already runs in-process" do
      GraphWeaver.client = GraphWeaver::InProcess.new(Demo::Schema)

      expect(described_class.config.schema_class!).to be Demo::Schema
    end

    it "names the fix when there's no live class to run against" do
      GraphWeaver.client = nil

      expect { described_class.config.schema_class! }
        .to raise_error(GraphWeaver::Error, /graphql_in_process\(MySchema\)/)
    end
  end

  describe ".configure" do
    it "applies config defaults to new executors" do
      described_class.configure do |config|
        config.seed = 7
        config.overrides = { "Person.name" => "from config" }
        config.list_size = 1..1
      end

      person = PersonQuery.execute!(
        client: GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema),
        id: "1",
      ).person

      expect(person&.name).to eq "from config"
      expect(person&.pets&.size).to eq 1
    end

    it "falls back to config.schema, like every other option" do
      described_class.configure { |config| config.schema = Demo::Schema }

      expect(PersonQuery.execute!(client: GraphWeaver::Testing::FakeClient.new, id: "1").person&.name)
        .to be_a String
    end

    it "says what to do when no schema resolves at all" do
      expect { GraphWeaver::Testing::FakeClient.new }
        .to raise_error(GraphWeaver::Error, /no schema to fake against.*config\.schema.*schema dump/m)
    end

    it "lets per-executor options win over config" do
      described_class.configure { |config| config.overrides = { "Person.name" => "config" } }

      executor = GraphWeaver::Testing::FakeClient.new(
        schema: Demo::Schema,
        seed: 1,
        overrides: { "Person.name" => "explicit" },
      )

      expect(PersonQuery.execute!(client: executor, id: "1").person&.name).to eq "explicit"
    end

    it "validates override keys when a schema is already configured" do
      expect {
        described_class.configure do |config|
          config.schema = Demo::Schema
          config.overrides = { "Person.nmae" => "Daniel" }
        end
      }.to raise_error(GraphWeaver::Error, /did you mean 'name'\?/)
    end

    it "resets to defaults" do
      described_class.configure { |config| config.seed = 99 }
      described_class.reset!

      expect(described_class.config.seed).to be_nil
      expect(described_class.config.list_size).to eq 1..3
    end
  end

  describe "review fixes" do
    it "merges duplicate-key selections so the fake casts against the generated struct" do
      mod = GraphWeaver.parse(schema: Demo::Schema, name: "DupKeys",
        query: "query { people { pets { name } pets { species } } }")
      fake = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1, list_size: 1..1)

      pet = mod.execute!(client: fake).people.first.pets.first # would raise (name missing) before the merge fix
      expect(pet.name).to be_a(String)
      expect(pet.species).not_to be_nil
    end

    it "fires fail_at on every execute, not just the first" do
      fake = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1, fail_at: "people.name")
      query = "query { people { name } }"

      expect(fake.execute(query)["errors"]).not_to be_nil
      expect(fake.execute(query)["errors"]).not_to be_nil # was nil (triggered stuck) before the fix
    end

    it "treats an Integer list_size as an exact length (a Range randomizes)" do
      fake = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1, list_size: 3)
      expect(fake.execute("query { people { name } }").dig("data", "people").size).to eq 3
    end
  end

  # Both lists are refusals with a spellcheck-free message — "must be one of
  # [...]" prints the constant — so an answer added here reaches the user as
  # a valid one the moment it exists, and docs/testing.md is where they'd
  # look for it.
  it "documents every mode and value style a spec can name" do
    docs = File.read(File.expand_path("../docs/testing.md", __dir__))

    expect(described_class::CLIENT_MODES.reject { |mode| docs.include?("graphql: :#{mode}") }).to be_empty
    expect(described_class::VALUE_STYLES.reject { |style| docs.include?(style.inspect) }).to be_empty
  end
end
