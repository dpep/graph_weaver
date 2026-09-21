# typed: false
require "bigdecimal"
require "graph_weaver/testing"

# A server that writes a decimal as a JSON number: exact to the seventh
# significant figure, which is the precision a string-valued Decimal exists to
# protect.
module LossyDemo
  class LossyType < GraphQL::Schema::Scalar
    graphql_name "Lossy"
    def self.coerce_input(value, _ctx) = BigDecimal(value)
    def self.coerce_result(value, _ctx) = value.to_f
  end

  class QueryType < GraphQL::Schema::Object
    graphql_name "Query"
    field :total, LossyType, null: false
  end

  class Schema < GraphQL::Schema
    query QueryType
  end
end

# A custom scalar has two definitions that have to agree — the server's
# coerce_input/coerce_result and the app's register_scalar — and no schema
# carries the first. A schema CLASS carries both, so check_scalars! runs them
# against each other.
describe "GraphWeaver::Testing.check_scalars!" do
  after { GraphWeaver.reset_registrations! }

  # Demo's Date scalar: coerce_input is Date.iso8601, coerce_result is
  # Date#iso8601 — a date, not a timestamp.
  def check = GraphWeaver::Testing.check_scalars!(Demo::Schema)

  it "says nothing when the two halves agree" do
    GraphWeaver.register_scalar("Date", Date)

    expect { check }.not_to raise_error
  end

  # The registration docs/scalars.md warns about in prose — "a date stays a
  # Date and a timestamp a Time" — now caught before a request runs.
  it "catches a cast: that can't read what the server's coerce_result writes" do
    GraphWeaver.register_scalar("Date", Time)

    expect { check }.to raise_error(GraphWeaver::Error, <<~MESSAGE.chomp)
      1 scalar(s) disagree with Demo::Schema:
        Date: cast: refused "2020-10-09", the result form the server's coerce_result writes (invalid xmlschema format: "2020-10-09")
    MESSAGE
  end

  it "catches a wire form the server's coerce_input refuses" do
    GraphWeaver.register_scalar("Date", Integer)

    expect { check }.to raise_error(GraphWeaver::Error,
      /Date: the server refused \d+, the wire form serialize: writes \(no implicit conversion/)
  end

  # The fabricated value is all the check has to work with, so the value that
  # matters has to be pinned — two decimal places always survive a Float.
  it "catches a lossy round trip, and says what was lost" do
    GraphWeaver::Testing.configure { |config| config.overrides = { "Lossy" => "123456789.123456789" } }
    GraphWeaver.register_scalar("Lossy", BigDecimal)

    expect { GraphWeaver::Testing.check_scalars!(LossyDemo::Schema) }.to raise_error(
      GraphWeaver::Error,
      /Lossy: round-trips lossily — sent 123456789\.123456789, got back 123456789\.1234567/,
    )
  ensure
    GraphWeaver::Testing.reset!
  end

  it "says a serialize: Proc is source and can't be run against a value" do
    GraphWeaver.register_scalar("Date", Date,
      cast: ->(v) { "Date.iso8601(#{v})" }, serialize: ->(v) { "#{v}.iso8601" })

    expect { check }.to raise_error(GraphWeaver::Error, /Date: serialize: is a Proc, which builds source/)
  end

  # one unpinned scalar must not hide the verdict on the others — and the
  # advice is the one door that is a door here: check_scalars! takes the
  # schema and nothing else, and runs outside every fake
  it "reports a scalar nothing can fabricate a value for, pinnable where it runs" do
    GraphWeaver.register_scalar("Date", Class.new { def self.name = "Wallet" }, cast: :parse)

    expect { check }.to raise_error(GraphWeaver::Error) { |error|
      expect(error.message).to include("Date: can't fabricate a Date", "it deserializes into Wallet",
        "Pin the form this server sends: GraphWeaver::Testing.config.overrides = { \"Date\" => ... }.")
      expect(error.message).not_to include("graphql_fake", "FakeClient.new")
    }
  end

  # the same one door, from the other branch that says to pin
  it "names it the same way when cast: can't read the fabricated value" do
    GraphWeaver.register_scalar("Metadata", Integer, cast: :Integer)

    expect { check }.to raise_error(GraphWeaver::Error) { |error|
      expect(error.message).to include("Metadata: cast: can't read",
        "Pin the form this server sends: GraphWeaver::Testing.config.overrides = { \"Metadata\" => ... }.")
    }
  end

  # `sent <x>, got back <x>` read as a library bug; the class just inherits
  # Object#==, and the check has to say so rather than claim a loss
  it "says a class with no == can't be round-trip checked, rather than calling it lossy" do
    wallet = Class.new do
      def self.parse(wire) = new(wire)
      def initialize(amount) = @amount = amount
      def to_s = @amount.to_s
      def inspect = "#<Wallet #{@amount}>"
    end
    # the cast is evaluated at the top level, where the generated file's
    # constants resolve from, so the class has to be reachable by name
    stub_const("Wallet", wallet)
    GraphWeaver.register_scalar("Metadata", wallet, cast: :parse, serialize: :to_s)
    GraphWeaver::Testing.configure { |config| config.overrides = { "Metadata" => "12.50" } }

    expect { check }.to raise_error(GraphWeaver::Error) { |error|
      expect(error.message).to match(/Metadata: \S+ defines no ==, so a round trip can't be checked/)
      expect(error.message).to include("and nothing here can tell those apart")
      expect(error.message).not_to include("round-trips lossily")
    }
  ensure
    GraphWeaver::Testing.reset!
  end

  # A wire-class registration casts through the library's own rule for that
  # class, and Metadata's coercers do nothing at all — so the whole loop is
  # that rule against itself.
  it "agrees about a scalar registered as a wire class, against a pass-through server" do
    [Integer, Float, String, "T::Boolean"].each do |type|
      GraphWeaver.register_scalar("Metadata", type)

      expect { check }.not_to(raise_error, "expected agreement for #{type}")
    end
  end

  it "says nothing about a scalar the app never registered, or the library's own entries" do
    # Metadata is declared and unregistered; Date holds the pre-registered entry
    expect { check }.not_to raise_error
  end
end
