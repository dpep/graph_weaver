require "graph_weaver/testing"
require "logger"
require "stringio"

# app-owned types for the enum-mapping and type-helper specs
class PetKind < T::Enum
  enums do
    Cat = new("cat")
    Dog = new("dog")
    Unknown = new("unknown")
  end
end

class CatsOnly < T::Enum
  enums do
    Cat = new("cat")
  end
end

module PetShouting
  def shout = "#{name}!"
end

# A sibling subgraph of Demo: one registry serves both, and neither schema
# declares the other's names.
PAYMENTS_SDL = <<~SDL
  scalar Money
  type Invoice { id: ID!, total: Money! }
  type Query { invoice(id: ID!): Invoice }
SDL

# One registry, global, consulted by every generation path — the console
# (parse) and the build step (generate!) alike.
describe "the registration registry" do
  after { GraphWeaver::Codegen.reset_registrations! }

  let(:client) { GraphWeaver.new(Demo::Schema) }
  let(:query) { "query { person(id: 1) { pets { species } } }" }
  let(:mutation) { "mutation($species: Species!) { addPet(name: \"Rex\", species: $species) { species } }" }

  describe "scalars" do
    it "applies to a client's own parse, with no per-client overlay to disagree with" do
      GraphWeaver.register_scalar("Date", String, cast: :itself, serialize: :itself)

      birthday = client.run!("query { person(id: 1) { birthday } }").person&.birthday
      expect(birthday).to be_a String
    end

    it "refuses a name this schema declares as something other than a scalar" do
      GraphWeaver.register_scalar("Species", String)

      expect { client.parse(query) }
        .to raise_error(GraphWeaver::Error, /register_scalar\("Species"\) names an enum, not a scalar/)
    end

    # fabrication is a test concern, said in test config — see the pin specs
    it "takes no fake:" do
      expect { GraphWeaver.register_scalar("Date", String, fake: "2020-01-01") }
        .to raise_error(ArgumentError, /unknown keyword: :fake/)
    end
  end

  describe "enum mappings" do
    it "casts wire values into the registered app enum, and serializes back" do
      GraphWeaver.register_enum("Species", PetKind)

      species = client.run!(query).person&.pets&.map(&:species)
      expect(species).to eq [PetKind::Dog, PetKind::Cat]

      # variables accept the member or its wire value
      expect(client.run!(mutation, species: PetKind::Dog).add_pet.species).to eq PetKind::Dog
      expect(client.run!(mutation, species: "CAT").add_pet.species).to eq PetKind::Cat
    end

    it "checks exhaustiveness at generation, naming the gaps" do
      GraphWeaver.register_enum("Species", CatsOnly)

      expect { client.parse(query) }
        .to raise_error(GraphWeaver::Error, /CatsOnly has no member for Species value\(s\) DOG/)
    end

    it "fallback: absorbs unknown wire values on cast; inputs stay strict" do
      GraphWeaver.register_enum("Species", CatsOnly, fallback: CatsOnly::Cat)

      species = client.run!(query).person&.pets&.map(&:species)
      expect(species).to eq [CatsOnly::Cat, CatsOnly::Cat] # DOG absorbed

      expect { client.run!(mutation, species: "DOG") }
        .to raise_error(GraphWeaver::InputError, /not a valid CatsOnly — expected one of: CAT/)
    end

    it "names the map: keyword when a value map is passed positionally" do
      # a bare "given 3, expected 2" never mentions the keyword
      message = 'register_enum: the value map is a keyword — register_enum("Species", PetKind, map: {...})'

      expect { GraphWeaver.register_enum("Species", PetKind, { "cat" => PetKind::Cat }) }
        .to raise_error(GraphWeaver::Error, message)
      expect { GraphWeaver::Codegen.register_enum("Species", PetKind, { "cat" => PetKind::Cat }) }
        .to raise_error(GraphWeaver::Error, message)
    end

    # a name is the natural workaround when the constant won't resolve, which
    # in Rails means an initializer — so say where it does resolve
    it "says where to register when handed a constant's name" do
      expect { GraphWeaver.register_enum("Species", "PetKind") }
        .to raise_error(ArgumentError, /register_enum\("Species", PetKind\).*to_prepare/m)
    end
  end

  describe "type helpers" do
    let(:query) { "query { person(id: 1) { pets { name species } } }" }

    it "includes registered modules into structs generated from the type" do
      GraphWeaver.extend_type("Pet", PetShouting)

      pet = client.run!(query).person&.pets&.first
      expect(pet&.shout).to eq "Shelby!"
      expect(pet&.name).to eq "Shelby" # the wire value stays honest
    end

    it "builds a mixin from a block, auto-named for generated source" do
      GraphWeaver.extend_type("Pet") do
        def whisper = "#{name.downcase}..."
      end

      pet = client.run!(query).person&.pets&.first
      expect(pet&.whisper).to eq "shelby..."
      expect(GraphWeaver::TypeHelpers.const_defined?(:Pet)).to be true

      # a second block registration stacks under a fresh name
      GraphWeaver.extend_type("Pet") { def echo = name * 2 }
      expect(client.run!(query).person&.pets&.first&.echo).to eq "ShelbyShelby"

      expect { GraphWeaver.extend_type("Pet") }.to raise_error(ArgumentError, /helper modules, a block, or alias/)
    end

    it "says where to register when handed a module's name" do
      expect { GraphWeaver.extend_type("Pet", "PetShouting") }
        .to raise_error(ArgumentError, /extend_type\("Pet", PetShouting\).*to_prepare/m)
    end
  end

  # One registry serves a whole graph while a generation sees one schema, so
  # a name this schema simply doesn't have may belong to a sibling subgraph.
  describe "a registration this schema doesn't match" do
    let(:io) { StringIO.new }

    around do |example|
      GraphWeaver.logger = Logger.new(io, level: Logger::WARN)
      example.run
    ensure
      GraphWeaver.logger = nil
    end

    it "warns rather than failing, and keeps the did-you-mean hint" do
      GraphWeaver.register_scalar("Dtae", String)

      expect { client.parse(query) }.not_to raise_error
      expect(io.string).to include(
        %{register_scalar("Dtae") matches no scalar in Demo::Schema } \
        "— a typo (did you mean 'Date'?), or a registration for another schema",
      )
    end

    it "warns for an enum, a type helper, and a field on a type that's elsewhere" do
      GraphWeaver.register_enum("Currency", PetKind)
      GraphWeaver.extend_type("Invoice", PetShouting)
      GraphWeaver.register_scalar("Invoice.due", String)

      expect { client.parse(query) }.not_to raise_error
      expect(io.string).to include(%{register_enum("Currency") matches no enum in Demo::Schema})
      expect(io.string).to include(%{extend_type("Invoice") matches no type in Demo::Schema})
      expect(io.string).to include(%{register_scalar("Invoice.due") matches no scalar field in Demo::Schema})
    end

    # an entity type is declared by every subgraph that references it, and its
    # fields are split across them, so a field missing here proves nothing
    it "warns on a field the type it names doesn't have, suggesting the coordinate" do
      GraphWeaver.register_scalar("Person.birthdya", String)

      expect { client.parse(query) }.not_to raise_error
      expect(io.string).to include(
        %{register_scalar("Person.birthdya") matches no scalar field in Demo::Schema } \
        "— a typo (did you mean 'Person.birthday'?), or a registration for another schema",
      )
    end

    it "still fails on a field that isn't a scalar" do
      GraphWeaver.register_scalar("Person.pets", String)

      expect { client.parse(query) }.to raise_error(GraphWeaver::Error, /isn't a scalar field/)
    end

    # the shape that drove this: register what the graph needs once, then
    # generate each query against the subgraph that serves it
    it "generates against two schemas from one set of registrations" do
      GraphWeaver.register_scalar("Money", String, cast: :itself, serialize: :itself)
      GraphWeaver.register_scalar("Person.birthday", String, cast: :itself, serialize: :itself)
      GraphWeaver.extend_type("Pet", PetShouting)

      demo = GraphWeaver.new(Demo::Schema)
      payments = GraphWeaver.new(PAYMENTS_SDL) # loaded, so unnamed

      expect { demo.parse("query { person(id: 1) { birthday pets { name } } }") }.not_to raise_error
      expect { payments.parse("query { invoice(id: 1) { total } }") }.not_to raise_error
      expect(io.string).to include(%{register_scalar("Money") matches no scalar in Demo::Schema})
      expect(io.string).to include(%{extend_type("Pet") matches no type in this schema})
      expect(io.string).to include(%{register_scalar("Person.birthday") matches no scalar field in this schema})
    end

    it "says nothing when registrations are scoped to each generation" do
      GraphWeaver.register_scalar("Person.birthday", String, cast: :itself, serialize: :itself)
      GraphWeaver.new(Demo::Schema).parse("query { person(id: 1) { birthday } }")

      GraphWeaver::Codegen.reset_registrations!
      GraphWeaver.register_scalar("Money", String, cast: :itself, serialize: :itself)
      GraphWeaver.new(PAYMENTS_SDL).parse("query { invoice(id: 1) { total } }")

      expect(io.string).to be_empty
    end

    # the build channel reads this rather than the log; a second, clean run
    # still reporting the first run's registrations would be a false alarm
    it "hands the list to the build, and clears it on a clean run" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "person.graphql"), "query { person(id: 1) { name } }\n")
        out = File.join(dir, "generated")

        GraphWeaver.register_scalar("Money", String, cast: :itself, serialize: :itself)
        GraphWeaver.generate!(schema: Demo::Schema, queries: dir, output: out)
        expect(GraphWeaver.unmatched_registrations).to contain_exactly(/register_scalar\("Money"\)/)

        GraphWeaver::Codegen.reset_registrations!
        GraphWeaver.generate!(schema: Demo::Schema, queries: dir, output: out)
        expect(GraphWeaver.unmatched_registrations).to be_empty
      end
    end
  end

  describe "resets" do
    before do
      GraphWeaver.register_scalar("Date", String, cast: :itself, serialize: :itself)
      GraphWeaver.register_enum("Species", PetKind)
      GraphWeaver.extend_type("Pet", PetShouting)
    end

    it "drops enum mappings on their own" do
      GraphWeaver::Codegen.reset_enums!

      expect(GraphWeaver::Codegen.enum_registry).to be_empty
      expect(GraphWeaver::Codegen.type_registry).not_to be_empty
    end

    it "drops type helpers on their own" do
      GraphWeaver::Codegen.reset_type_helpers!

      expect(GraphWeaver::Codegen.type_registry).to be_empty
      expect(GraphWeaver::Codegen.enum_registry).not_to be_empty
    end

    it "clears all three at once, built-in scalars restored" do
      GraphWeaver::Codegen.reset_registrations!

      expect(GraphWeaver::Codegen.enum_registry).to be_empty
      expect(GraphWeaver::Codegen.type_registry).to be_empty
      # the override is gone, the built-in Date codec is back
      expect(GraphWeaver::Codegen.scalar("Date").cast?).to be true
    end

    # a private_constant inside a method body runs on every call, so what
    # the gem exposes would depend on what a suite happened to reset
    it "leaves the constants Codegen exposes alone" do
      expect { GraphWeaver::Codegen.reset_registrations! }
        .not_to change { GraphWeaver::Codegen.constants(false).sort }
    end
  end

  describe "generation paths agree" do
    # the bug this collapse fixes: parse read a client-scoped registration
    # that generate! could not see, so the same query typed differently
    # depending on which door you came in by
    it "types a registered scalar identically via parse and via generate!" do
      query = "query { person(id: 1) { birthday } }"
      GraphWeaver.register_scalar("Date", String, cast: :itself, serialize: :itself)

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "person.graphql"), "#{query}\n")
        out = File.join(dir, "generated")
        GraphWeaver.generate!(schema: client, queries: dir, output: out)

        expect(File.read(File.join(out, "person_query.rb"))).to include("const :birthday, T.nilable(String)")
      end

      # ...and parse, from the same client, agrees
      expect(client.run!(query).person&.birthday).to be_a String
    end

    it "generate! takes a Client where it takes a schema" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "pet.graphql"), "query { person(id: 1) { name } }\n")
        out = File.join(dir, "generated")

        expect(GraphWeaver.generate!(schema: client, queries: dir, output: out).size).to eq 1
        expect(GraphWeaver.verify_generated!(schema: client, queries: dir, output: out)).to be true
      end
    end

    it "still refuses a live object as the baked client: constant" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "pet.graphql"), "query { person(id: 1) { name } }\n")

        expect { GraphWeaver.generate!(schema: client, queries: dir, output: dir, client: client) }
          .to raise_error(ArgumentError, /must be a named constant or String/)
      end
    end
  end
end
