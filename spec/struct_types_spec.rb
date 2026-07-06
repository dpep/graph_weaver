require_relative "../lib/struct_types"

# Proves the class-generation layer can be swapped: a client whose @types
# module emits T::Structs instead of ObjectClass wrappers.
describe StructTypes do
  StructClient = GraphQL::Client.new(schema: Demo::Schema, execute: Demo::Schema)
  StructClient.instance_variable_set(:@types, StructTypes.generate(Demo::Schema))

  StructQuery = StructClient.parse <<~GRAPHQL
    query($id: ID!) {
      person(id: $id) {
        id
        name
        birthday
        pets {
          name
        }
      }
    }
  GRAPHQL

  let(:result) { StructClient.query(StructQuery, variables: { id: "1" }) }
  let(:person) { result.data.person }

  it "casts responses into generated T::Structs" do
    expect(result.data).to be_a T::Struct
    expect(person).to be_a T::Struct
    expect(person.pets.first).to be_a T::Struct
  end

  it "deserializes fields, including custom scalars" do
    expect(person.id).to eq "1"
    expect(person.name).to eq "Daniel"
    expect(person.birthday).to eq Date.new(1990, 6, 15)
    expect(person.pets.map(&:name)).to eq %w[Shelby Brownie]
  end

  it "types the generated props from the schema" do
    props = person.class.props

    expect(props[:name][:type_object].to_s).to eq "String" # non-null in schema
    expect(props[:birthday][:type_object].to_s).to eq "T.nilable(Date)"
    expect(props[:pets][:type_object].to_s).to eq "T::Array[StructTypes::Pet]"
  end

  it "enforces prop types at cast time" do
    # structs are real T::Structs, so a bad wire value raises
    bad_caster = StructQuery.schema_class
    expect {
      bad_caster.new({ "person" => "not a hash" })
    }.to raise_error(TypeError)
  end

  it "names generated structs after their graphql type" do
    expect(person.class.name).to eq "StructTypes::Person"
  end
end
