# typed: false
# A field registered by TYPE STRING has no coercer, so nothing brands its
# refusal on the way past — only sorbet stands between the value and the
# struct, and InputStruct.mistyped is what turns sorbet's complaint back into
# the library's. These are the shapes a type string can name.
describe GraphWeaver::InputStruct do
  after { GraphWeaver::Codegen.reset_scalars! }

  SHAPES_SCHEMA = GraphQL::Schema.from_definition(<<~GRAPHQL)
    scalar Vector
    scalar Grid
    scalar JSON
    input LineItemInput { sku: String!, vector: Vector, grid: Grid, notes: [JSON!] }
    input OrderInput { items: [LineItemInput!]! }
    type Order { id: ID! }
    type Mutation { placeOrder(input: OrderInput!): Order }
    type Query { order: Order }
  GRAPHQL

  let(:client) do
    Class.new do
      def execute(_query, variables:, **) = { "data" => { "placeOrder" => { "id" => "1" } } }
    end.new
  end

  def place(item)
    GraphWeaver.register_scalar("Vector", "T::Array[Float]")
    GraphWeaver.register_scalar("Grid", "T::Array[T::Array[Float]]")
    mod = GraphWeaver.parse(
      schema: SHAPES_SCHEMA,
      query: "mutation PlaceOrder($input: OrderInput!) { placeOrder(input: $input) { id } }",
      name: "PlaceOrderMutation",
    )
    mod.execute!(input: { items: [{ sku: "A1" }.merge(item)] }, client:)
  end

  def refusal(item)
    place(item)
    raise "expected a refusal"
  rescue GraphWeaver::InputError => e
    e
  end

  # `[1, 2, 3]` for a T::Array[Float]: sorbet's #valid? is shallow and says
  # yes, while the setter checks recursively and raises — so mistyped's own
  # check couldn't see what had gone wrong, and blamed the containing list.
  it "names the field whose element type refused, not the list holding it" do
    error = refusal(vector: [1, 2, 3])

    expect(error.message).to eq %($input of PlaceOrder: vector: expected Vector, got [1, 2, 3])
    expect(error.coordinate).to eq "LineItemInput.vector"
    expect(error.path).to eq ["input", "items", 0, "vector"]
    expect(error.details).to eq(type: "Vector")
    expect(error.value).to eq [1, 2, 3]
  end

  it "sees through a list of lists to the element that refused" do
    error = refusal(grid: [[1.0], [2]])

    expect(error.message).to include "grid: expected Grid, got [[1.0], [2]]"
    expect(error.coordinate).to eq "LineItemInput.grid"
    expect(error.details).to eq(type: "Grid")
  end

  # The schema's own spelling, not the prop's: a list of a scalar nothing
  # coerces reaches here as "T::Array[T.untyped]", which is the library's
  # vocabulary in the one field an app translates for a user.
  it "reports a list field the way the schema spells it" do
    error = refusal(notes: "nope")

    expect(error.message).to eq %($input of PlaceOrder: notes: expected [JSON!], got "nope")
    expect(error.details).to eq(type: "[JSON!]")
  end

  # the nilable wrapper is the prop's, not the element's: nil stays legal
  it "keeps nil legal in a nilable field, and still checks a supplied list" do
    expect { place(vector: nil) }.not_to raise_error
    expect(refusal(vector: ["a"]).coordinate).to eq "LineItemInput.vector"
  end

  # already correct before the fix — sorbet's shallow check caught this one,
  # so it is the shape the two above now report like
  it "reports a wholly wrong type the same way" do
    error = refusal(vector: "nope")

    expect(error.message).to eq %($input of PlaceOrder: vector: expected Vector, got "nope")
    expect(error.coordinate).to eq "LineItemInput.vector"
    expect(error.details).to eq(type: "Vector")
  end
end
