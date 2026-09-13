# typed: false
require "bigdecimal"
require "delegate"
require "graphql"

# What ActiveSupport::TimeWithZone is — the everyday value `Time.zone.now`
# hands you: not a Time, acts_like? one, converts to one losslessly. (The
# real class also answers is_a?(Time); nothing here leans on that.)
class TimeWithZoneAlike < SimpleDelegator
  def acts_like?(sym) = sym == :time
  def to_time = __getobj__
end

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
    # a result compares its props with eql?, so a leaf that stops at == makes
    # two results parsed from the same bytes unequal
    alias_method :eql?, :==
    def hash = [Money, @amount].hash
  end

  # A codec that fails the way real ones do — JSON::ParserError,
  # URI::InvalidURIError, Money::ParseError — not TypeError/ArgumentError.
  module Strict
    def self.parse(_str) = raise(JSON::ParserError, "not money")
  end

  Product = Struct.new(:name, :price, keyword_init: true)

  # a T::Enum's values are singletons, so it inherits eql?/hash and is right to
  class Currency < T::Enum
    enums { USD = new("USD") }
  end

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

  # A result compares its props with eql?, so it and #hash agree on "same".
  # The rule is eql? alone: a type that leaves it at Object's compares by
  # identity, so two results parsed from the SAME bytes are unequal — which no
  # caller would guess from the leaf comparing fine. Both drafts below get
  # there, the == one being the most common Ruby idiom there is.
  def warnings_for(type)
    io = StringIO.new
    GraphWeaver.logger = Logger.new(io, level: Logger::WARN)
    GraphWeaver.register_scalar("Money", type)
    io.string
  ensure
    GraphWeaver.logger = nil
  end

  it "warns when a registered type defines == but not eql?" do
    half_a_value_object = Class.new do
      def self.name = "HalfValue"
      def self.parse(str) = new
      def ==(other) = other.is_a?(self.class)
    end

    expect(warnings_for(half_a_value_object))
      .to include("HalfValue inherits #eql? and #hash, so its instances compare by identity")
  end

  it "warns about a type with no equality at all, the commoner first draft" do
    no_value_object = Class.new do
      def self.name = "NoValue"
      def self.parse(str) = new
    end

    expect(warnings_for(no_value_object))
      .to include("NoValue inherits #eql? and #hash, so its instances compare by identity")
  end

  it "says nothing about a type whose eql? agrees with its ==" do
    expect(warnings_for(MoneyDemo::Money)).to be_empty
  end

  # Every type the docs tell you to reach for, plus the Comparable idiom's one
  # honest true positive: Comparable supplies == off <=> and leaves eql?/hash
  # at Object's, so it IS the bug this warns about.
  it "says nothing about the stdlib types a registration names" do
    [String, Integer, Float, Date, Time, DateTime, BigDecimal].each do |type|
      expect(warnings_for(type)).to(be_empty, "expected no warning for #{type}")
    end
  end

  it "says nothing about a T::Enum, whose values are singletons" do
    expect(warnings_for(MoneyDemo::Currency)).to be_empty
  end

  it "warns about a Comparable that stops at <=>" do
    comparable = Class.new do
      include Comparable
      def self.name = "Ranked"
      def self.parse(str) = new
      def <=>(other) = 0
    end

    expect(warnings_for(comparable)).to include("Ranked inherits #eql? and #hash")
  end

  it "compares two results holding the same registered scalar as equal" do
    GraphWeaver.register_scalar("Money", MoneyDemo::Money)
    mod = GraphWeaver.parse(schema: MoneyDemo::Schema, query:, name: "StoreQuery")
    wire = { "data" => { "product" => { "name" => "Widget", "price" => "12.50" } } }

    expect(mod.from_response!(wire)).to eq mod.from_response!(wire)
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
    # inferred serialize emits the inverse for the Money variable — inside
    # Coerce.variable, so a refusal from it names the variable too
    expect(source).to include("OPERATION_NAME, budget) { |v| GraphWeaver::Coerce.cast(MoneyDemo::Money, v, " \
      "\"Money\") { |raw| MoneyDemo::Money.parse(raw) }.to_s }")
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
        %(GraphWeaver::Coerce.cast(MoneyDemo::Money, v, "Money") { |raw| MoneyDemo::Money.parse(raw) }),
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

      expect(generate).to include(%(GraphWeaver::Coerce.string(v, "Money")))
    end

    # #details is what an app translates for a user, so a refusal speaks the
    # schema's vocabulary — "Money", never the BigDecimal it happens to map to
    it "refuses in the schema's vocabulary, not the Ruby type's" do
      GraphWeaver.register_scalar("Money", BigDecimal)
      mod = GraphWeaver.parse(schema: MoneyDemo::Schema, client: MoneyDemo::Schema, query:)

      error = begin
        mod.execute(name: "Widget", budget: "abc")
      rescue GraphWeaver::InputError => e
        e
      end

      expect(error.details[:type]).to eq "Money"
      expect(error.message).to include "invalid value for BigDecimal()"
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
      .to raise_error(GraphWeaver::CastError, /not money/)
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
      expect(GraphWeaver::Codegen.scalar("Cents").coerce_input("v")).to eq %(GraphWeaver::Coerce.integer(v, "Cents"))
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
        type Query { event: Event! echo(d: ISO8601Date, t: ISO8601DateTime): String }
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

    # A date stays a Date and a timestamp a Time, at the door as well as off
    # the wire: converting one into the other drops the time of day or
    # invents a midnight, and doing that quietly is how a query silently
    # widens the window it filters on.
    describe "a date and a timestamp are not each other" do
      let(:spy) do
        Class.new do
          attr_reader :variables
          def execute(_query, variables:, operation_name: nil)
            @variables = variables
            { "data" => { "echo" => "ok" } }
          end
        end.new
      end
      let(:on) { GraphWeaver.parse(schema:, client: spy, query: "query On($d: ISO8601Date) { echo(d: $d) }") }
      let(:at) { GraphWeaver.parse(schema:, client: spy, query: "query At($t: ISO8601DateTime) { echo(t: $t) }") }
      let(:noon) { Time.utc(2024, 1, 15, 12, 30, 45) }

      it "refuses a timestamp for a Date variable, whatever class it arrives in" do
        expect { on.execute(d: noon) }.to raise_error(
          GraphWeaver::InputError, /\$d of On: expected an ISO8601Date, got a Time — pass \.to_date/
        )
        expect { on.execute(d: DateTime.new(2024, 1, 15, 12, 30, 45)) }
          .to raise_error(GraphWeaver::InputError, /expected an ISO8601Date, got a DateTime/)
        expect { on.execute(d: TimeWithZoneAlike.new(noon)) }
          .to raise_error(GraphWeaver::InputError, /expected an ISO8601Date, got a TimeWithZoneAlike/)
      end

      it "refuses a Date for a timestamp variable rather than inventing a midnight" do
        expect { at.execute(t: Date.new(2024, 1, 15)) }.to raise_error(
          GraphWeaver::InputError, /\$t of At: expected an ISO8601DateTime, got a Date — a Date has no time of day/
        )
      end

      it "takes what converts without inventing or dropping anything" do
        at.execute(t: TimeWithZoneAlike.new(noon))
        expect(spy.variables).to eq("t" => "2024-01-15T12:30:45Z")

        at.execute(t: DateTime.new(2024, 1, 15, 12, 30, 45))
        expect(spy.variables).to eq("t" => "2024-01-15T12:30:45+00:00")
      end

      # graphql-ruby's own ISO8601DateTime writes whole seconds, but a JS or
      # Apollo server writes milliseconds on every timestamp — and a value
      # read from one used to go back out a fraction poorer, which is how an
      # `updatedAt` token stops matching or a `since:` window quietly widens
      it "keeps the sub-second part of a timestamp on the way out" do
        at.execute(t: Time.utc(2024, 1, 15, 12, 30, 45, 500_000))
        expect(spy.variables).to eq("t" => "2024-01-15T12:30:45.500000Z")

        # and a whole second still sends exactly what it always sent
        at.execute(t: noon)
        expect(spy.variables).to eq("t" => "2024-01-15T12:30:45Z")
      end

      it "still takes the type the schema asked for, and the string form" do
        on.execute(d: Date.new(2024, 1, 15))
        expect(spy.variables).to eq("d" => "2024-01-15")
        on.execute(d: "2024-01-15")
        expect(spy.variables).to eq("d" => "2024-01-15")

        at.execute(t: noon)
        expect(spy.variables).to eq("t" => "2024-01-15T12:30:45Z")
        at.execute(t: "2024-01-15T12:30:45Z")
        expect(spy.variables).to eq("t" => "2024-01-15T12:30:45Z")
      end
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

        # an em dash is the table's "nothing here"
        serialize, requires = [serialize, requires].map { |cell| cell unless cell == "—" }

        expect([scalar.cast("v"), scalar.serialize("v"), scalar.requires])
          .to eq [cast, serialize, Array(requires)]
      end
    end
  end

  it "rejects an anonymous class as a scalar type (would emit a literal nil)" do
    expect { GraphWeaver.register_scalar("Anon", Class.new) }
      .to raise_error(ArgumentError, /anonymous/)
  end
end

# A `cast:` replaces how the Ruby object is BUILT. It does not replace the
# library's rules about which values are the right ones — an app's cast
# complains about the value alone ("no implicit conversion of Integer into
# String"), and the stdlib's own class graph files a DateTime under Date.
describe "a registration that names its own cast:" do
  after { GraphWeaver::Codegen.reset_scalars! }

  # the built-in Date, respelled by an app that prefers #iso8601 on the way out
  def register
    GraphWeaver.register_scalar("Date", Date, cast: :iso8601, serialize: :iso8601)
  end

  let(:capture) do
    Class.new do
      attr_reader :variables

      def execute(_query, variables:, operation_name: nil)
        @variables = variables
        { "data" => nil, "errors" => [{ "message" => "captured" }] }
      end
    end.new
  end

  let(:mutation) { "mutation Probe($input: AdoptionInput!) { adopt(input: $input) { name } }" }

  # the input-field layer: the cast runs inside a generated input struct
  def adopting(birthday, client: Demo::Schema)
    GraphWeaver.parse(schema: Demo::Schema, client:, query: mutation)
      .execute(input: { name: "Rex", species: "DOG", birthday: })
  end

  def refusal
    yield
    raise "expected a GraphWeaver::InputError"
  rescue GraphWeaver::InputError => e
    e
  end

  # the variable layer: the same cast, one rescue higher up
  def on(day)
    schema = GraphQL::Schema.from_definition(
      "scalar Date\ntype Query { on(day: Date!): String }\nschema { query: Query }",
    )
    GraphWeaver.parse(schema:, client: capture, query: "query Day($day: Date!) { on(day: $day) }")
      .execute(day:)
  end

  # The gem can't know what an app's cast accepts, so no guard belongs in the
  # codec — but TypeError is Ruby's own word for "wrong class", and that is
  # the same refusal the built-in Date gives for the same mistake.
  it "says what was expected when the cast refuses the value's class" do
    register

    expect { adopting(5) }
      .to raise_error(GraphWeaver::InputError, "$input of Probe: birthday: expected a Date, got 5")
    expect { on(5) }.to raise_error(GraphWeaver::InputError, "$day of Day: expected a Date, got 5")
  end

  # ArgumentError is Ruby's word for "wrong content", and the parser's own
  # sentence is the better one — it says which part of the date was wrong
  it "keeps the cast's own words when only the content was wrong" do
    register

    expect { adopting("nope") }
      .to raise_error(GraphWeaver::InputError, "$input of Probe: birthday: invalid date")
    # the variable layer quotes the value a parser never does, as it does for
    # the built-in Date
    expect { on("nope") }.to raise_error(GraphWeaver::InputError, '$day of Day: invalid date (got "nope")')
  end

  # DateTime < Date, so is_a? passed one straight through the guard and the
  # app's serializer wrote "2024-01-15T10:20:30+00:00" where a date belongs
  it "refuses a DateTime for a Date, in the built-in Date's own words" do
    noon = DateTime.new(2024, 1, 15, 10, 20, 30)
    builtin = refusal { on(noon) }
    register

    expect { adopting(noon) }.to raise_error(
      GraphWeaver::InputError,
      "$input of Probe: birthday: expected a Date, got a DateTime — " \
        "pass .to_date if dropping the time of day is what you meant",
    )
    # the variable layer quotes the value a cross-type refusal names only by
    # class, and does it the same way for both
    expect(refusal { on(noon) }.message).to eq builtin.message
  end

  it "passes a Date through untouched, and writes a date on the wire" do
    register

    adopting(Date.new(2024, 1, 15), client: capture)

    expect(capture.variables["input"]["birthday"]).to eq "2024-01-15"
  end

  it "still casts the wire spelling the registration named" do
    register

    adopting("2024-01-15", client: capture)

    expect(capture.variables["input"]["birthday"]).to eq "2024-01-15"
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

  # Two different mistakes reach the same dead end, so the refusal has to say
  # which one you made: a class the probes missed, or a name that was never
  # probed at all.
  it "refuses at generation, naming the three probes that found nothing" do
    GraphWeaver.register_scalar("Money", Money)

    expect { source }.to raise_error(GraphWeaver::Error, <<~MSG.chomp.tr("\n", " "))
      register_scalar("Money", Money) has no cast, so nothing builds a Money out of the JSON at
      Product.price — Money defines no .parse and no .load, and Kernel has no Money conversion
      function, so there was nothing to infer. Give it a cast (cast: :parse names a class method,
      cast: ->(v) { "Money.new(\#{v})" } emits any expression), or register a type the wire already
      parses into
    MSG
  end

  # The string form skips probing by design — there is no class in hand — so
  # the same class that would have inferred nothing is a different diagnosis.
  it "refuses a name-registered type by saying nothing was probed" do
    GraphWeaver.register_scalar("Money", "Money")

    expect { source }.to raise_error(GraphWeaver::Error, <<~MSG.chomp.tr("\n", " "))
      register_scalar("Money", "Money") has no cast, so nothing builds a Money out of the JSON at
      Product.price — a type: given by name is never probed, since there is no class in hand. Pass
      the class (register_scalar("Money", Money)) to infer a cast from it, or name one yourself
      (cast: :parse names a class method, cast: ->(v) { "Money.parse(\#{v})" } emits any expression)
    MSG
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

  # the serializer used to run outside Coerce.variable's rescue, so whatever it
  # raised arrived bare, naming neither the variable nor the operation
  it "names the variable and the operation when the serializer raises" do
    # a badly-written codec: the cast answers nil for what it doesn't
    # recognise, and the serializer can't take one
    GraphWeaver.register_scalar("Money", String,
      cast: ->(v) { "(#{v}.is_a?(String) ? #{v} : nil)" },
      serialize: ->(v) { "#{v}.upcase" })

    expect {
      GraphWeaver.parse(schema: MoneyDemo::Schema, client: Demo::Schema, query:)
        .execute(name: "Widget", budget: 5)
    }.to raise_error(GraphWeaver::InputError,
      # Ruby 3.4 spells the NoMethodError with a straight quote and no class
      /\A\$budget of Store: undefined method [`']upcase' for nil(:NilClass)? \(got 5\)\z/)
  end
end

# A JSON scalar can legally be any JSON value, so the registry can only say
# T.untyped — but a field whose shape the app knows narrows per coordinate,
# which is what docs/scalars.md shows under "Overriding one field".
describe "narrowing a JSON field with a type string" do
  after { GraphWeaver::Codegen.reset_scalars! }

  let(:schema) do
    GraphQL::Schema.from_definition(<<~GRAPHQL)
      scalar JSON
      type Query { settings: Settings! }
      type Settings { meta: JSON }
    GRAPHQL
  end

  let(:query) { "query Settings { settings { meta } }" }

  def source
    GraphWeaver::Codegen.generate(schema:, query:, name: "SettingsQuery")
  end

  def meta(wire)
    mod = Module.new
    mod.module_eval(source)
    mod.const_get(:SettingsQuery).from_response!("data" => { "settings" => { "meta" => wire } }).settings.meta
  end

  # exactly the registration docs/scalars.md shows
  def narrow
    GraphWeaver.register_scalar("Settings.meta", "T::Hash[String, T.untyped]")
  end

  it "stays untyped without a registration — the scalar really is any JSON value" do
    expect(source).to include("const :meta, T.untyped")
  end

  it "types the prop with the string it is given" do
    narrow

    expect(source).to include("const :meta, T.nilable(T::Hash[String, T.untyped])")
  end

  it "passes a Hash through" do
    narrow

    expect(meta("theme" => "dark")).to eq({ "theme" => "dark" })
  end

  it "refuses a value that isn't one, naming the struct" do
    narrow

    expect { meta(["dark"]) }.to raise_error(GraphWeaver::CastError, /SettingsQuery::Result::Settings/)
  end
end
