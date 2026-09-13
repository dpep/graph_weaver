# typed: false
require_relative "generated/find_pets_query"
require_relative "generated/person_query"
require_relative "generated/search_query"

# an app enum whose fallback member matches no wire value, so it is in no
# wire table — see the mapped-enum example below
class ResultStructKind < T::Enum
  enums do
    Dog = new("DOG")
    Cat = new("CAT")
    Unknown = new("UNKNOWN")
  end
end

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

    # The promise the docs make about caching: Marshal restores the canonical
    # T::Enum member, so the result still equals itself. YAML can't — Psych
    # allocates the object before filling it, and sorbet compares enum members
    # by identity — which is why the docs say Marshal.
    it "survives a Marshal round trip" do
      expect(Marshal.load(Marshal.dump(pets))).to eq pets
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

  describe "#as_json" do
    it "is the wire shape: response keys, and each leaf back the way it arrived" do
      expect(person(birthday: nil).as_json).to eq(
        "person" => { "id" => "1", "name" => "Daniel", "birthday" => nil,
                      "pets" => [{ "name" => "Nibbler" }] },
      )
      expect(pets.as_json).to eq(
        "findPets" => [{ "name" => "Nibbler", "species" => "CAT", "metadata" => nil }],
      )
    end

    it "reads back through .from_h as an equal struct" do
      [person, person(birthday: nil), pets, pets(species: "DOG")].each do |result|
        expect(result.class.from_h(JSON.parse(result.to_json))).to eq result
      end
    end

    # a union dispatches on __typename, so the tag has to survive the trip
    it "round-trips an abstract field through its __typename" do
      result = SearchQuery::Result.from_h(
        "search" => [
          { "__typename" => "Person", "name" => "Daniel", "birthday" => "1984-05-06" },
          { "__typename" => "Pet", "name" => "Nibbler", "species" => "CAT" },
          { "__typename" => "Robot", "name" => nil },
        ],
      )

      expect(SearchQuery::Result.from_h(JSON.parse(result.to_json))).to eq result
    end

    # `render json: result` goes through as_json, so the response key is what
    # reaches the browser — not the prop, whose trailing underscore is a Ruby
    # artifact the schema never said
    it "names a reserved key by its wire name, not the renamed prop" do
      mod = GraphWeaver.parse(schema: reserved_schema, query: "{ thing { class hash } }", name: "ThingQuery")
      result = mod::Result.from_h("thing" => { "class" => "A", "hash" => "B" })

      expect(result.as_json).to eq("thing" => { "class" => "A", "hash" => "B" })
      expect(mod::Result.from_h(JSON.parse(result.to_json))).to eq result
    end

    it "is what #to_json encodes" do
      expect(JSON.parse(person.to_json)).to eq person.as_json
    end

    # The fallback member is in no wire table — several wire values collapse
    # into it, so `invert` keeps none — and it is exactly what a drifted
    # response casts to. Its own #serialize casts back to the fallback, so the
    # result still reads back; a bare fetch raised KeyError out of #to_json.
    it "renders a mapped enum's fallback member rather than raising" do
      GraphWeaver.register_enum("Species", ResultStructKind, fallback: ResultStructKind::Unknown)
      mod = GraphWeaver.parse(schema: Demo::Schema, query: "{ findPets { species } }", name: "KindQuery")
      result = mod::Result.from_h("findPets" => [{ "species" => "FERRET" }])

      expect(result.find_pets.map(&:species)).to eq [ResultStructKind::Unknown]
      expect(result.as_json).to eq("findPets" => [{ "species" => "UNKNOWN" }])
      expect(mod::Result.from_h(JSON.parse(result.to_json))).to eq result
    ensure
      GraphWeaver::Codegen.reset_enums!
    end

    # The rule IS a round trip, so the honest check is the property, over
    # responses the schema permits rather than the handful written above.
    # bin/round-trip runs the same shape unbounded, on real schemas.
    it "round-trips every response the fuzzer builds" do
      seed = 20260907
      failures = []

      40.times do |i|
        rng = Random.new(seed + i)
        query = RoundTrip::Fuzzer.new(Demo::Schema, rng).query
        next unless query && Demo::Schema.validate(query).empty?

        trip = RoundTrip.check(schema: Demo::Schema, query:, name: "AsJson#{i}", rng:)
        next unless trip.checked? && trip.result

        back = trip.result.class.from_h(JSON.parse(trip.result.to_json))
        failures << "seed #{seed + i}: #{trip.query}" unless back == trip.result
      end

      expect(failures).to be_empty, -> { failures.join("\n") }
    end
  end

  # a schema whose field names are reserved Ruby prop names
  def reserved_schema
    Class.new(GraphQL::Schema) do
      thing = Class.new(GraphQL::Schema::Object) do
        graphql_name "Thing"
        field :class, String, null: false, resolver_method: :klass
        field :hash, String, null: false, resolver_method: :hsh
        define_method(:klass) { "A" }
        define_method(:hsh) { "B" }
      end
      query(Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :thing, thing, null: false
      end)
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
