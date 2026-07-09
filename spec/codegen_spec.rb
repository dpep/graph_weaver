
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
        executor: Demo::Schema,
        query: File.read(File.join(root, "spec/queries/#{base}.graphql")),
        module_name: "#{base.split("_").map(&:capitalize).join}Query",
      ).generate

      expect(File.read(File.join(root, "spec/generated/#{base}_query.rb"))).to eq source
    end
  end

  it "rejects queries that do not validate against the schema" do
    codegen = described_class.new(
      schema: Demo::Schema,
      executor: Demo::Schema,
      query: "{ nope }",
      module_name: "Bad",
    )

    expect { codegen.generate }.to raise_error(ArgumentError, /invalid query/)
  end

  describe "the generated module" do
    let(:response) { PersonQuery.execute(id: "1") }
    let(:result) { response.data! }
    let(:person) { result.person }

    it "executes and casts into the generated structs" do
      expect(response).to be_a PersonQuery::Response
      expect(result).to be_a PersonQuery::Result
      expect(person).to be_a PersonQuery::Result::Person
      expect(person.name).to eq "Daniel"
      expect(person.birthday).to eq Date.new(1990, 6, 15)
      expect(person.pets.map(&:name)).to eq %w[Shelby Brownie]
    end

    it "returns errors in the envelope; data! raises QueryError" do
      failing = Class.new do
        def execute(_query, variables:)
          { "errors" => [{ "message" => "boom", "extensions" => { "code" => "OOPS" } }] }
        end
      end

      response = PersonQuery.execute(id: "1", executor: failing.new)
      expect(response.errors?).to be true
      expect(response.errors.first.code).to eq "OOPS"
      expect { response.data! }.to raise_error(GraphWeaver::QueryError, /boom/)
    end
  end

  describe "unions and fragments" do
    let(:results) { SearchQuery.execute(term: "el").data!.search }

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
        executor: Demo::Schema,
        query: 'query { search(term: "x") { ... on Pet { name } } }',
        module_name: "Bad",
      )

      expect { codegen.generate }.to raise_error(ArgumentError, /__typename/)
    end
  end

  describe "interface-typed fields" do
    it "dispatches to member structs like unions" do
      pet = NamedQuery.execute(name: "Shelby").data!.named
      person = NamedQuery.execute(name: "Daniel").data!.named

      expect(pet).to be_a NamedQuery::Result::Named::Pet
      expect(pet.name).to eq "Shelby" # interface field, gathered into every member
      expect(pet.species).to eq NamedQuery::Result::Named::Pet::Species::Dog
      expect(person).to be_a NamedQuery::Result::Named::Person
      expect(person.name).to eq "Daniel"
    end
  end

  describe "mutations and typed variables" do
    it "executes mutations with typed kwargs, serializing enum variables" do
      result = AddPetQuery.execute(name: "Rex", species: AddPetQuery::Species::Dog).data!

      expect(result.add_pet.name).to eq "Rex"
      expect(result.add_pet.species).to eq AddPetQuery::Result::Pet::Species::Dog
    end

    it "omits optional variables from the wire when nil" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        executor: Demo::Schema,
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
      )

      names = mod.execute.data!.search.map(&:name)
      expect(names).to eq %w[Daniel Shelby] # server applied the "el" default
    end
  end

  describe "GraphWeaver.parse (dynamic mode)" do
    it "evals a module on the fly, deriving the name from the operation" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        executor: Demo::Schema,
        query: "query People { people { name } }",
      )

      expect(mod.execute.data!.people.map(&:name)).to eq ["Daniel"]
    end

    it "derives the module name from a .graphql file" do
      # person.graphql's operation is anonymous, so this only works if
      # the name comes from the file name
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        executor: Demo::Schema,
        query: File.expand_path("queries/person.graphql", __dir__),
      )

      expect(mod.execute(id: "1").data!.person&.name).to eq "Daniel"
    end

    it "parses anonymous raw query strings, defaulting the name" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        executor: Demo::Schema,
        query: "query { people { name } }",
      )

      expect(mod.execute.data!.people.map(&:name)).to eq ["Daniel"]
    end

    it "still requires a deliberate name when generating files" do
      expect {
        described_class.generate(schema: Demo::Schema, query: "query { people { name } }")
      }.to raise_error(ArgumentError, /module_name/)
    end

    it "does not leak global constants" do
      GraphWeaver.parse(
        schema: Demo::Schema,
        executor: Demo::Schema,
        query: "query Leaky { people { name } }",
      )

      expect(defined?(::Leaky)).to be_nil
    end
  end

  describe "executors" do
    let(:mod) do
      GraphWeaver.parse(schema: Demo::Schema, query: "query People { people { name } }")
    end

    it "falls back to GraphWeaver.executor, raising when unconfigured" do
      expect { mod.execute }.to raise_error(GraphWeaver::Error, /no executor configured/)

      begin
        GraphWeaver.executor = Demo::Schema
        expect(mod.execute.data!.people.map(&:name)).to eq ["Daniel"]
      ensure
        GraphWeaver.executor = nil
      end
    end

    it "supports per-module override" do
      mod.executor = Demo::Schema

      expect(mod.execute.data!.people.map(&:name)).to eq ["Daniel"]
    end
  end

  describe "GraphWeaver.execute (one-shot)" do
    it "runs a query in-process with variables" do
      result = GraphWeaver.execute(
        schema: Demo::Schema,
        query: "query($id: ID!) { person(id: $id) { name } }",
        variables: { id: "1" },
      )

      expect(result.person&.name).to eq "Daniel"
    end

    it "accepts graphql-cased variable keys" do
      result = GraphWeaver.execute(
        schema: Demo::Schema,
        query: 'query($term: String!) { search(term: $term) { __typename ... on Named { name } } }',
        variables: { "term" => "el" },
      )

      expect(result.search.map(&:name)).to eq %w[Daniel Shelby]
    end

    it "prefers GraphWeaver.executor over in-process execution" do
      recorded = []
      recorder = Class.new do
        define_method(:initialize) { |log| @log = log }
        define_method(:execute) do |query, variables:|
          @log << variables
          Demo::Schema.execute(query, variables:)
        end
      end

      begin
        GraphWeaver.executor = recorder.new(recorded)
        result = GraphWeaver.execute(
          schema: Demo::Schema,
          query: "query($id: ID!) { person(id: $id) { name } }",
          variables: { id: "1" },
        )

        expect(result.person&.name).to eq "Daniel"
        expect(recorded).to eq [{ "id" => "1" }]
      ensure
        GraphWeaver.executor = nil
      end
    end

    it "prefers an explicit executor over the default" do
      failing = Class.new do
        def execute(_query, variables:)
          { "errors" => [{ "message" => "wrong executor" }] }
        end
      end

      begin
        GraphWeaver.executor = failing.new
        result = GraphWeaver.execute(
          schema: Demo::Schema,
          query: "query($id: ID!) { person(id: $id) { name } }",
          variables: { id: "1" },
          executor: Demo::Schema,
        )

        expect(result.person&.name).to eq "Daniel"
      ensure
        GraphWeaver.executor = nil
      end
    end
  end
end
