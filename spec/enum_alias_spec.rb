# typed: ignore — loads generated code by constant name
require "tmpdir"

# Two wire spellings, one value. A schema mid-rename emits both so old clients
# keep working, and every generated pair collides on one Ruby constant —
# `alias:` says which spelling goes on the wire and reads the other as it.
module EnumAliasDemo
  class Mode < T::Enum
    enums do
      Legacy = new("legacy")
      Live = new("live")
    end
  end
end

describe "register_enum alias:" do
  after { GraphWeaver::Codegen.reset_registrations! }

  # the report's schema: a generated rename, both spellings declared
  let(:sdl) do
    <<~SDL
      enum Status {
        LEGACY_MODE
        legacy_mode @deprecated(reason: "Use LEGACY_MODE instead")
        ACTIVE
        active @deprecated(reason: "Use ACTIVE instead")
      }
      type Query { status(was: Status!): Status }
    SDL
  end
  let(:schema) { GraphQL::Schema.from_definition(sdl) }
  let(:query) { "query Q($was: Status!) { status(was: $was) }" }

  def capturing(response)
    Class.new do
      attr_reader :sent

      define_method(:execute) do |_query, variables:, **|
        @sent = variables
        { "data" => response }
      end
    end.new
  end

  describe "on a generated enum" do
    before { GraphWeaver.register_enum("Status", alias: { "legacy_mode" => "LEGACY_MODE", "active" => "ACTIVE" }) }

    it "gives the alias spelling no constant of its own" do
      src = GraphWeaver::Codegen.generate(schema:, query:, name: "Q")

      expect(src).to include('LegacyMode = new("LEGACY_MODE")')
      expect(src).to include('Active = new("ACTIVE")')
      expect(src).not_to include('new("legacy_mode")')
      expect(src).not_to include('new("active")')
    end

    it "casts either spelling to the one member, and puts the target on the wire" do
      client = capturing("status" => "legacy_mode")
      mod = GraphWeaver.parse(schema:, query:, name: "Q")

      result = mod.execute!(client:, was: mod::Status::LegacyMode)

      expect(result.status).to eq mod::Status::LegacyMode
      expect(client.sent).to eq("was" => "LEGACY_MODE")
    end

    # the shared-types workflow puts the enum in its own file and aliases every
    # name a query module spells — the table is one of them
    it "reaches a query module through the shared types module" do
      Dir.mktmpdir do |dir|
        queries = File.join(dir, "queries")
        FileUtils.mkdir_p(queries)
        File.write(File.join(dir, "schema.graphql"), sdl)
        File.write(File.join(queries, "status.graphql"), "query($was: Status!) { status(was: $was) }\n")

        GraphWeaver.generate!(
          schema: File.join(dir, "schema.graphql"), queries:, output: File.join(dir, "out"),
          types_module: "AliasTypes",
        )

        expect(File.read(File.join(dir, "out/types/status.rb"))).to include("ALIASES = T.let({")
        expect(File.read(File.join(dir, "out/status_query.rb")))
          .to include("STATUS_ALIASES = AliasTypes::STATUS_ALIASES")

        require File.join(dir, "out/status_query.rb")
        expect(StatusQuery::Result.from_h("status" => "legacy_mode").status)
          .to eq AliasTypes::Status::LegacyMode
      end
    end

    it "takes the alias spelling as a variable, and sends the target" do
      client = capturing("status" => "ACTIVE")
      mod = GraphWeaver.parse(schema:, query:, name: "Q")

      expect(mod.execute!(client:, was: "active").status).to eq mod::Status::Active
      expect(client.sent).to eq("was" => "ACTIVE")
    end
  end

  # The same rule on the mapped path: inference is case/underscore-insensitive,
  # so a rename pair lands on ONE member of your enum and only one spelling can
  # go back out. TO_WIRE used to be FROM_WIRE.invert, which silently kept
  # whichever came last in the sorted mapping — the deprecated one.
  describe "on an enum mapped onto your own" do
    let(:sdl) do
      <<~SDL
        enum Mode { LEGACY legacy LIVE }
        type Query { mode(was: Mode!): Mode }
      SDL
    end
    let(:query) { "query Q($was: Mode!) { mode(was: $was) }" }

    it "refuses two spellings on one member rather than picking one" do
      GraphWeaver.register_enum("Mode", EnumAliasDemo::Mode)

      expect { GraphWeaver::Codegen.generate(schema:, query:, name: "Q") }
        .to raise_error(GraphWeaver::Error, <<~MSG.chomp)
          enum Mode: LEGACY and legacy both map onto the EnumAliasDemo::Mode member "legacy" — say which spelling goes on the wire:
            GraphWeaver.register_enum("Mode", EnumAliasDemo::Mode, alias: { "legacy" => "LEGACY" })
        MSG
    end

    it "sends the target and still casts the alias" do
      GraphWeaver.register_enum("Mode", EnumAliasDemo::Mode, alias: { "legacy" => "LEGACY" })
      client = capturing("mode" => "legacy")
      mod = GraphWeaver.parse(schema:, query:, name: "Q")

      expect(mod.execute!(client:, was: EnumAliasDemo::Mode::Legacy).mode).to eq EnumAliasDemo::Mode::Legacy
      expect(client.sent).to eq("was" => "LEGACY")
    end
  end

  describe "the collision refusal" do
    it "names a pair, counts the rest, and prints the registration to paste" do
      expect { GraphWeaver::Codegen.generate(schema:, query:, name: "Q") }
        .to raise_error(GraphWeaver::Error, <<~MSG.chomp)
          enum Status values ACTIVE and active both become the constant Active (and 1 more colliding pair) — if each pair is one value, say which spelling goes on the wire:
            GraphWeaver.register_enum("Status", alias: { "active" => "ACTIVE", "legacy_mode" => "LEGACY_MODE" })
          or map the enum onto one of yours: register_enum("Status", YourEnum)
        MSG
    end

    it "counts no further pairs when there is only the one" do
      one = GraphQL::Schema.from_definition("enum E { active ACTIVE }\ntype Query { e: E }")

      expect { GraphWeaver::Codegen.generate(schema: one, query: "query Q { e }", name: "Q") }
        .to raise_error(GraphWeaver::Error, /both become the constant Active — if each pair/)
    end
  end

  describe "refusals" do
    it "refuses an alias onto a value the schema doesn't declare" do
      GraphWeaver.register_enum("Status", alias: { "legacy_mode" => "LEGACY", "active" => "ACTIVE" })

      expect { GraphWeaver::Codegen.generate(schema:, query:, name: "Q") }
        .to raise_error(
          GraphWeaver::Error,
          'enum Status: alias "legacy_mode" => "LEGACY" names no value of Status — its values are ' \
          "ACTIVE, LEGACY_MODE, active, legacy_mode; the target is the spelling that goes on the wire",
        )
    end

    it "refuses an alias for a value the schema doesn't declare" do
      GraphWeaver.register_enum("Status", alias: { "legacymode" => "LEGACY_MODE" })

      expect { GraphWeaver::Codegen.generate(schema:, query:, name: "Q") }
        .to raise_error(
          GraphWeaver::Error,
          'enum Status has no value "legacymode" to alias — its values are ' \
          "ACTIVE, LEGACY_MODE, active, legacy_mode; fix the spelling or drop the alias",
        )
    end

    it "refuses an alias that chains onto another alias" do
      expect { GraphWeaver.register_enum("Status", alias: { "a" => "b", "b" => "C" }) }
        .to raise_error(
          ArgumentError,
          'register_enum("Status"): "b" is both an alias and the value an alias points at — ' \
          "an alias can't chain; point every spelling at the one that goes on the wire",
        )
    end

    it "refuses an alias onto itself" do
      expect { GraphWeaver.register_enum("Status", alias: { "ACTIVE" => "ACTIVE" }) }
        .to raise_error(
          ArgumentError,
          'register_enum("Status"): alias "ACTIVE" => "ACTIVE" reads a value as itself — drop it',
        )
    end

    it "refuses a registration that says nothing" do
      expect { GraphWeaver.register_enum("Status") }
        .to raise_error(
          ArgumentError,
          'register_enum("Status") says nothing about Status — pass the T::Enum to map it onto, ' \
          'or alias: { "old" => "NEW" } to read two wire values as one',
        )
    end

    it "refuses fallback: with no T::Enum to describe" do
      expect { GraphWeaver.register_enum("Status", alias: { "active" => "ACTIVE" }, fallback: :x) }
        .to raise_error(
          ArgumentError,
          'register_enum("Status", alias: {...}) takes no fallback: — that describes a T::Enum of ' \
          'your own, so pass one: register_enum("Status", YourEnum, alias: {...})',
        )
    end
  end
end
