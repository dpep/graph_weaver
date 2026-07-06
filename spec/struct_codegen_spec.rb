require_relative "../lib/struct_codegen"
require_relative "../lib/generated/person_query"

describe StructCodegen do
  let(:query) { File.read(File.expand_path("../queries/person.graphql", __dir__)) }

  subject(:codegen) do
    described_class.new(
      schema: Demo::Schema,
      schema_const: "Demo::Schema",
      query:,
      module_name: "PersonQuery",
    )
  end

  it "keeps the checked-in generated file up to date" do
    generated = File.read(File.expand_path("../lib/generated/person_query.rb", __dir__))
    expect(generated).to eq codegen.generate
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
end
