
require_relative "generated/add_pet_query"
require_relative "generated/named_query"
require_relative "generated/person_query"
require_relative "generated/search_query"

describe GraphWeaver::Codegen do
  it "keeps the checked-in generated files up to date" do
    root = File.expand_path("..", __dir__)

    %w[add_pet named person search].each do |base|
      source = described_class.new(
        schema: Demo::Schema,
        executor_const: "Demo::Schema",
        query: File.read(File.join(root, "spec/queries/#{base}.graphql")),
        module_name: "#{base.split("_").map(&:capitalize).join}Query",
      ).generate

      expect(File.read(File.join(root, "spec/generated/#{base}_query.rb"))).to eq source
    end
  end

  it "rejects queries that do not validate against the schema" do
    codegen = described_class.new(
      schema: Demo::Schema,
      executor_const: "Demo::Schema",
      query: "{ nope }",
      module_name: "Bad",
    )

    expect { codegen.generate }.to raise_error(ArgumentError, /invalid query/)
  end

  describe "the generated module" do
    let(:result) { PersonQuery.execute(id: "1") }
    let(:person) { result.person }

    it "executes and casts into the generated structs" do
      expect(result).to be_a PersonQuery::Result
      expect(person).to be_a PersonQuery::Result::Person
      expect(person.name).to eq "Daniel"
      expect(person.birthday).to eq Date.new(1990, 6, 15)
      expect(person.pets.map(&:name)).to eq %w[Shelby Brownie]
    end

    it "raises on failed queries" do
      failing = Class.new do
        def execute(_query, variables:)
          { "errors" => [{ "message" => "boom" }] }
        end
      end

      expect { PersonQuery.execute(id: "1", executor: failing.new) }.to raise_error(/query failed/)
    end
  end

  describe "unions and fragments" do
    let(:results) { SearchQuery.execute(term: "el").search }

    it "dispatches each result to its member struct via __typename" do
      expect(results.map(&:class)).to eq [
        SearchQuery::Result::SearchResult::Person,
        SearchQuery::Result::SearchResult::Pet,
      ]
      expect(results.map(&:__typename)).to eq %w[Person Pet]
    end

    it "casts member fields, including interface-condition and fragment-spread selections" do
      person, pet = results

      expect(person.name).to eq "Daniel" # selected via `... on Named`
      expect(person.birthday).to eq Date.new(1990, 6, 15)
      expect(pet.name).to eq "Shelby"
      expect(pet.species).to eq SearchQuery::Result::SearchResult::Pet::Species::Dog
    end

    it "deserializes enums into generated T::Enums" do
      species = SearchQuery::Result::SearchResult::Pet::Species

      expect(species.values).to eq [species::Cat, species::Dog]
      expect(species::Dog.serialize).to eq "DOG"
    end

    it "requires __typename on union selections" do
      codegen = described_class.new(
        schema: Demo::Schema,
        executor_const: "Demo::Schema",
        query: 'query { search(term: "x") { ... on Pet { name } } }',
        module_name: "Bad",
      )

      expect { codegen.generate }.to raise_error(ArgumentError, /__typename/)
    end
  end

  describe "interface-typed fields" do
    it "dispatches to member structs like unions" do
      pet = NamedQuery.execute(name: "Shelby").named
      person = NamedQuery.execute(name: "Daniel").named

      expect(pet).to be_a NamedQuery::Result::Named::Pet
      expect(pet.name).to eq "Shelby" # interface field, gathered into every member
      expect(pet.species).to eq NamedQuery::Result::Named::Pet::Species::Dog
      expect(person).to be_a NamedQuery::Result::Named::Person
      expect(person.name).to eq "Daniel"
    end
  end

  describe "mutations and typed variables" do
    it "executes mutations with typed kwargs, serializing enum variables" do
      result = AddPetQuery.execute(name: "Rex", species: AddPetQuery::Species::Dog)

      expect(result.add_pet.name).to eq "Rex"
      expect(result.add_pet.species).to eq AddPetQuery::Result::Pet::Species::Dog
    end

    it "omits optional variables from the wire when nil" do
      mod = described_class.load(
        schema: Demo::Schema,
        executor_const: "Demo::Schema",
        query: <<~GRAPHQL,
          query($term: String = "el") {
            search(term: $term) {
              __typename
              ... on Named {
                name
              }
            }
          }
        GRAPHQL
        module_name: "DynamicDefaultedSearch",
      )

      names = mod.execute.search.map(&:name)
      expect(names).to eq %w[Daniel Shelby] # server applied the "el" default
    end
  end

  describe ".load (dynamic mode)" do
    it "generates and evals a module on the fly, no build artifact" do
      mod = described_class.load(
        schema: Demo::Schema,
        executor_const: "Demo::Schema",
        query: "query { people { name } }",
        module_name: "DynamicPeopleQuery",
      )

      result = mod.execute
      expect(result.people.map(&:name)).to eq ["Daniel"]
    end
  end
end
