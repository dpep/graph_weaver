# typed: false
require "bigdecimal"
require "graphql"

# A rich Ruby value object we want GraphQL `Money` fields cast into, backed
# by BigDecimal, plus a tiny in-process schema exposing a `Money` custom
# scalar. Kept in its own namespace and separate from Demo::Schema so
# registering scalars here can never perturb the rest of the suite.
module MoneyDemo
  class Money
    attr_reader :amount # BigDecimal

    # wire ("$1,999.00") -> Money
    def self.parse(str)
      new(BigDecimal(str.to_s.delete("$,")))
    end

    def initialize(amount)
      @amount = amount
    end

    # Money -> wire, always two decimal places ("1999.00")
    def to_s
      format("%.2f", @amount)
    end

    def ==(other)
      other.is_a?(Money) && other.amount == @amount
    end
  end

  # A codec that fails the way real ones do — JSON::ParserError,
  # URI::InvalidURIError, Money::ParseError — not TypeError/ArgumentError.
  module Strict
    def self.parse(_str) = raise(JSON::ParserError, "not money")
  end

  Product = Struct.new(:name, :price, keyword_init: true)

  class MoneyType < GraphQL::Schema::Scalar
    graphql_name "Money"

    def self.coerce_result(value, _ctx)
      value.to_s
    end

    def self.coerce_input(value, _ctx)
      Money.parse(value)
    end
  end

  class ProductType < GraphQL::Schema::Object
    graphql_name "Product"

    field :name, String, null: false
    field :price, MoneyType, null: false
  end

  class QueryType < GraphQL::Schema::Object
    graphql_name "Query"

    field :product, ProductType, null: false do
      argument :name, String, required: true
      argument :budget, MoneyType, required: true
    end

    def product(name:, budget:)
      Product.new(name:, price: budget)
    end
  end

  class Schema < GraphQL::Schema
    query QueryType
  end
end

describe "custom scalar deserialization" do
  # register_scalar mutates a process-wide registry; restore the built-in
  # defaults after each example so these don't leak into the rest of the suite.
  after { GraphWeaver::Codegen.reset_scalars! }

  let(:query) do
    <<~GRAPHQL
      query Store($name: String!, $budget: Money!) {
        product(name: $name, budget: $budget) {
          name
          price
        }
      }
    GRAPHQL
  end

  def generate
    GraphWeaver::Codegen.generate(schema: MoneyDemo::Schema, query:, name: "StoreQuery")
  end

  it "infers cast (.parse) and serialize (#to_s) from a class type" do
    GraphWeaver.register_scalar("Money", MoneyDemo::Money)

    scalar = GraphWeaver::Codegen.scalar("Money")
    expect(scalar.type).to eq "MoneyDemo::Money"
    expect(scalar.cast("v")).to eq "MoneyDemo::Money.parse(v)"
    expect(scalar.serialize("v")).to eq "v.to_s"
  end

  it "infers a .load/.dump codec when the class defines .load" do
    blob = Class.new do
      def self.name = "Blob"
      def self.load(_str) = new
      def self.dump(_obj) = ""
    end
    GraphWeaver.register_scalar("Blob", blob)

    scalar = GraphWeaver::Codegen.scalar("Blob")
    expect(scalar.cast("v")).to eq "Blob.load(v)"
    expect(scalar.serialize("v")).to eq "Blob.dump(v)"
  end

  it "does not infer anything for plain types (no spurious #to_s serializer)" do
    GraphWeaver.register_scalar("Money", String) # String has no .parse/.load

    scalar = GraphWeaver::Codegen.scalar("Money")
    expect(scalar.cast?).to be false
    expect(scalar.serialize?).to be false
  end

  it "opts out of inference with :itself" do
    GraphWeaver.register_scalar("Money", MoneyDemo::Money, cast: :itself, serialize: :itself)

    scalar = GraphWeaver::Codegen.scalar("Money")
    expect(scalar.cast?).to be false
    expect(scalar.serialize?).to be false
  end

  it "generates a Money-typed prop and inlines the inferred cast in from_h" do
    GraphWeaver.register_scalar("Money", MoneyDemo::Money)

    source = generate

    expect(source).to include("const :price, MoneyDemo::Money")
    expect(source).to include('MoneyDemo::Money.parse(data.fetch("price"))')
    # inferred serialize emits the inverse for the Money variable
    expect(source).to include("}.to_s,")
  end

  it "emits requires: atop the generated source, before the module" do
    GraphWeaver.register_scalar("Money", MoneyDemo::Money, requires: "bigdecimal")

    source = generate

    expect(source).to include(%(require "bigdecimal"))
    expect(source.index(%(require "bigdecimal"))).to be < source.index("module StoreQuery")
  end

  it "loads requires: before probing for a codec (Time.parse lives in the time stdlib)" do
    # the probe method arrives with the require — a bare class gains
    # .parse only once its file loads, exactly like core Time and "time"
    Dir.mktmpdir do |dir|
      class LateProbe; end # rubocop:disable Lint/ConstantDefinitionInBlock
      ext = File.join(dir, "late_probe_ext.rb")
      File.write(ext, "class LateProbe; def self.parse(v) = new; def to_s = \"wire\"; end")

      GraphWeaver.register_scalar("Late", LateProbe, requires: ext)

      scalar = GraphWeaver::Codegen.scalar("Late")
      expect(scalar.cast?).to be true
      expect(scalar.cast("v")).to eq "LateProbe.parse(v)"
    ensure
      Object.send(:remove_const, :LateProbe) if Object.const_defined?(:LateProbe)
    end
  end

  it "round-trips a BigDecimal-backed object through serialize and cast" do
    GraphWeaver.register_scalar("Money", MoneyDemo::Money, requires: "bigdecimal")

    mod = GraphWeaver.parse(
      schema: MoneyDemo::Schema,
      client: MoneyDemo::Schema,
      query:,
    )

    product = mod.execute(name: "Widget", budget: MoneyDemo::Money.parse("2500.50")).data!.product

    expect(product.price).to be_a MoneyDemo::Money
    expect(product.price.amount).to eq BigDecimal("2500.50")
  end

  it "accepts an explicit Proc cast and serialize, overriding inference" do
    GraphWeaver.register_scalar("Money", "MoneyDemo::Money",
      cast: ->(expr) { "MoneyDemo::Money.new(#{expr})" },
      serialize: ->(expr) { "#{expr}.amount.to_s" })

    scalar = GraphWeaver::Codegen.scalar("Money")
    expect(scalar.cast("x")).to eq "MoneyDemo::Money.new(x)"
    expect(scalar.serialize("x")).to eq "x.amount.to_s"
  end

  it "lets a later registration override an earlier one, including built-ins" do
    GraphWeaver.register_scalar("Date", "MyDate", cast: :load)

    scalar = GraphWeaver::Codegen.scalar("Date")
    expect(scalar.type).to eq "MyDate"
    expect(scalar.cast("s")).to eq "MyDate.load(s)"
  end

  it "clears and resets the registry" do
    GraphWeaver::Codegen.clear_scalars!
    expect(GraphWeaver::Codegen.scalar("Date").cast?).to be false # built-in gone

    GraphWeaver::Codegen.reset_scalars!
    expect(GraphWeaver::Codegen.scalar("Date").cast("s")).to eq "Date.iso8601(s)"
  end

  it "leaves unregistered custom scalars as untyped pass-through" do
    source = generate

    expect(source).to include("const :price, T.untyped")
    expect(source).to include('price: data.fetch("price")')
    # no cast: the raw wire value passes straight through
    expect(source).not_to include("Money.parse")
  end

  it "rejects malformed registrations" do
    expect { GraphWeaver.register_scalar("X", 42) }
      .to raise_error(ArgumentError, /type:/)
    expect { GraphWeaver.register_scalar("X", "X", cast: "nope") }
      .to raise_error(ArgumentError, /cast:/)
    expect { GraphWeaver.register_scalar("X", "X", serialize: 99) }
      .to raise_error(ArgumentError, /serialize:/)
  end

  it "validates requires: is a String or Array of Strings" do
    expect { GraphWeaver.register_scalar("X", "X", requires: 42) }
      .to raise_error(ArgumentError, /requires:/)
    expect { GraphWeaver.register_scalar("X", "X", requires: ["ok", ""]) }
      .to raise_error(ArgumentError, /requires:/)
    expect { GraphWeaver.register_scalar("X", "X", requires: ["bigdecimal"]) }
      .not_to raise_error
  end

  it "actually requires the path when a real class is given, catching typos" do
    # a real class means the runtime is loaded, so a bogus require is caught now
    expect { GraphWeaver.register_scalar("Money", MoneyDemo::Money, requires: "no_such_lib_zzz") }
      .to raise_error(ArgumentError, /not loadable/)

    # a valid one loads (or no-ops if already loaded) without complaint
    expect { GraphWeaver.register_scalar("Money", MoneyDemo::Money, requires: "bigdecimal") }
      .not_to raise_error
  end

  it "does not attempt the require for a type-name string (dep may be codegen-absent)" do
    expect { GraphWeaver.register_scalar("Money", "MoneyDemo::Money", requires: "no_such_lib_zzz") }
      .not_to raise_error
  end

  # cast: is the how in both directions: what builds a Money out of the wire
  # also builds one out of a Rails param. Nothing to opt into, and the kwarg
  # stays typed Money.
  describe "loose variable input" do
    it "keeps the kwarg narrow and normalizes in the body" do
      GraphWeaver.register_scalar("Money", MoneyDemo::Money)

      source = generate

      expect(source).to include("budget: MoneyDemo::Money")
      expect(source).to include(
        '(v.is_a?(MoneyDemo::Money) ? v : MoneyDemo::Money.parse(v))',
      )
    end

    it "coerces a raw string input end to end, and passes a value through" do
      GraphWeaver.register_scalar("Money", MoneyDemo::Money, requires: "bigdecimal")

      mod = GraphWeaver.parse(
        schema: MoneyDemo::Schema,
        client: MoneyDemo::Schema,
        query:,
      )

      from_string = mod.execute(name: "Widget", budget: "12.00").data!.product
      from_value = mod.execute(name: "Widget", budget: MoneyDemo::Money.parse("12.00")).data!.product

      expect(from_string.price.amount).to eq BigDecimal("12.00")
      expect(from_value.price.amount).to eq BigDecimal("12.00")
    end

    it "names the variable when the cast refuses" do
      GraphWeaver.register_scalar("Money", MoneyDemo::Money, requires: "bigdecimal")

      mod = GraphWeaver.parse(schema: MoneyDemo::Schema, client: MoneyDemo::Schema, query:)

      expect { mod.execute(name: "Widget", budget: Object.new) }
        .to raise_error(GraphWeaver::InputError, /\$budget of Store/)
    end

    # the sig no longer checks at runtime, so a pass-through scalar still
    # has its Ruby type held to
    it "checks a pass-through scalar's Ruby type" do
      GraphWeaver.register_scalar("Money", String) # String has no .parse/.load

      expect(generate).to include("GraphWeaver::Coerce.string(v)")
    end
  end

  # the built-in Date scalar carries its own require, so any query using it
  # generates a self-contained file
  it "emits require \"date\" for the built-in Date scalar" do
    source = GraphWeaver::Codegen.generate(
      schema: Demo::Schema,
      query: File.read(File.expand_path("queries/person.graphql", __dir__)),
      name: "PersonQuery",
    )

    expect(source).to include(%(require "date"))
    expect(source.index(%(require "date"))).to be < source.index("module PersonQuery")
  end

  it "brands a cast that raises outside TypeError/ArgumentError/KeyError" do
    GraphWeaver.register_scalar("Money", MoneyDemo::Strict)
    mod = Module.new
    mod.module_eval(generate)

    expect { mod.const_get(:StoreQuery).from_response!("data" => { "product" => { "name" => "W", "price" => "12" } }) }
      .to raise_error(GraphWeaver::TypeError, /not money/)
  end

  # A stdlib type should take one argument beyond the name, because the
  # careful registration is the one people get wrong: `serialize: :to_s` on a
  # BigDecimal puts "0.125e2" on the wire.
  describe "a stdlib type" do
    it "infers the codec and the require from the class alone" do
      GraphWeaver.register_scalar("Decimal", BigDecimal)

      scalar = GraphWeaver::Codegen.scalar("Decimal")
      expect(scalar.cast("v")).to eq "BigDecimal(v)"
      expect(scalar.serialize("v")).to eq %(v.to_s("F"))
      expect(scalar.requires).to eq ["bigdecimal"]
    end

    it "writes a decimal in plain notation, not scientific" do
      GraphWeaver.register_scalar("Decimal", BigDecimal)

      expect(GraphWeaver::Codegen.scalar("Decimal").serialize_value(BigDecimal("12.5"))).to eq "12.5"
    end

    it "reads a decimal both directions through a generated module" do
      GraphWeaver.register_scalar("Money", BigDecimal)
      mod = GraphWeaver.parse(schema: MoneyDemo::Schema, client: MoneyDemo::Schema, query:)

      # the schema's own Money.parse reads what we serialized, and its
      # two-decimal result casts back into a BigDecimal
      expect(mod.execute(name: "W", budget: BigDecimal("12.5")).data!.product.price).to eq BigDecimal("12.5")
      expect(mod.execute(name: "W", budget: "12.5").data!.product.price).to eq BigDecimal("12.5")
      expect { mod.execute(name: "W", budget: "abc") }
        .to raise_error(GraphWeaver::InputError, /\$budget of Store.*"abc"/)
    end

    it "sends a decimal variable as a plain decimal string" do
      GraphWeaver.register_scalar("Money", BigDecimal)
      capture = Class.new do
        attr_reader :variables

        def execute(_query, variables:, operation_name: nil)
          @variables = variables
          { "data" => nil, "errors" => [{ "message" => "captured" }] }
        end
      end.new

      GraphWeaver.parse(schema: MoneyDemo::Schema, client: capture, query:)
        .execute(name: "W", budget: BigDecimal("12.5"))

      expect(capture.variables["budget"]).to eq "12.5"
    end

    it "lets an explicit serialize: win over what the library knows" do
      GraphWeaver.register_scalar("Decimal", BigDecimal, serialize: :to_i, requires: "bigdecimal")

      expect(GraphWeaver::Codegen.scalar("Decimal").serialize("v")).to eq "v.to_i"
    end

    it "leaves a wire class alone, Kernel conversion or not" do
      GraphWeaver.register_scalar("Cents", Integer) # not Integer(v) — see Coerce

      expect(GraphWeaver::Codegen.scalar("Cents").cast?).to be false
      expect(GraphWeaver::Codegen.scalar("Cents").coerce_input("v")).to eq "GraphWeaver::Coerce.integer(v)"
    end

    it "rejects a malformed serialize: Array" do
      expect { GraphWeaver.register_scalar("X", "X", serialize: ["to_s"]) }
        .to raise_error(ArgumentError, /serialize:/)
    end
  end

  # Names that are conventions rather than guesses: graphql-ruby ships all
  # but DateTime as its own scalars, and DateTime is what GitHub, Shopify and
  # most hand-written schemas call an ISO 8601 timestamp.
  describe "conventional scalar names" do
    let(:schema) do
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        scalar ISO8601Date
        scalar ISO8601DateTime
        scalar DateTime
        scalar BigInt
        scalar JSON
        type Query { event: Event! }
        type Event { on: ISO8601Date at: ISO8601DateTime seen: DateTime count: BigInt meta: JSON }
      GRAPHQL
    end

    let(:event_query) { "query Event { event { on at seen count meta } }" }

    def event(wire)
      mod = Module.new
      mod.module_eval(GraphWeaver::Codegen.generate(schema:, query: event_query, name: "EventQuery"))
      mod.const_get(:EventQuery).from_response!("data" => { "event" => wire }).event
    end

    it "casts each one off a real wire value with no registration" do
      values = event(
        "on" => "2024-01-15", "at" => "2024-01-15T10:00:00Z", "seen" => "2024-01-15T10:00:00Z",
        "count" => "9007199254740993", "meta" => { "a" => 1 },
      )

      expect(values.on).to eq Date.new(2024, 1, 15)
      expect(values.at).to eq Time.utc(2024, 1, 15, 10)
      expect(values.seen).to eq Time.utc(2024, 1, 15, 10)
      expect(values.count).to eq 9_007_199_254_740_993
      expect(values.meta).to eq({ "a" => 1 })
    end

    it "keeps a date a Date, so nothing invents a midnight" do
      expect(GraphWeaver::Codegen.scalar("ISO8601Date").type).to eq "Date"
      expect(GraphWeaver::Codegen.scalar("ISO8601DateTime").type).to eq "Time"
    end

    it "is overridden by a registration, like any other entry" do
      GraphWeaver.register_scalar("DateTime", Date)

      expect(GraphWeaver::Codegen.scalar("DateTime").cast("v")).to eq "Date.iso8601(v)"
    end

    it "says nothing about a schema that has none of them" do
      io = StringIO.new
      GraphWeaver.logger = Logger.new(io, level: Logger::WARN)

      GraphWeaver.new(Demo::Schema).parse("query { person(id: 1) { birthday } }")

      expect(io.string).to be_empty
    ensure
      GraphWeaver.logger = nil
    end
  end

  # Two tables in docs/scalars.md are the whole answer to "what do I have to
  # register" — so they are read off the registry rather than kept beside it.
  describe "docs/scalars.md" do
    let(:docs) { File.read(File.expand_path("../docs/scalars.md", __dir__)) }

    def rows(section)
      table = docs[/^## #{section}\n(.*?)\n## /m, 1]
      table.scan(/^\|(?!-).*\|$/)
        .map { |row| row.split("|").map { |cell| cell.strip.delete("`") }.reject(&:empty?) }
        .reject { |row| %w[scalar\ name Ruby\ type scalar].include?(row.first) }
    end

    it "names every scalar that needs no registration" do
      documented = docs[/^## Already registered\n(.*?)\n## /m, 1]
        .scan(/^\| ([^|]+) \|/).flatten.flat_map { |cell| cell.scan(/`([^`]+)`/).flatten }

      expect(documented).to match_array GraphWeaver::Codegen::BUILTIN_SCALARS
    end

    it "shows the codec each stdlib type actually infers" do
      table = rows("Registering a stdlib type")
      expect(table.map(&:first)).to include("BigDecimal", "Date", "Time")

      table.each do |type, cast, serialize, requires|
        GraphWeaver.register_scalar("Probe", Object.const_get(type))
        scalar = GraphWeaver::Codegen.scalar("Probe")

        expect([scalar.cast("v"), scalar.serialize("v"), scalar.requires])
          .to eq [cast, serialize, [requires]]
      end
    end
  end

  it "rejects an anonymous class as a scalar type (would emit a literal nil)" do
    expect { GraphWeaver.register_scalar("Anon", Class.new) }
      .to raise_error(ArgumentError, /anonymous/)
  end
end

# The money gem's Money, without the dependency: from_amount(decimal,
# currency) builds one and #to_s writes a plain decimal string. Top-level and
# real rather than stub_const'd, because docs/scalars.md registers it under
# this name and the generated cast resolves the constant it is given.
class Money
  def self.from_amount(decimal, currency) = new(decimal, currency)

  attr_reader :amount, :currency

  def initialize(amount, currency)
    @amount = amount
    @currency = currency
  end

  def to_s = format("%.2f", @amount)

  def ==(other)
    other.is_a?(Money) && other.amount == @amount && other.currency == @currency
  end
end

# The registration docs/scalars.md shows for it: two facts only the app can
# supply — which wire spelling this server's Money scalar uses, and the
# currency from_amount needs.
describe "a class whose codec can't be inferred" do
  after { GraphWeaver::Codegen.reset_scalars! }

  # exactly the registration docs/scalars.md shows
  def register
    GraphWeaver.register_scalar("Money", Money,
      cast: ->(v) { "Money.from_amount(BigDecimal(#{v}), \"USD\")" },
      serialize: :to_s)
  end

  let(:query) do
    <<~GRAPHQL
      query Store($name: String!, $budget: Money!) {
        product(name: $name, budget: $budget) {
          name
          price
        }
      }
    GRAPHQL
  end

  def source
    GraphWeaver::Codegen.generate(schema: MoneyDemo::Schema, query:, name: "StoreQuery")
  end

  it "infers nothing from the class — no .parse, no .load, no Kernel#Money" do
    GraphWeaver.register_scalar("Money", Money)

    scalar = GraphWeaver::Codegen.scalar("Money")
    expect(scalar.cast?).to be false
    expect(scalar.serialize?).to be false
  end

  it "inlines the source the cast: proc builds, and #to_s as the serializer" do
    register

    scalar = GraphWeaver::Codegen.scalar("Money")
    expect(scalar.cast("v")).to eq %(Money.from_amount(BigDecimal(v), "USD"))
    expect(scalar.serialize("v")).to eq "v.to_s"
    expect(source).to include(%(Money.from_amount(BigDecimal(data.fetch("price")), "USD")))
  end

  it "casts a decimal string off the wire into a Money" do
    register
    mod = Module.new
    mod.module_eval(source)

    product = mod.const_get(:StoreQuery)
      .from_response!("data" => { "product" => { "name" => "Widget", "price" => "12.50" } })
      .product

    expect(product.price).to eq Money.from_amount(BigDecimal("12.50"), "USD")
  end

  it "writes a Money variable back as the same decimal string" do
    register
    capture = Class.new do
      attr_reader :variables

      def execute(_query, variables:, operation_name: nil)
        @variables = variables
        { "data" => nil, "errors" => [{ "message" => "captured" }] }
      end
    end.new

    GraphWeaver.parse(schema: MoneyDemo::Schema, client: capture, query:)
      .execute(name: "Widget", budget: Money.from_amount(BigDecimal("12.50"), "USD"))

    expect(capture.variables["budget"]).to eq "12.50"
  end
end
