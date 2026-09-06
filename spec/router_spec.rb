# typed: ignore — subgraph classes and eval'd query modules are invisible to srb
# frozen_string_literal: true

require "graph_weaver/testing"

# The local federation router: one subgraph per operation, verbatim, and a
# loud refusal for everything that crosses a boundary.
describe GraphWeaver::Testing::Router do
  Unplannable = GraphWeaver::Testing::Unplannable

  subject(:router) do
    described_class.new(supergraph: RouterGraph::SUPERGRAPH, subgraphs: RouterGraph::SUBGRAPHS)
  end

  def refusal(query, variables: {})
    router.execute(query, variables:)
    raise "expected #{query.inspect} to be refused"
  rescue Unplannable => e
    e
  end

  describe "a query that stays inside one subgraph" do
    it "answers exactly what that subgraph answers, and says which it asked" do
      query = "query($first: Int!) { topProducts(first: $first) { upc name price } }"
      variables = { "first" => 2 }

      expect(router.execute(query, variables:))
        .to eq RouterGraph::Products::Schema.execute(query, variables:).to_h
      expect(router.trace).to eq [{ subgraph: "products", query:, variables: }]
    end

    it "routes each operation to its own subgraph" do
      router.execute("{ me { username } }")
      expect(router.trace.map { |fetch| fetch[:subgraph] }).to eq ["accounts"]

      router.execute("{ reviews { body } }")
      expect(router.trace.map { |fetch| fetch[:subgraph] }).to eq ["reviews"]
    end

    it "passes context through to the resolvers" do
      as_ada = described_class.new(
        supergraph: RouterGraph::SUPERGRAPH,
        subgraphs: RouterGraph::SUBGRAPHS,
        context: { current_user_id: "2" },
      )

      expect(as_ada.execute("{ me { username } }").dig("data", "me", "username")).to eq "ada"
    end

    it "plans a union, a fragment, and an alias that never leave the subgraph" do
      feed = router.execute("{ feed { ... on Review { body } ... on Announcement { headline } } }")
      expect(feed.dig("data", "feed")).to eq [{ "body" => "Love it" }, { "headline" => "New in stock" }]

      spread = router.execute("query { me { ...Bits } } fragment Bits on User { handle: username }")
      expect(spread.dig("data", "me")).to eq({ "handle" => "dpep" })
    end

    # @provides means this subgraph carries its own copy, and the router
    # reads that copy rather than routing to the owner — so neither does this
    it "follows @provides rather than routing to the owning subgraph" do
      response = router.execute("{ reviews { body author { username } } }")

      expect(response.dig("data", "reviews", 0, "author", "username")).to eq "dpep"
      expect(router.trace.map { |fetch| fetch[:subgraph] }).to eq ["reviews"]
    end

    it "runs a mutation-free document's __typename against whichever subgraph runs it" do
      expect(router.execute("{ __typename me { username } }").fetch("data"))
        .to eq({ "__typename" => "Query", "me" => { "username" => "dpep" } })
    end
  end

  describe "refusing" do
    it "refuses before any subgraph runs" do
      expect { router.execute("{ me { username reviews { body } } }") }.to raise_error(Unplannable)
      expect(router.trace).to be_empty
    end

    it "is a GraphWeaver::Error, so one rescue catches it" do
      expect { router.execute("{ me { reviews { body } } }") }.to raise_error(GraphWeaver::Error)
      expect(refusal("{ me { reviews { body } } }").to_h)
        .to include("category" => "crosses_subgraph")
    end

    it "names the field, both subgraphs, and what to do — a boundary crossing" do
      error = refusal("{ me { username reviews { body } } }")

      expect(error.category).to eq :crosses_subgraph
      expect(error.message).to eq "User.reviews is resolved by reviews, and this operation runs in " \
        "accounts — the local router hands one query to one subgraph verbatim and doesn't stitch " \
        "across a boundary. Run this one against a real router."
    end

    it "names the field sets — a @requires the running subgraph can't satisfy" do
      error = refusal("{ reviews { product { shippingEstimate } } }")

      expect(error.category).to eq :requires
      expect(error.message).to eq 'Product.shippingEstimate runs in reviews and @requires ' \
        '"price weight", which reviews doesn\'t hold (price, weight come from products) — the ' \
        "router fetches those first and hands them back, a chain the local router doesn't plan. " \
        "Run this one against a real router."
    end

    it "names every root field and its subgraph — root fields that span" do
      error = refusal("{ me { username } topProducts(first: 2) { name } }")

      expect(error.category).to eq :root_fields_span
      expect(error.message).to start_with "this operation's root fields span subgraphs — " \
        "Query.me (accounts), Query.topProducts (products)."
      expect(error.message).to end_with "Split it into one operation per subgraph, or run this one " \
        "against a real router."
    end

    # a union whose members live in different subgraphs, plus a subscription
    # root — neither shape the demo graph has
    SPLIT_UNION = <<~SDL
      schema @link(url: "https://specs.apollo.dev/link/v1.0")
        @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
      { query: Query, subscription: Subscription }
      directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT | UNION
      directive @join__unionMember(graph: join__Graph!, member: String!) repeatable on UNION
      scalar join__FieldSet
      enum join__Graph {
        A @join__graph(name: "a", url: "http://a")
        B @join__graph(name: "b", url: "http://b")
      }
      type Query @join__type(graph: A) @join__type(graph: B) {
        search: [Result!]! @join__field(graph: A)
      }
      type Subscription @join__type(graph: A) { ticks: Int @join__field(graph: A) }
      union Result @join__type(graph: A) @join__type(graph: B)
        @join__unionMember(graph: A, member: "Doc")
        @join__unionMember(graph: B, member: "Note") = Doc | Note
      type Doc @join__type(graph: A) { id: ID! }
      type Note @join__type(graph: B) { id: ID! }
    SDL

    # nothing here is ever executed — every one of these refuses at plan time
    let(:split) do
      stand_in = RouterGraph::Accounts::Schema
      described_class.new(supergraph: SPLIT_UNION, subgraphs: { "a" => stand_in, "b" => stand_in })
    end

    it "refuses a fragment on a type the running subgraph doesn't declare" do
      expect { split.execute("{ search { ... on Note { id } } }") }
        .to raise_error(Unplannable, /\ANote lives in b, and this operation runs in a —/)

      split.execute("{ search { ... on Doc { id } } }") # the same shape, one subgraph
      expect(split.trace.map { |fetch| fetch[:subgraph] }).to eq ["a"]
    end

    it "refuses a subscription" do
      expect { split.execute("subscription { ticks }") }
        .to raise_error(Unplannable, /plans queries and mutations — got a subscription/)
    end

    it "refuses introspection mixed with data fields" do
      error = refusal("{ __schema { queryType { name } } me { id } }")

      expect(error.category).to eq :mixed_introspection
      expect(error.message).to include "answers introspection from the composed API schema"
    end

    it "asks which operation when the document holds more than one" do
      error = refusal("query A { me { username } } query B { me { email } }")

      expect(error.category).to eq :ambiguous_operation
      expect(error.message).to eq "the document holds 2 operations (A, B) — pass operation_name: " \
        "to say which one to run."
      expect(router.execute("query A { me { username } } query B { me { email } }", operation_name: "B"))
        .to eq({ "data" => { "me" => { "email" => "pepper.daniel@gmail.com" } } })
    end
  end

  describe "answering as a router does" do
    # a subgraph would answer with its own slice, and its own root type
    it "answers introspection from the composed API schema" do
      response = router.execute("{ __schema { types { name } } }")
      names = response.dig("data", "__schema", "types").map { |type| type["name"] }

      expect(names).to include "Product", "Review", "User"
      expect(names.grep(/join__|_Entity|_Any/)).to be_empty
      expect(router.trace).to be_empty
    end

    it "reports a query that no longer validates, without asking a subgraph" do
      response = router.execute("{ me { nosuch } }")

      expect(response["data"]).to be_nil
      expect(response.dig("errors", 0, "extensions", "code")).to eq "GRAPHQL_VALIDATION_FAILED"
      expect(router.trace).to be_empty
    end

    it "reports an unparseable query" do
      expect(router.execute("{ me {").dig("errors", 0, "extensions", "code"))
        .to eq "GRAPHQL_PARSE_FAILED"
    end
  end

  describe "construction" do
    it "requires every subgraph in the supergraph, and only those" do
      expect { described_class.new(supergraph: RouterGraph::SUPERGRAPH, subgraphs: { "accounts" => RouterGraph::Accounts::Schema }) }
        .to raise_error(ArgumentError, /missing products, reviews/)

      expect {
        described_class.new(
          supergraph: RouterGraph::SUPERGRAPH,
          subgraphs: RouterGraph::SUBGRAPHS.merge("billing" => RouterGraph::Accounts::Schema),
        )
      }.to raise_error(ArgumentError, /unknown billing/)
    end

    # bounding the maintenance tail across federation spec versions: a
    # construct the routing table doesn't read makes the whole table a guess
    it "refuses a supergraph carrying a federation construct it doesn't read" do
      sdl = File.read(RouterGraph::SUPERGRAPH).sub(
        "type Announcement\n  @join__type(graph: REVIEWS)",
        "type Announcement\n  @join__type(graph: REVIEWS)\n  @join__directive(graphs: [REVIEWS], name: \"x\")",
      )

      expect { described_class.new(supergraph: sdl, subgraphs: RouterGraph::SUBGRAPHS) }
        .to raise_error(Unplannable, /Announcement applies @join__directive/)
    end
  end

  # the point of the whole thing: generated modules against real resolvers
  describe "as the app's client" do
    around do |example|
      previous = GraphWeaver.client
      GraphWeaver.client = router
      example.run
    ensure
      GraphWeaver.client = previous
    end

    it "runs a generated query module against the real subgraph resolvers" do
      mod = GraphWeaver.parse(
        schema: router.schema,
        query: "query Basket { topProducts(first: 2) { name price } }",
        name: "BasketQuery",
      )

      products = mod.execute!.top_products
      expect(products.map(&:name)).to eq ["Table", "Couch"]
      expect(products.first.price).to eq 899
      expect(router.trace.map { |fetch| fetch[:subgraph] }).to eq ["products"]
    end
  end

  it "logs each fetch at debug, and never the context" do
    log = StringIO.new
    GraphWeaver.logger = Logger.new(log, level: Logger::DEBUG)
    router.execute("{ me { username } }")

    expect(log.string).to include "router -> accounts"
    expect(router.inspect).to eq '#<GraphWeaver::Testing::Router subgraphs=["accounts", "products", "reviews"]>'
  ensure
    GraphWeaver.logger = nil
  end
end
