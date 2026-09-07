require "graph_weaver/testing"
require_relative "generated/person_query"
require_relative "generated/search_query"
require_relative "generated/add_pet_mutation"

describe GraphWeaver::Testing do
  after { GraphWeaver::Testing.reset! }

  let(:fake) { GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 42) }

  describe GraphWeaver::Testing::FakeClient do
    it "fabricates responses that cast cleanly through generated structs" do
      person = PersonQuery.execute!(fake, id: "1").person

      expect(person&.name).to be_a String
      expect(person&.pets).to all(be_a(PersonQuery::Result::Person::Pets))
      expect(person&.birthday).to be_a(Date).or be_nil
    end

    it "samples real enum values and valid union members" do
      results = SearchQuery.execute!(fake, term: "x").search

      results.each do |member|
        expect(%w[Person Pet]).to include(member.__typename)
      end

      pet = AddPetMutation.execute!(fake, name: "Rex", species: AddPetMutation::Species::Dog).add_pet
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

    describe "override key validation" do
      def fake_with(overrides)
        GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, overrides:)
      end

      it "rejects a typo'd field, spellchecked" do
        expect { fake_with("Person.nmae" => "Daniel") }
          .to raise_error(GraphWeaver::Error, /"Person.nmae" is not a field of Person — did you mean 'name'\?/)
        expect { fake_with("nmae" => "Daniel") }
          .to raise_error(GraphWeaver::Error, /matches no field in this schema — did you mean 'name'\?/)
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
      expect(PersonQuery.execute!(always_nil, id: "1").person).to be_nil

      never_nil = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1, list_size: 2..2)
      person = PersonQuery.execute!(never_nil, id: "1").person
      expect(person&.birthday).to be_a Date # default null_chance 0: nullable but present
      expect(person&.pets&.size).to eq 2
    end
  end

  describe GraphWeaver::Testing::Values do
    let(:values) { GraphWeaver::Testing::Values.new(seed: 3) }

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

    it "mode: :literal skips semantics even with faker loaded" do
      literal = GraphWeaver::Testing::Values.new(seed: 3, mode: :literal)

      expect(literal.scalar("String", "email")).to match(/^email-\d+$/)
    end

    it "rejects unknown modes" do
      expect {
        GraphWeaver::Testing::Values.new(mode: :chaos)
      }.to raise_error(ArgumentError, /:faker, :literal/)

      expect {
        GraphWeaver::Testing.configure { |config| config.mode = :chaos }
      }.to raise_error(ArgumentError, /:faker, :literal/)
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

    it "accepts auto_fake, the pre-tag spelling" do
      GraphWeaver::Testing.configure { |config| config.auto_fake = true }

      expect(GraphWeaver::Testing.config.default_mode).to eq :fake
      expect(GraphWeaver::Testing.config.auto_fake).to be true
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

  describe "#live_schema" do
    around do |example|
      prior = GraphWeaver.client
      example.run
    ensure
      GraphWeaver.client = prior
    end

    it "takes the configured schema" do
      described_class.configure { |config| config.schema = Demo::Schema }

      expect(described_class.config.live_schema).to be Demo::Schema
    end

    it "borrows the class the client already runs in-process" do
      GraphWeaver.client = GraphWeaver::InProcess.new(Demo::Schema)

      expect(described_class.config.live_schema).to be Demo::Schema
    end

    it "names the fix when there's no live class to run against" do
      GraphWeaver.client = nil

      expect { described_class.config.live_schema }
        .to raise_error(GraphWeaver::Error, /config\.schema = MySchema/)
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
        GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema),
        id: "1",
      ).person

      expect(person&.name).to eq "from config"
      expect(person&.pets&.size).to eq 1
    end

    it "falls back to config.schema, like every other option" do
      described_class.configure { |config| config.schema = Demo::Schema }

      expect(PersonQuery.execute!(GraphWeaver::Testing::FakeClient.new, id: "1").person&.name)
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

      expect(PersonQuery.execute!(executor, id: "1").person&.name).to eq "explicit"
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
      expect(described_class.config.null_chance).to eq 0.0
    end
  end

  describe "review fixes" do
    it "merges duplicate-key selections so the fake casts against the generated struct" do
      mod = GraphWeaver.parse(schema: Demo::Schema, name: "DupKeys",
        query: "query { people { pets { name } pets { species } } }")
      fake = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1, list_size: 1..1)

      pet = mod.execute!(fake).people.first.pets.first # would raise (name missing) before the merge fix
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
end
