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
  # restore strict built-ins and the lazy default after each example
  after do
    GraphWeaver.auto_coerce = nil
    GraphWeaver::Codegen.reset_scalars!
  end

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

  it "auto_coerce gives the convertible built-ins their conversion" do
    GraphWeaver.auto_coerce = true

    float = GraphWeaver::Codegen.scalar("Float")
    expect(float.coerce?).to be true
    expect(float.coerce_input("v")).to eq "v.to_f"
    expect(float.coerce_type).to eq "T.any(Float, Integer, String)"
  end

  it "coerce: true on one built-in is auto_coerce scoped to it" do
    GraphWeaver.register_scalar("Int", Integer, coerce: true)

    source = generate

    expect(source).to include("count: T.any(Integer, Float, String)")
    expect(source).to include('"count" => count.to_i,')
    # the others are untouched — this is the per-scalar half of the switch
    expect(source).to include("amount: Float,")
    expect(source).not_to include("amount.to_f")
  end

  it "widens the numeric sigs, and leaves String/ID strictly typed" do
    GraphWeaver.auto_coerce = true

    source = generate

    # String/ID are pass-through: no conversion, no cast/serialize pair,
    # nothing to coerce from
    expect(source).to include(
      "amount: T.any(Float, Integer, String), " \
      "count: T.any(Integer, Float, String), " \
      "id: String, " \
      "label: String",
    )
    expect(source).to include('"amount" => amount.to_f,')
    expect(source).to include('"count" => count.to_i,')
    expect(source).to include('"id" => id,')
    expect(source).to include('"label" => label,')
  end

  it "refuses coerce: true on a pass-through scalar" do
    expect { GraphWeaver.register_scalar("ID", String, coerce: true) }
      .to raise_error(ArgumentError, /nothing to coerce/)
  end

  it "coerces raw inputs end to end, sending native wire values" do
    GraphWeaver.auto_coerce = true

    mod = GraphWeaver.parse(
      schema: BuiltinDemo::Schema,
      client: BuiltinDemo::Schema,
      query:,
    )

    # amount/count arrive as strings but land on the wire as a Float/Integer;
    # id/label stay strictly typed, so they pass through as written
    echo = mod.execute(amount: "5.5", count: "3", id: "42", label: "x").data!.echo

    expect(echo).to eq "Float:5.5 Integer:3 String:42 String:x"
  end

  it "auto_coerce: Boolean stays strict (no lossless conversion); Date takes parse-style coercion" do
    GraphWeaver.auto_coerce = true

    expect(GraphWeaver::Codegen.scalar("Boolean").coerce?).to be false
    expect(GraphWeaver::Codegen.scalar("Date").coerce?).to be true
  end

  # JSON has one number type, so 1.0 reaches Ruby as an Integer from any
  # encoder that drops the trailing zero — graphql-js and Go both do.
  it "reads a Float that arrived on the wire as a whole number" do
    schema = GraphQL::Schema.from_definition("type Q { ratio: Float, rate: Float! }\nschema { query: Q }")
    mod = GraphWeaver.parse(schema:, query: "query M { ratio rate }")

    result = mod.from_response!("data" => { "ratio" => 2, "rate" => 9 })

    expect(result.ratio).to eq 2.0
    expect(result.rate).to be_a Float
  end

  it "still refuses a Float the wire can't have meant" do
    schema = GraphQL::Schema.from_definition("type Q { ratio: Float }\nschema { query: Q }")
    mod = GraphWeaver.parse(schema:, query: "query M { ratio }")

    expect { mod.from_response!("data" => { "ratio" => "not a number" }) }
      .to raise_error(GraphWeaver::TypeError)
  end

  # spec: Int serializes as a JSON integer. Nothing about the wire format
  # forces the decimal point, so 2.0 is the server being wrong — unlike a
  # whole Float, which encoders write without one.
  it "refuses an Int the server wrote with a decimal point" do
    schema = GraphQL::Schema.from_definition("type Q { n: Int }\nschema { query: Q }")
    mod = GraphWeaver.parse(schema:, query: "query M { n }")

    expect { mod.from_response!("data" => { "n" => 2.0 }) }
      .to raise_error(GraphWeaver::TypeError, /'n'.*Float/m)
  end

  # a cast raises about the value alone — "invalid date" locates nothing on
  # a struct holding four of them
  it "names the field when a leaf's cast refuses the wire value" do
    schema = GraphQL::Schema.from_definition(
      "scalar Date\ntype Q { born: Date, died: Date }\nschema { query: Q }",
    )
    mod = GraphWeaver.parse(schema:, query: "query M { born died }")

    expect { mod.from_response!("data" => { "born" => "2024-01-01", "died" => "not a date" }) }
      .to raise_error(GraphWeaver::TypeError, /died: invalid date/)
  end

  # ID is a String on the wire whatever the server stores; a raw integer
  # primary key is the case that keeps happening, and looks like our bug
  it "says whose bug an unquoted ID is, and how to take it anyway" do
    schema = GraphQL::Schema.from_definition("type Q { id: ID }\nschema { query: Q }")
    mod = GraphWeaver.parse(schema:, query: "query M { id }")

    expect { mod.from_response!("data" => { "id" => 42 }) }
      .to raise_error(GraphWeaver::TypeError, /"id" unquoted.*register_scalar\("ID", "T\.untyped"\)/m)
  end

  it "rejects a non-boolean coerce:" do
    expect { GraphWeaver.register_scalar("X", "X", coerce: :to_s) }
      .to raise_error(ArgumentError, /coerce:/)
    expect { GraphWeaver.register_scalar("X", "X", coerce: 42) }
      .to raise_error(ArgumentError, /coerce:/)
  end
end
