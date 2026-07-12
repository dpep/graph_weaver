# typed: false
require "graphql"

# A tiny schema whose query takes one variable of each convertible built-in
# scalar and echoes back what the server actually received (class + value),
# so coercion can be checked end to end.
module BuiltinDemo
  class QueryType < GraphQL::Schema::Object
    graphql_name "Query"

    field :echo, String, null: false do
      argument :amount, Float, required: true
      argument :count, Int, required: true
      argument :id, ID, required: true
      argument :label, String, required: true
    end

    def echo(amount:, count:, id:, label:)
      "#{amount.class}:#{amount} #{count.class}:#{count} #{id.class}:#{id} #{label.class}:#{label}"
    end
  end

  class Schema < GraphQL::Schema
    query QueryType
  end
end

describe "built-in scalar coercion" do
  # reset_scalars! restores the strict built-ins after each example.
  after { GraphWeaver.reset_scalars! }

  let(:query) do
    <<~GRAPHQL
      query Compute($amount: Float!, $count: Int!, $id: ID!, $label: String!) {
        echo(amount: $amount, count: $count, id: $id, label: $label)
      }
    GRAPHQL
  end

  def generate
    GraphWeaver::Codegen.generate(schema: BuiltinDemo::Schema, query:, module_name: "ComputeQuery")
  end

  it "is off by default — scalar variables stay strictly typed and identity-serialized" do
    source = generate

    expect(source).to include("amount: Float, count: Integer, id: String, label: String")
    expect(source).to include('"amount" => amount,')
    expect(source).not_to include("amount.to_f")
  end

  it "reset_scalars!(coerce: true) reloads the built-ins as coercible" do
    GraphWeaver.reset_scalars!(coerce: true)

    float = GraphWeaver::Codegen.scalar("Float")
    expect(float.coerce?).to be true
    expect(float.coerce_input("v")).to eq "v.to_f"
    expect(float.coerce_type).to eq "T.any(Float, Integer, String)"
  end

  it "widens the sig and converts each variable when coercion is on" do
    GraphWeaver.reset_scalars!(coerce: true)

    source = generate

    expect(source).to include(
      "amount: T.any(Float, Integer, String), " \
      "count: T.any(Integer, Float, String), " \
      "id: T.anything, " \
      "label: T.anything",
    )
    expect(source).to include('"amount" => amount.to_f,')
    expect(source).to include('"count" => count.to_i,')
    expect(source).to include('"id" => id.to_s,')
    expect(source).to include('"label" => label.to_s,')
  end

  it "coerces raw inputs end to end, sending native wire values" do
    GraphWeaver.reset_scalars!(coerce: true)

    mod = GraphWeaver.parse(
      schema: BuiltinDemo::Schema,
      executor: BuiltinDemo::Schema,
      query:,
    )

    # amount/count arrive as strings but land on the wire as a Float/Integer;
    # id (Integer) and label (Float, another built-in) are stringified via to_s
    echo = mod.execute(amount: "5.5", count: "3", id: 42, label: 3.5).data!.echo

    expect(echo).to eq "Float:5.5 Integer:3 String:42 String:3.5"
  end

  it "leaves Boolean and Date strict even with coerce: true" do
    GraphWeaver.reset_scalars!(coerce: true)

    expect(GraphWeaver::Codegen.scalar("Boolean").coerce?).to be false
    expect(GraphWeaver::Codegen.scalar("Date").coerce?).to be false
  end

  it "rejects a non-boolean, non-symbol coerce:" do
    expect { GraphWeaver.register_scalar("X", "X", coerce: 42) }
      .to raise_error(ArgumentError, /coerce:/)
  end
end
