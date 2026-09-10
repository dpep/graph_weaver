# typed: ignore

require "graph_weaver/testing"
require_relative "generated/person_query"
require_relative "generated/search_query"
require_relative "generated/find_pets_query"
require_relative "generated/named_query"
require_relative "generated/add_pet_mutation"
require_relative "generated/adopt_mutation"

# The client slot is one contract, so the fake has to answer an invalid query
# the way the others do — it backs the default testing mode, and this is the
# mistake a developer makes most.
describe GraphWeaver::Testing::FakeClient do
  let(:schema) do
    GraphQL::Schema.from_definition("type Query { me: User } type User { name: String }")
  end

  it "reports an unknown field the way a real server does" do
    result = described_class.new(schema:).execute("query { me { nmae } }", variables: {})

    expect(result["data"]).to be_nil
    expect(result.dig("errors", 0, "message"))
      .to eq "Field 'nmae' doesn't exist on type 'User' (Did you mean `name`?)"
  end

  it "agrees with InProcess on the same query" do
    query = "query { me { nmae } }"

    expect(described_class.new(schema:).execute(query, variables: {}).dig("errors", 0, "message"))
      .to eq GraphWeaver::InProcess.new(schema).execute(query, variables: {}).dig("errors", 0, "message")
  end

  # a Symbol is the natural thing to type for the bare-field form, and it used
  # to validate clean and pin nothing
  it "pins on a Symbol override key, as on a String" do
    client = described_class.new(schema:, overrides: { name: "Ada" })

    expect(client.execute("{ me { name } }", variables: {}).dig("data", "me", "name")).to eq "Ada"
  end

  # a misspelled option fabricates with the default and leaves the example
  # green — the same silent pass a typo'd override key is refused for
  it "refuses an option it doesn't take" do
    expect { described_class.new(schema:, overides: { "User.name" => "Ada" }) }
      .to raise_error(ArgumentError, /overides:.*did you mean overrides:.*null_chance:/m)
  end

  it "still fabricates a valid query" do
    result = described_class.new(schema:).execute("query { me { name } }", variables: {})

    expect(result["errors"]).to be_nil
    expect(result.dig("data", "me", "name")).to be_a String
  end

  # The headline promise is that a fake casts cleanly through the generated
  # structs. `srb tc` can't check that and one seeded example barely can: the
  # fake's every choice — which union member, which enum value, where a null
  # lands, how long a list is — comes off the rng, so a shape it gets wrong
  # shows up in some fraction of runs and not the one the spec pinned.
  it "fabricates a response every generated module can read, whatever the seed" do
    # an app class is the shape only the registration can fabricate for, so
    # the promise has to hold through one of those too
    stub_const("Tag", Class.new do
      def self.parse(wire) = new(wire.fetch("label"))
      def initialize(label) = @label = label
      attr_reader :label
    end)
    GraphWeaver.register_scalar("Metadata", Tag, cast: :parse, serialize: :to_h,
      fake: ->(rng) { { "label" => "tag-#{rng.rand(100)}" } })
    tagged = GraphWeaver.parse(schema: Demo::Schema, name: "Tagged",
      query: "query Tagged { people { pets { metadata } } }")

    modules = [PersonQuery, SearchQuery, FindPetsQuery, NamedQuery, AddPetMutation, AdoptMutation, tagged]

    40.times do |seed|
      fake = described_class.new(schema: Demo::Schema, seed:, null_chance: 0.3, list_size: 0..3)

      modules.each do |mod|
        response = fake.execute(mod::QUERY, variables: {})
        expect(response["errors"]).to be_nil, "seed #{seed}, #{mod}: #{response["errors"].inspect}"
        expect { mod.from_response(response) }
          .not_to raise_error, "seed #{seed}, #{mod}: #{response.inspect}"
      end
    end
  ensure
    GraphWeaver::Codegen.reset_scalars!
  end

  describe "@skip / @include" do
    # The router evaluates them (spec/router_directives_spec.rb) and the fake
    # didn't, so one query carried a key under :fake and not under :router —
    # and a spec exercising the "field absent" branch never reached it.
    let(:pets) { GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1) }

    def keys(query, variables = {})
      pets.execute(query, variables:).dig("data", "people", 0).keys
    end

    it "leaves out what the directive drops" do
      expect(keys("{ people { name email @skip(if: true) } }")).to eq %w[name]
      expect(keys("{ people { name email @include(if: false) } }")).to eq %w[name]
      expect(keys("{ people { name email @skip(if: false) } }")).to eq %w[name email]
    end

    it "reads the variable it was passed, and the default when it wasn't" do
      query = 'query Q($show: Boolean = true) { people { name email @include(if: $show) } }'

      expect(keys(query)).to eq %w[name email]
      expect(keys(query, { "show" => false })).to eq %w[name]
    end

    it "drops a whole fragment the directive rules out" do
      query = "{ people { name ... on Person @skip(if: true) { email } } }"

      expect(keys(query)).to eq %w[name]
    end

    # #object is the _entities seam, and the router has already decided the
    # directive for the fetch it is sending — reading an unpassed variable
    # as absent there drops the field it just asked for
    it "leaves them alone at the object seam, where no variables were passed" do
      selections = GraphQL.parse('{ person { name email @include(if: $show) } }')
        .definitions.first.selections.first.selections

      expect(pets.object("Person", selections).keys).to eq %w[name email]
    end
  end

  describe "list length" do
    let(:fake) { GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1) }

    def size(query, variables = {})
      fake.execute(query, variables:).dig("data", "search").size
    end

    it "caps at a first: passed as a variable, not only a literal" do
      expect(size('query Q($n: Int) { search(term: "x", first: $n) { __typename } }', { "n" => 4 })).to eq 4
    end

    # Array.new(-1) raised "negative array size" from inside the fabricator
    it "reads a cap below zero as a page of none" do
      expect(size('{ search(term: "x", first: -1) { __typename } }')).to eq 0
    end
  end

  # A registered scalar's fake has to survive the codec codegen emitted for
  # it — the whole point of registering one.
  it "fabricates a custom scalar the value its registered type can hold" do
    sdl = "scalar Timestamp scalar Ticks type Query { event: Event } type Event { at: Timestamp! ticks: Ticks! }"
    GraphWeaver.register_scalar("Timestamp", Time, cast: :iso8601, serialize: :iso8601, requires: "time")
    GraphWeaver.register_scalar("Ticks", Integer)
    schema = GraphQL::Schema.from_definition(sdl)
    fake = described_class.new(schema:, seed: 1)

    mod = GraphWeaver.parse(schema:, name: "Event", query: "query Event { event { at ticks } }", client: fake)
    event = mod.execute!.event

    expect(event.at).to be_a Time
    expect(event.ticks).to be_an Integer
  ensure
    GraphWeaver::Codegen.reset_scalars!
  end

  # A `Type.field` registration is how the same scalar deserializes as
  # different Ruby types across fields — so the fake has to resolve it the
  # way codegen does, most specific first, or the emitted codec gets a value
  # fabricated for the wrong type.
  it "fabricates a per-field registration for the type that field deserializes into" do
    GraphWeaver.register_scalar("Person.email", Time, cast: :iso8601, serialize: :iso8601, requires: "time")
    fake = described_class.new(schema: Demo::Schema, seed: 1)

    mod = GraphWeaver.parse(schema: Demo::Schema, name: "Contact",
      query: "query Contact { people { name email } }", client: fake)

    expect(mod.execute!.people.first.email).to be_a Time
  ensure
    GraphWeaver::Codegen.reset_scalars!
  end
end
