# typed: ignore — the enum's constants only exist in a dynamically parsed module
require "logger"
require "stringio"

# A client of somebody else's API goes down the day that API adds an enum
# value. `fallback: true` buys the generated enum one extra member, Other,
# and every value the schema doesn't declare casts to it.
module EnumFallbackDemo
  class Kind < T::Enum
    enums do
      Bird = new("BIRD")
      Cat = new("CAT")
      Unknown = new("unknown")
    end
  end
end

describe "register_enum fallback: true" do
  after { GraphWeaver::Codegen.reset_registrations! }

  let(:sdl) do
    <<~SDL
      enum Species { BIRD CAT DOG }
      type Query { species(was: Species): Species }
    SDL
  end
  let(:schema) { GraphQL::Schema.from_definition(sdl) }
  let(:query) { "query Q($was: Species) { species(was: $was) }" }

  def client_for(response)
    Class.new do
      attr_reader :sent

      define_method(:execute) do |_query, variables:, **|
        @sent = variables
        { "data" => response }
      end
    end.new
  end

  describe "the generated enum" do
    before { GraphWeaver.register_enum("Species", fallback: true) }

    it "gains one member the schema never declares" do
      src = GraphWeaver::Codegen.generate(schema:, query:, name: "Q")

      expect(src).to include('Other = new("__other__")')
      expect(src).to include("GraphWeaver::Hints.enum(Species, v1, fallback: Species::Other)")
      expect(src).to include("GraphWeaver::InputStruct.enum(Species, v, fallback: Species::Other)")
    end

    it "casts a value the server added into Other" do
      mod = GraphWeaver.parse(schema:, query:, name: "Q")

      expect(mod::Result.from_h("species" => "AXOLOTL").species).to eq mod::Species::Other
    end

    it "leaves the declared values alone" do
      mod = GraphWeaver.parse(schema:, query:, name: "Q")

      expect(mod::Result.from_h("species" => "DOG").species).to eq mod::Species::Dog
      expect(mod::Result.from_h("species" => "DOG").species.serialize).to eq "DOG"
    end

    # Other is a T::Enum singleton, so the value it swallowed lives nowhere
    # else — the debug line is the whole record of it.
    it "names the value it absorbed at debug" do
      log = StringIO.new
      GraphWeaver.logger = Logger.new(log, level: Logger::DEBUG)
      mod = GraphWeaver.parse(schema:, query:, name: "Q")

      mod::Result.from_h("species" => "AXOLOTL")

      expect(log.string).to include('Species absorbed "AXOLOTL" into Other')
    ensure
      GraphWeaver.logger = nil
    end

    it "round-trips Other through as_json" do
      mod = GraphWeaver.parse(schema:, query:, name: "Q")
      result = mod::Result.from_h("species" => "AXOLOTL")

      expect(mod::Result.from_h(JSON.parse(result.as_json.to_json)).species).to eq mod::Species::Other
    end

    it "refuses to send Other as a variable" do
      mod = GraphWeaver.parse(schema:, query:, name: "Q")

      expect { mod.execute!(client: client_for("species" => "CAT"), was: mod::Species::Other) }
        .to raise_error(
          GraphWeaver::InputError,
          "$was of Q: #{mod::Species}::Other absorbs values the server added, so there is nothing to " \
          "send for it — expected one of: BIRD, CAT, DOG (got #<#{mod::Species}::Other>)",
        )
    end

    it "still refuses a variable the schema doesn't declare, without naming Other" do
      mod = GraphWeaver.parse(schema:, query:, name: "Q")

      expect { mod.execute!(client: client_for("species" => "CAT"), was: "AXOLOTL") }
        .to raise_error(
          GraphWeaver::InputError,
          "$was of Q: \"AXOLOTL\" is not a valid #{mod::Species} — expected one of: BIRD, CAT, DOG",
        )
    end

    it "sends a declared value as before" do
      client = client_for("species" => "CAT")
      mod = GraphWeaver.parse(schema:, query:, name: "Q")

      expect(mod.execute!(client:, was: mod::Species::Cat).species).to eq mod::Species::Cat
      expect(client.sent).to eq("was" => "CAT")
    end
  end

  it "combines with alias: on the one registration" do
    sdl = "enum Species { BIRD CAT cat }\ntype Query { species: Species }"
    GraphWeaver.register_enum("Species", alias: { "cat" => "CAT" }, fallback: true)
    mod = GraphWeaver.parse(schema: GraphQL::Schema.from_definition(sdl), query: "query Q { species }", name: "Q")

    expect(mod::Result.from_h("species" => "cat").species).to eq mod::Species::Cat
    expect(mod::Result.from_h("species" => "AXOLOTL").species).to eq mod::Species::Other
  end

  describe "without a fallback" do
    it "points the drift message at the registration that would absorb it" do
      mod = GraphWeaver.parse(schema:, query:, name: "Q")

      expect { mod::Result.from_h("species" => "AXOLOTL") }
        .to raise_error(
          GraphWeaver::CastError,
          "failed to cast response into #{mod::Result}: species: \"AXOLOTL\" is not a #{mod::Species} — " \
          "expected one of: BIRD, CAT, DOG; a value the server added since you generated needs a " \
          "regenerate, or register_enum fallback: true to absorb them",
        )
    end
  end

  describe "refusals" do
    it "refuses a schema that already declares the constant Other" do
      taken = GraphQL::Schema.from_definition("enum Species { CAT OTHER }\ntype Query { species: Species }")
      GraphWeaver.register_enum("Species", fallback: true)

      expect { GraphWeaver::Codegen.generate(schema: taken, query: "query Q { species }", name: "Q") }
        .to raise_error(
          GraphWeaver::Error,
          "enum Species declares OTHER, so a generated Other member couldn't be told apart from it — " \
          'map the enum onto one of yours: register_enum("Species", YourEnum, fallback: YourEnum::Unknown)',
        )
    end

    it "refuses a member name where the generated enum generates its own" do
      expect { GraphWeaver.register_enum("Species", fallback: :other) }
        .to raise_error(
          ArgumentError,
          'register_enum("Species", fallback: :other): the generated enum generates its fallback member ' \
          "too, so say fallback: true. To fall back onto a member of your own, pass the T::Enum: " \
          'register_enum("Species", YourEnum, fallback: YourEnum::Unknown)',
        )
    end

    it "refuses fallback: true where a T::Enum of your own owns the members" do
      expect { GraphWeaver.register_enum("Species", EnumFallbackDemo::Kind, fallback: true) }
        .to raise_error(ArgumentError, "fallback: must be a EnumFallbackDemo::Kind member, got true")
    end
  end
end
