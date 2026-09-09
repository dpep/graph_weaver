# typed: false
require "graphql"

# A tiny schema whose query takes one variable of each built-in scalar and
# echoes back what the server actually received (class + value), so coercion
# can be checked end to end.
module BuiltinDemo
  class QueryType < GraphQL::Schema::Object
    graphql_name "Query"

    field :echo, String, null: false do
      argument :amount, Float, required: true
      argument :count, Int, required: true
      argument :flag, Boolean, required: true
      argument :id, ID, required: true
      argument :label, String, required: true
    end

    def echo(amount:, count:, flag:, id:, label:)
      "#{amount.class}:#{amount} #{count.class}:#{count} #{flag.class}:#{flag} " \
        "#{id.class}:#{id} #{label.class}:#{label}"
    end

    field :join, String, null: false do
      argument :ids, [ID], required: true
    end

    def join(ids:) = ids.map { |id| "#{id.class}:#{id}" }.join(" ")
  end

  class Schema < GraphQL::Schema
    query QueryType
  end
end

describe "built-in scalar coercion" do
  after { GraphWeaver::Codegen.reset_scalars! }

  let(:query) do
    <<~GRAPHQL
      query Compute($amount: Float!, $count: Int!, $flag: Boolean!, $id: ID!, $label: String!) {
        echo(amount: $amount, count: $count, flag: $flag, id: $id, label: $label)
      }
    GRAPHQL
  end

  let(:mod) { GraphWeaver.parse(schema: BuiltinDemo::Schema, client: BuiltinDemo::Schema, query:) }

  # every variable typed, so an example only says what it is varying
  def echo(**loose)
    mod.execute!(**{ amount: 1.5, count: 3, flag: true, id: "42", label: "x" }.merge(loose)).echo
  end

  it "keeps the kwarg sig as narrow as the schema" do
    source = GraphWeaver::Codegen.generate(schema: BuiltinDemo::Schema, query:, module_name: "ComputeQuery")

    expect(source).to include("amount: Float, count: Integer, flag: T::Boolean, id: String, label: String")
    # the sig can't be what stops a Rails param, so it isn't the check
    expect(source).to include(".checked(:never)")
  end

  it "passes an already-typed value through" do
    expect(echo).to eq "Float:1.5 Integer:3 TrueClass:true String:42 String:x"
  end

  it "converts an untyped value into the type the sig promises" do
    expect(echo(amount: "5.5", count: "3", id: 42))
      .to eq "Float:5.5 Integer:3 TrueClass:true String:42 String:x"
  end

  it "names the variable, the operation and the value it refused" do
    expect { echo(count: "lots") }
      .to raise_error(GraphWeaver::InputError, '$count of Compute: expected an Int, got "lots"')
  end

  # Integer(2.5) is 2 and Integer("2.5") raises — one door, one answer
  it "refuses an Int conversion that would lose something" do
    expect { echo(count: 2.5) }.to raise_error(GraphWeaver::InputError, /not a whole number/)
    expect { echo(count: "2.5") }.to raise_error(GraphWeaver::InputError, /\$count/)
    expect(echo(count: 3.0)).to include "Integer:3"
  end

  # Kernel#Integer reads "010" as octal; a zero-padded form field is a real input
  it "reads a numeric string in base 10" do
    expect(echo(count: "010")).to include "Integer:10"
  end

  # Ruby literal syntax, which Kernel#Integer and Kernel#Float both accept
  it "refuses number spellings no server or form writes" do
    expect { echo(amount: "0x1f") }.to raise_error(GraphWeaver::InputError, /\$amount/)
    expect { echo(amount: "1_0") }.to raise_error(GraphWeaver::InputError, /\$amount/)
    expect { echo(count: "0x1f") }.to raise_error(GraphWeaver::InputError, /\$count/)
  end

  it "refuses a String for a Boolean, and says to convert at the call site" do
    expect { echo(flag: "true") }
      .to raise_error(GraphWeaver::InputError, /\$flag of Compute: expected a Boolean.*call site/)
    expect { echo(flag: 1) }.to raise_error(GraphWeaver::InputError, /\$flag/)
  end

  # the GraphQL spec has ID serialize as a String but accept an integer input
  it "takes an Integer for ID, and refuses one for String" do
    expect(echo(id: 42)).to include "String:42"
    expect { echo(label: 42) }.to raise_error(GraphWeaver::InputError, /\$label of Compute: expected a String/)
  end

  it "refuses nil for a non-null variable" do
    expect { echo(id: nil) }.to raise_error(GraphWeaver::InputError, /\$id of Compute: expected an ID, got nil/)
  end

  # nothing about true or a hash says which number it meant
  it "refuses a value of no numeric kind at all" do
    expect { echo(count: true) }.to raise_error(GraphWeaver::InputError, /\$count of Compute: expected an Int/)
    expect { echo(amount: { a: 1 }) }.to raise_error(GraphWeaver::InputError, /\$amount of Compute: expected a Float/)
  end

  # nothing is registered for it, so nothing is known to convert it to
  it "leaves an unregistered scalar untouched" do
    source = GraphWeaver::Codegen.generate(
      schema: Demo::Schema,
      query: "query Pets($where: PetFilter) { findPets(where: $where) { metadata } }",
      module_name: "PetsQuery",
    )

    expect(source).to include('Field.new(:metadata, "metadata", false, nil, nil)')
  end

  # A scalar registered as a Ruby type with no codec and no entry in Coerce's
  # table gets no coercer either, so the struct's own type is the only check
  # left — and sorbet's complaint is what reaches the app unless something
  # brands it.
  it "brands a wrong-typed field no coercer covers" do
    GraphWeaver.register_scalar("Metadata", Hash)
    mod = GraphWeaver.parse(
      schema: Demo::Schema, client: Demo::Schema,
      query: "query Pets($where: PetFilter) { findPets(where: $where) { name } }",
    )

    expect { mod::PetFilter.coerce({ metadata: "brown" }) }
      .to raise_error(GraphWeaver::InputError, /invalid input for .*PetFilter/) { |error|
        expect(error.cause).to be_a ::TypeError
      }
  end

  it "coerces input-object fields through the same table" do
    mod = GraphWeaver.parse(
      schema: Demo::Schema, client: Demo::Schema,
      query: "mutation Adopt($input: AdoptionInput!) { adopt(input: $input) { name } }",
    )

    # Date's cast: is also what a raw iso8601 string coerces through
    expect(mod.execute!(input: { name: "Rex", species: "DOG", birthday: "2020-06-15" }).adopt.name).to eq "Rex"
    expect { mod.execute!(input: { name: 7, species: "DOG" }) }
      .to raise_error(GraphWeaver::InputError, /name: expected a String, got 7/)
    expect { mod.execute!(input: { name: "Rex", species: "DOG", birthday: "nope" }) }
      .to raise_error(GraphWeaver::InputError, /birthday: invalid date/)
  end

  it "coerces each element of a list variable" do
    list = GraphWeaver.parse(
      schema: BuiltinDemo::Schema, client: BuiltinDemo::Schema,
      query: "query Ids($ids: [ID!]!) { join(ids: $ids) }",
    )

    expect(list.execute!(ids: [1, "2"]).join).to eq "String:1 String:2"
    expect { list.execute!(ids: [1, true]) }
      .to raise_error(GraphWeaver::InputError, /\$ids of Ids: expected an ID/)
  end

  # JSON has one number type, so 1.0 reaches Ruby as an Integer from any
  # encoder that drops the trailing zero — graphql-js and Go both do.
  it "reads a Float that arrived on the wire as a whole number" do
    schema = GraphQL::Schema.from_definition("type Q { ratio: Float, rate: Float! }\nschema { query: Q }")
    mod = GraphWeaver.parse(schema:, query: "query M { ratio rate }")

    result = mod.from_response!("data" => { "ratio" => 2, "rate" => 9 })

    expect(result.ratio).to eq 2.0
    expect(result.rate).to be_a Float
    expect(mod.from_response!("data" => { "ratio" => 1.5, "rate" => 9 }).ratio).to eq 1.5
  end

  it "still refuses a Float the wire can't have meant" do
    schema = GraphQL::Schema.from_definition("type Q { ratio: Float }\nschema { query: Q }")
    mod = GraphWeaver.parse(schema:, query: "query M { ratio }")

    expect { mod.from_response!("data" => { "ratio" => "not a number" }) }
      .to raise_error(GraphWeaver::TypeError)
    expect { mod.from_response!("data" => { "ratio" => true }) }
      .to raise_error(GraphWeaver::TypeError, /ratio: expected a Float/)
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
end
