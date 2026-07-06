require "sorbet-runtime"

# Can we hydrate query results into our own Ruby classes?
describe "hydrating custom classes" do
  HydrationQuery = Demo::Client.parse <<~GRAPHQL
    query($id: ID!) {
      person(id: $id) {
        name
        birthday
        pets {
          name
        }
      }
    }
  GRAPHQL

  class PetStruct < T::Struct
    const :name, String
  end

  class PersonStruct < T::Struct
    const :name, String
    const :birthday, Date
    const :pets, T::Array[PetStruct]
  end

  let(:result) { Demo::Client.query(HydrationQuery, variables: { id: "1" }) }
  let(:person) { result.data.person }

  it "hydrates a T::Struct from the response hash" do
    hydrated = PersonStruct.new(
      name: person.name,
      birthday: person.birthday,
      pets: person.pets.map { |pet| PetStruct.new(name: pet.name) },
    )

    expect(hydrated.name).to eq "Daniel"
    expect(hydrated.birthday).to eq Date.new(1990, 6, 15)
    expect(hydrated.pets.map(&:name)).to eq %w[Shelby Brownie]
  end

  it "enforces types at construction" do
    expect {
      PersonStruct.new(name: "x", birthday: "not a date", pets: [])
    }.to raise_error(TypeError)
  end
end
