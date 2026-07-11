require "graph_weaver/testing"
require_relative "generated/person_query"
require_relative "generated/search_query"
require_relative "generated/add_pet_query"

describe GraphWeaver::Testing do
  after { GraphWeaver::Testing.reset! }

  let(:fake) { GraphWeaver::Testing::FakeExecutor.new(schema: Demo::Schema, seed: 42) }

  describe GraphWeaver::Testing::FakeExecutor do
    it "fabricates responses that cast cleanly through generated structs" do
      person = PersonQuery.execute!(id: "1", executor: fake).person

      expect(person&.name).to be_a String
      expect(person&.pets).to all(be_a(PersonQuery::Result::Person::Pet))
      expect(person&.birthday).to be_a(Date).or be_nil
    end

    it "samples real enum values and valid union members" do
      results = SearchQuery.execute!(term: "x", executor: fake).search

      results.each do |member|
        expect(%w[Person Pet]).to include(member.__typename)
      end

      pet = AddPetQuery.execute!(name: "Rex", species: AddPetQuery::Species::Dog, executor: fake).add_pet
      expect([AddPetQuery::Result::Pet::Species::Dog, AddPetQuery::Result::Pet::Species::Cat])
        .to include(pet.species)
    end

    it "is reproducible with a seed" do
      one = GraphWeaver::Testing::FakeExecutor.new(schema: Demo::Schema, seed: 7)
      two = GraphWeaver::Testing::FakeExecutor.new(schema: Demo::Schema, seed: 7)
      query = "query { people { name pets { name species } } }"

      expect(one.execute(query, variables: {})).to eq two.execute(query, variables: {})
    end

    it "generates semantic values from field names (faker)" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        query: "query { person(id: 1) { name email } }",
        executor: fake,
      )

      person = mod.execute!.person
      expect(person&.email).to match(/@/)
      expect(person&.name).not_to be_empty
    end

    it "pins fields via overrides, most-specific key first" do
      executor = GraphWeaver::Testing::FakeExecutor.new(
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
        executor:,
      )

      person = mod.execute!.person
      expect(person&.name).to eq "Daniel"                # Type.field wins
      expect(person&.email).to eq "me@example.com"       # proc override
      expect(person&.pets&.map(&:name)).to all(eq "generic") # field-name fallback
    end

    it "honors null_chance and list_size" do
      always_nil = GraphWeaver::Testing::FakeExecutor.new(schema: Demo::Schema, seed: 1, null_chance: 1.0)
      # person is itself nullable, so it nils at the root
      expect(PersonQuery.execute!(id: "1", executor: always_nil).person).to be_nil

      never_nil = GraphWeaver::Testing::FakeExecutor.new(schema: Demo::Schema, seed: 1, list_size: 2..2)
      person = PersonQuery.execute!(id: "1", executor: never_nil).person
      expect(person&.birthday).to be_a Date # default null_chance 0: nullable but present
      expect(person&.pets&.size).to eq 2
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
        id: "1",
        executor: GraphWeaver::Testing::FakeExecutor.new(schema: Demo::Schema),
      ).person

      expect(person&.name).to eq "from config"
      expect(person&.pets&.size).to eq 1
    end

    it "lets per-executor options win over config" do
      described_class.configure { |config| config.overrides = { "Person.name" => "config" } }

      executor = GraphWeaver::Testing::FakeExecutor.new(
        schema: Demo::Schema,
        seed: 1,
        overrides: { "Person.name" => "explicit" },
      )

      expect(PersonQuery.execute!(id: "1", executor:).person&.name).to eq "explicit"
    end

    it "resets to defaults" do
      described_class.configure { |config| config.seed = 99 }
      described_class.reset!

      expect(described_class.config.seed).to be_nil
      expect(described_class.config.null_chance).to eq 0.0
    end
  end
end
