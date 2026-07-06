describe "graphql-client deserialization" do
  PersonQuery = Demo::Client.parse <<~GRAPHQL
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

  let(:result) { Demo::Client.query(PersonQuery, variables: { id: "1" }) }
  let(:person) { result.data.person }

  it "exposes fields as snake_case reader methods" do
    expect(person.id).to eq "1"
    expect(person.name).to eq "Daniel"
  end

  it "wraps each object in a class generated from the query selection" do
    expect(person.class.ancestors.map(&:name)).to include("GraphQL::Client::Schema::ObjectClass")
  end

  it "wraps nested lists in generated classes too" do
    expect(person.pets.map(&:name)).to eq %w[Shelby Brownie]
    expect(person.pets.first.class.ancestors.map(&:name)).to include("GraphQL::Client::Schema::ObjectClass")
  end

  it "deserializes custom scalars via the schema type's coerce_input" do
    # the wire value is the string "1990-06-15" (from DateType.coerce_result),
    # but the client casts it back through DateType.coerce_input when wrapping
    expect(person.birthday).to eq Date.new(1990, 6, 15)
    expect(person.birthday).to be_a Date
  end

  it "raises when accessing a field the query did not select" do
    expect { person.pets.first.id }.to raise_error(NoMethodError)
  end

  it "converts to plain hashes of raw wire values, not casted ones" do
    # note: birthday is the iso8601 string here, though the reader returns a Date
    expect(person.to_h).to eq(
      "id" => "1",
      "name" => "Daniel",
      "birthday" => "1990-06-15",
      "pets" => [
        { "name" => "Shelby" },
        { "name" => "Brownie" },
      ],
    )
  end
end
