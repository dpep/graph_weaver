# typed: false
require "bigdecimal"
require "graphql"

# What a registration promises the wire can produce. A scalar's Ruby type is
# only reachable if JSON already parses into it or a cast: builds it — and a
# registration that satisfies neither is broken for every value, so it is
# refused at generation rather than at 3am.
describe "registered scalar wire types" do
  # An app's own value object with no way in from JSON: no .parse or .load to
  # probe, and no Kernel conversion of its name.
  class Uncastable; end # rubocop:disable Lint/ConstantDefinitionInBlock

  after { GraphWeaver::Codegen.reset_scalars! }

  let(:schema) do
    GraphQL::Schema.from_definition(
      "scalar Money\ntype Q { price: Money, cost: Money }\nschema { query: Q }",
    )
  end

  def generate
    GraphWeaver::Codegen.generate(schema:, query: "query M { price }", name: "PriceQuery")
  end

  it "refuses a type nothing on the wire can be, with no cast to build one" do
    GraphWeaver.register_scalar("Money", Uncastable)

    expect { generate }.to raise_error(GraphWeaver::Error, /no cast.*Q\.price.*cast:/m)
  end

  it "takes the same type once a cast builds it" do
    GraphWeaver.register_scalar("Money", Uncastable, cast: ->(v) { "Uncastable.build(#{v})" })

    expect(generate).to include("Uncastable.build(")
  end

  # where BigDecimal used to land: the type people reach for, and the one
  # Kernel#BigDecimal has been able to build all along
  it "infers a cast for a stdlib type rather than refusing it" do
    GraphWeaver.register_scalar("Money", BigDecimal)

    expect(generate).to include("BigDecimal(v1)", %(require "bigdecimal"))
  end

  # String, Integer, Float and friends need nothing: the wire is already one
  it "leaves a pass-through registration alone" do
    GraphWeaver.register_scalar("Money", String)

    expect(generate).to include("const :price, T.nilable(String)")
  end

  # a value the schema didn't declare is drift far more often than a bad
  # server, and T::Enum's KeyError says neither that nor what is legal
  it "names the values an enum does have when the wire brings one it doesn't" do
    enum_schema = GraphQL::Schema.from_definition(
      "enum Colour { RED GREEN }\ntype Q { c: Colour }\nschema { query: Q }",
    )
    mod = GraphWeaver.parse(schema: enum_schema, query: "query M { c }")

    expect { mod.from_response!("data" => { "c" => "PURPLE" }) }
      .to raise_error(GraphWeaver::TypeError, /c: "PURPLE" is not a .*expected one of: GREEN, RED.*regenerate/m)
  end

  # the same registration used only for a variable is fine — nothing casts it
  it "only judges a scalar the query reads back" do
    input = GraphQL::Schema.from_definition(
      "scalar Money\ntype Q { ok(at: Money): Boolean }\nschema { query: Q }",
    )
    GraphWeaver.register_scalar("Money", BigDecimal, serialize: :to_s, requires: "bigdecimal")

    expect {
      GraphWeaver::Codegen.generate(schema: input, query: "query M($at: Money) { ok(at: $at) }",
        name: "OkQuery")
    }.not_to raise_error
  end
end
