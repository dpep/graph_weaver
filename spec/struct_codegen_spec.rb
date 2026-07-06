require_relative "../lib/struct_codegen"
require_relative "../lib/generated/person_query"
require_relative "../lib/generated/search_query"

describe StructCodegen do
  it "keeps the checked-in generated files up to date" do
    root = File.expand_path("..", __dir__)

    %w[person search].each do |base|
      source = described_class.new(
        schema: Demo::Schema,
        schema_const: "Demo::Schema",
        query: File.read(File.join(root, "queries/#{base}.graphql")),
        module_name: "#{base.capitalize}Query",
      ).generate

      expect(File.read(File.join(root, "lib/generated/#{base}_query.rb"))).to eq source
    end
  end

  it "rejects queries that do not validate against the schema" do
    codegen = described_class.new(
      schema: Demo::Schema,
      schema_const: "Demo::Schema",
      query: "{ nope }",
      module_name: "Bad",
    )

    expect { codegen.generate }.to raise_error(ArgumentError, /invalid query/)
  end

  describe "the generated module" do
    let(:result) { PersonQuery.execute({ "id" => "1" }) }
    let(:person) { result.person }

    it "executes and casts into the generated structs" do
      expect(result).to be_a PersonQuery::Result
      expect(person).to be_a PersonQuery::Result::Person
      expect(person.name).to eq "Daniel"
      expect(person.birthday).to eq Date.new(1990, 6, 15)
      expect(person.pets.map(&:name)).to eq %w[Shelby Brownie]
    end

    it "raises on failed queries" do
      expect { PersonQuery.execute }.to raise_error(/query failed/)
    end
  end

  describe "unions and fragments" do
    let(:results) { SearchQuery.execute({ "term" => "el" }).search }

    it "dispatches each result to its member struct via __typename" do
      expect(results.map(&:class)).to eq [
        SearchQuery::Result::SearchResult::Person,
        SearchQuery::Result::SearchResult::Pet,
      ]
      expect(results.map(&:__typename)).to eq %w[Person Pet]
    end

    it "casts member fields, including fragment-spread selections" do
      person, pet = results

      expect(person.name).to eq "Daniel"
      expect(person.birthday).to eq Date.new(1990, 6, 15)
      expect(pet.name).to eq "Shelby" # selected via the PetFields fragment
    end

    it "requires __typename on union selections" do
      codegen = described_class.new(
        schema: Demo::Schema,
        schema_const: "Demo::Schema",
        query: 'query { search(term: "x") { ... on Pet { name } } }',
        module_name: "Bad",
      )

      expect { codegen.generate }.to raise_error(ArgumentError, /__typename/)
    end
  end
end
