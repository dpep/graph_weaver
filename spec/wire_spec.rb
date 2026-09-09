# typed: false
require "bigdecimal"
require "graphql"

# What a registration promises the wire can produce. A scalar's Ruby type is
# only reachable if JSON already parses into it or a cast: builds it — and a
# registration that satisfies neither is broken for every value, so it is
# refused at generation rather than at 3am.
describe "registered scalar wire types" do
  after { GraphWeaver::Codegen.reset_scalars! }

  let(:schema) do
    GraphQL::Schema.from_definition(
      "scalar Money\ntype Q { price: Money, cost: Money }\nschema { query: Q }",
    )
  end

  def generate
    GraphWeaver::Codegen.generate(schema:, query: "query M { price }", module_name: "PriceQuery")
  end

  it "refuses a type nothing on the wire can be, with no cast to build one" do
    GraphWeaver.register_scalar("Money", BigDecimal, requires: "bigdecimal")

    expect { generate }.to raise_error(GraphWeaver::Error, /no cast.*Q\.price.*cast:/m)
  end

  it "takes the same type once a cast builds it" do
    GraphWeaver.register_scalar("Money", BigDecimal, cast: ->(v) { "BigDecimal(#{v})" },
      serialize: :to_s, requires: "bigdecimal")

    expect(generate).to include("BigDecimal(")
  end

  # String, Integer, Float and friends need nothing: the wire is already one
  it "leaves a pass-through registration alone" do
    GraphWeaver.register_scalar("Money", String)

    expect(generate).to include("const :price, T.nilable(String)")
  end

  # the same registration used only for a variable is fine — nothing casts it
  it "only judges a scalar the query reads back" do
    input = GraphQL::Schema.from_definition(
      "scalar Money\ntype Q { ok(at: Money): Boolean }\nschema { query: Q }",
    )
    GraphWeaver.register_scalar("Money", BigDecimal, serialize: :to_s, requires: "bigdecimal")

    expect {
      GraphWeaver::Codegen.generate(schema: input, query: "query M($at: Money) { ok(at: $at) }",
        module_name: "OkQuery")
    }.not_to raise_error
  end
end
