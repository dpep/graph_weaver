# typed: false
require_relative "generated/find_pets_query"
require_relative "generated/person_query"

describe GraphWeaver::ResultStruct do
  def person(name: "Daniel", birthday: "1984-05-06", pets: [{ "name" => "Nibbler" }])
    PersonQuery::Result.from_h(
      "person" => { "id" => "1", "name" => name, "birthday" => birthday, "pets" => pets },
    )
  end

  def pets(species: "CAT")
    FindPetsQuery::Result.from_h(
      "findPets" => [{ "name" => "Nibbler", "species" => species, "metadata" => nil }],
    )
  end

  describe "equality" do
    it "compares by value, all the way down" do
      expect(person).to eq person
      expect(person).not_to eq person(pets: [{ "name" => "Zoidberg" }])
    end

    it "is not equal to a struct of another class holding the same props" do
      expect(person.person).not_to eq Struct.new(:id, :name, :birthday, :pets)
    end

    it "works as a hash key" do
      counts = Hash.new(0)
      counts[person] += 1
      counts[person] += 1

      expect(counts).to eq(person => 2)
    end
  end

  describe "pattern matching" do
    it "destructures, including through a nested struct" do
      case person
      in { person: { name: String => name, pets: [{ name: pet }] } }
        expect([name, pet]).to eq ["Daniel", "Nibbler"]
      else
        raise "no match"
      end
    end

    it "binds a nested struct as itself, not as a hash" do
      person => { person: PersonQuery::Result::Person => found }

      expect(found.name).to eq "Daniel"
    end
  end

  describe "#to_h" do
    it "follows nested structs and lists, keeps nils, and leaves enums alone" do
      expect(person(birthday: nil).to_h).to eq(
        person: { id: "1", name: "Daniel", birthday: nil, pets: [{ name: "Nibbler" }] },
      )
      expect(pets.to_h).to eq(
        find_pets: [{ name: "Nibbler", species: GraphQLTypes::Species::Cat, metadata: nil }],
      )
    end

    # the Ruby shape, not the wire's: snake_case prop names, and a scalar
    # keeps whatever object its codec built
    it "is not the response it was parsed from" do
      expect(person.to_h[:person][:birthday]).to eq Date.new(1984, 5, 6)
      expect(pets.to_h.keys).to eq [:find_pets]
    end

    # A leaf is the object the codec built, in to_h and off the reader alike —
    # duping one here would hand back a different Money than `result.price`,
    # and freezing it reaches into an object register_scalar owns. So a result
    # is immutable as far as its props go and no further, like Struct or Data:
    # `result.name << "!"` changes the result, and the docs say so.
    it "hands back the leaf itself, not a copy" do
      result = person

      expect(result.to_h[:person][:name]).to equal result.person.name
    end
  end

  # the behaviour is only real if every struct codegen emits gets the module
  it "is included in every result struct codegen emits" do
    src = GraphWeaver::Codegen.generate(
      schema: Demo::Schema,
      query: File.read(File.expand_path("queries/person.graphql", __dir__)),
      name: "PersonQuery",
    )

    structs = src.scan(/^\s*class \w+ < T::Struct$/).size
    expect(structs).to be > 1 # nested ones too, not just Result
    expect(src.scan("include GraphWeaver::ResultStruct").size).to eq structs
  end
end
