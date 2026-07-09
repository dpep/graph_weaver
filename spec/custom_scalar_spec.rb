# typed: false
require "graphql"

# A rich Ruby value object we want GraphQL `Money` fields cast into, and a
# tiny in-process schema exposing a `Money` custom scalar. Kept in its own
# namespace and separate from Demo::Schema so registering scalars here can
# never perturb the rest of the suite.
module MoneyDemo
  class Money
    attr_reader :cents

    # wire ("$19.99") -> Money
    def self.parse(str)
      new((Float(str.delete("$,")) * 100).round)
    end

    def initialize(cents)
      @cents = cents
    end

    # Money -> wire ("$19.99")
    def to_s
      format("$%.2f", @cents / 100.0)
    end

    def ==(other)
      other.is_a?(Money) && other.cents == @cents
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
  # register_scalar mutates a process-wide registry; snapshot and restore
  # so these examples neither leak into nor depend on the rest of the suite.
  around do |example|
    saved = GraphWeaver::Codegen.scalar_registry.dup
    example.run
  ensure
    GraphWeaver::Codegen.scalar_registry.replace(saved)
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

  def generate
    GraphWeaver::Codegen.generate(schema: MoneyDemo::Schema, query:, module_name: "StoreQuery")
  end

  it "generates a Money-typed prop and inlines the cast in from_h" do
    GraphWeaver.register_scalar("Money", type: MoneyDemo::Money, cast: :parse, serialize: :to_s)

    source = generate

    expect(source).to include("const :price, MoneyDemo::Money")
    expect(source).to include('price: MoneyDemo::Money.parse(data.fetch("price"))')
    # serialize: :to_s emits the inverse for the Money variable
    expect(source).to include('"budget" => budget.to_s')
  end

  it "round-trips a custom object through serialize and cast end to end" do
    GraphWeaver.register_scalar("Money", type: MoneyDemo::Money, cast: :parse, serialize: :to_s)

    mod = GraphWeaver.parse(
      schema: MoneyDemo::Schema,
      executor: MoneyDemo::Schema,
      query:,
      name: "StoreQuery",
    )

    product = mod.execute(name: "Widget", budget: MoneyDemo::Money.new(2500)).product

    expect(product.price).to be_a MoneyDemo::Money
    expect(product.price).to eq MoneyDemo::Money.new(2500)
  end

  it "accepts a Proc cast for expressions a method name can't express" do
    GraphWeaver.register_scalar("Money", type: "MoneyDemo::Money",
      cast: ->(expr) { "MoneyDemo::Money.new(#{expr})" })

    expect(GraphWeaver::Codegen.scalar("Money").cast("x")).to eq "MoneyDemo::Money.new(x)"
  end

  it "lets a later registration override an earlier one, including built-ins" do
    GraphWeaver.register_scalar("Date", type: "MyDate", cast: :load)

    scalar = GraphWeaver::Codegen.scalar("Date")
    expect(scalar.type).to eq "MyDate"
    expect(scalar.cast("s")).to eq "MyDate.load(s)"
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
  end
end
