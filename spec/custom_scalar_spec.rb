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
  after { GraphWeaver.reset_scalars! }

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
    GraphWeaver::Codegen.generate(schema: MoneyDemo::Schema, query:, module_name: "StoreQuery")
  end

  it "infers cast (.parse) and serialize (#to_s) from a class type" do
    GraphWeaver.register_scalar("Money", type: MoneyDemo::Money)

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
    GraphWeaver.register_scalar("Blob", type: blob)

    scalar = GraphWeaver::Codegen.scalar("Blob")
    expect(scalar.cast("v")).to eq "Blob.load(v)"
    expect(scalar.serialize("v")).to eq "Blob.dump(v)"
  end

  it "does not infer anything for plain types (no spurious #to_s serializer)" do
    GraphWeaver.register_scalar("Money", type: String) # String has no .parse/.load

    scalar = GraphWeaver::Codegen.scalar("Money")
    expect(scalar.cast?).to be false
    expect(scalar.serialize?).to be false
  end

  it "opts out of inference with :itself" do
    GraphWeaver.register_scalar("Money", type: MoneyDemo::Money, cast: :itself, serialize: :itself)

    scalar = GraphWeaver::Codegen.scalar("Money")
    expect(scalar.cast?).to be false
    expect(scalar.serialize?).to be false
  end

  it "generates a Money-typed prop and inlines the inferred cast in from_h" do
    GraphWeaver.register_scalar("Money", type: MoneyDemo::Money)

    source = generate

    expect(source).to include("const :price, MoneyDemo::Money")
    expect(source).to include('price: MoneyDemo::Money.parse(data.fetch("price"))')
    # inferred serialize emits the inverse for the Money variable
    expect(source).to include('"budget" => budget.to_s')
  end

  it "emits requires: atop the generated source, before the module" do
    GraphWeaver.register_scalar("Money", type: MoneyDemo::Money, requires: "bigdecimal")

    source = generate

    expect(source).to include(%(require "bigdecimal"))
    expect(source.index(%(require "bigdecimal"))).to be < source.index("module StoreQuery")
  end

  it "round-trips a BigDecimal-backed object through serialize and cast" do
    GraphWeaver.register_scalar("Money", type: MoneyDemo::Money, requires: "bigdecimal")

    mod = GraphWeaver.parse(
      schema: MoneyDemo::Schema,
      executor: MoneyDemo::Schema,
      query:,
      name: "StoreQuery",
    )

    product = mod.execute(name: "Widget", budget: MoneyDemo::Money.parse("2500.50")).product

    expect(product.price).to be_a MoneyDemo::Money
    expect(product.price.amount).to eq BigDecimal("2500.50")
  end

  it "accepts an explicit Proc cast and serialize, overriding inference" do
    GraphWeaver.register_scalar("Money", type: "MoneyDemo::Money",
      cast: ->(expr) { "MoneyDemo::Money.new(#{expr})" },
      serialize: ->(expr) { "#{expr}.amount.to_s" })

    scalar = GraphWeaver::Codegen.scalar("Money")
    expect(scalar.cast("x")).to eq "MoneyDemo::Money.new(x)"
    expect(scalar.serialize("x")).to eq "x.amount.to_s"
  end

  it "lets a later registration override an earlier one, including built-ins" do
    GraphWeaver.register_scalar("Date", type: "MyDate", cast: :load)

    scalar = GraphWeaver::Codegen.scalar("Date")
    expect(scalar.type).to eq "MyDate"
    expect(scalar.cast("s")).to eq "MyDate.load(s)"
  end

  it "clears and resets the registry" do
    GraphWeaver.clear_scalars!
    expect(GraphWeaver::Codegen.scalar("Date").cast?).to be false # built-in gone

    GraphWeaver.reset_scalars!
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
    expect { GraphWeaver.register_scalar("X", type: 42) }
      .to raise_error(ArgumentError, /type:/)
    expect { GraphWeaver.register_scalar("X", type: "X", cast: "nope") }
      .to raise_error(ArgumentError, /cast:/)
    expect { GraphWeaver.register_scalar("X", type: "X", serialize: 99) }
      .to raise_error(ArgumentError, /serialize:/)
  end

  it "validates requires: is a String or Array of Strings" do
    expect { GraphWeaver.register_scalar("X", type: "X", requires: 42) }
      .to raise_error(ArgumentError, /requires:/)
    expect { GraphWeaver.register_scalar("X", type: "X", requires: ["ok", ""]) }
      .to raise_error(ArgumentError, /requires:/)
    expect { GraphWeaver.register_scalar("X", type: "X", requires: ["bigdecimal"]) }
      .not_to raise_error
  end

  # the built-in Date scalar carries its own require, so any query using it
  # generates a self-contained file
  it "emits require \"date\" for the built-in Date scalar" do
    source = GraphWeaver::Codegen.generate(
      schema: Demo::Schema,
      query: File.read(File.expand_path("queries/person.graphql", __dir__)),
      module_name: "PersonQuery",
    )

    expect(source).to include(%(require "date"))
    expect(source.index(%(require "date"))).to be < source.index("module PersonQuery")
  end
end
