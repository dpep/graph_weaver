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

  describe "a query that crosses a subgraph boundary" do
    def subgraphs = router.trace.map { |fetch| fetch[:subgraph] }

    it "splits at the crossing and stitches the entity back" do
      response = router.execute("{ me { username reviews { id body } } }")

      expect(response.fetch("data")).to eq({
        "me" => {
          "username" => "dpep",
          "reviews" => [{ "id" => "r1", "body" => "Love it" }, { "id" => "r2", "body" => "Too expensive" }],
        },
      })
      expect(subgraphs).to eq ["accounts", "reviews"]
    end

    # the key travels under a reserved alias so it can't collide with a
    # response key the caller asked for, and never reaches the caller
    it "injects the @key it needs and strips it back out" do
      router.execute("{ me { username reviews { body } } }")
      keys, entities = router.trace

      expect(keys[:query]).to include "_gw_id: id"
      expect(entities[:variables]).to eq({ "representations" => [{ "id" => "1", "__typename" => "User" }] })
    end

    it "fetches every node at one level in one _entities call" do
      response = router.execute("{ users { username reviews { body product { name } } } }")

      expect(response.dig("data", "users", 1, "reviews", 0, "product", "name")).to eq "Chair"
      # two users in one fetch, then all three of their reviews' products in one more
      expect(subgraphs).to eq ["accounts", "reviews", "products"]
      expect(router.trace.last[:variables].fetch("representations").size).to eq 3
    end

    # both selections carry a plan under the same response key, and keeping
    # only the last one would silently drop the other's fetch
    it "keeps every subplan when two selections share a response key" do
      response = router.execute("{ reviews { product { name } product { upc } } }")

      expect(response.dig("data", "reviews", 0, "product")).to eq({ "name" => "Table", "upc" => "p1" })
    end

    it "runs root fields that span subgraphs as one fetch each" do
      response = router.execute("{ me { username } topProducts(first: 1) { name } }")

      expect(response.fetch("data"))
        .to eq({ "me" => { "username" => "dpep" }, "topProducts" => [{ "name" => "Table" }] })
      expect(subgraphs).to eq ["accounts", "products"]
    end

    it "reads a @provides copy in place and fetches only the rest" do
      response = router.execute("{ reviews { author { username email } } }")

      expect(response.dig("data", "reviews", 0, "author"))
        .to eq({ "username" => "dpep", "email" => "pepper.daniel@gmail.com" })
      expect(subgraphs).to eq ["reviews", "accounts"]
    end

    it "leaves a skipped stitched field absent rather than null" do
      query = "query($hide: Boolean!) { me { username reviews @skip(if: $hide) { body } } }"

      expect(router.execute(query, variables: { "hide" => true }).fetch("data"))
        .to eq({ "me" => { "username" => "dpep" } })
    end

    # A stitched fetch can put a null where the composed schema says non-null,
    # and nothing re-applies GraphQL's propagation rules over a merged tree
    # unless the router does: without it this comes back populated, with a
    # null inside, and the real router answers data: null.
    describe "a null the merged tree can't hold" do
      it "propagates it the way the composed schema says" do
        # products can't resolve the orphan's upc, so Review.product — a
        # Product! inside a [Review!]! — comes back null
        expect(router.execute("{ orphanReviews { body product { name } } }"))
          .to eq({ "data" => nil })
      end

      it "re-paths a subgraph error out of _entities, without inventing a location" do
        response = router.execute("{ topProducts(first: 4) { name shippingEstimate } }")

        expect(response.fetch("data")).to be_nil
        expect(response.fetch("errors"))
          .to eq [{ "message" => "carrier unavailable", "path" => ["topProducts", 3, "shippingEstimate"] }]
      end
    end
  end

  describe "refusing" do
    it "refuses before any subgraph runs" do
      expect { router.execute("{ reviews { product { shippingEstimate } } }") }.to raise_error(Unplannable)
      expect(router.trace).to be_empty
    end

    it "is a GraphWeaver::Error, so one rescue catches it" do
      expect { router.execute("{ reviews { product { shippingEstimate } } }") }
        .to raise_error(GraphWeaver::Error)
      expect(refusal("{ reviews { product { shippingEstimate } } }").to_h)
        .to include("category" => "requires")
    end

    # Apollo's router injects the @key under its own name and lets it win, so
    # this comes back as the user's id rather than their username. Matching
    # the router matters more than being right — and we can be neither.
    it "names the alias colliding with a @key the fetch needs" do
      error = refusal("{ me { id: username reviews { body } } }")

      expect(error.category).to eq :shadowed_key
      expect(error.detail).to eq 'User.reviews is fetched on User\'s "id", and this selection ' \
        'aliases username as "id" over it'
      expect(error.message).to end_with "Rename the alias."
    end

    it "names the abstract type it can't build a representation for" do
      error = refusal("{ feed { ... on Review { body author { email } } } }")

      expect(error.category).to eq :abstract_boundary
      expect(error.detail).to eq "this operation selects ...on Review inside FeedItem and part of " \
        "it resolves outside reviews"
    end

    it "names the field sets — a @requires the running subgraph can't satisfy" do
      error = refusal("{ reviews { product { shippingEstimate } } }")

      expect(error.category).to eq :requires
      expect(error.message).to eq 'Product.shippingEstimate runs in reviews and @requires ' \
        '"price weight", which reviews doesn\'t hold (price, weight come from products) — the ' \
        "router fetches those first and hands them back, a chain the local router doesn't plan. " \
        "Run this one against a real router."
    end

    # a union split across subgraphs, a mutation whose roots are, and a
    # subscription — none of them shapes the demo graph has
    let(:split) do
      described_class.new(supergraph: SplitGraph::SUPERGRAPH, subgraphs: SplitGraph::SUBGRAPHS)
    end

    it "refuses a fragment on a type the running subgraph doesn't declare" do
      expect { split.execute("{ search { ... on Note { id } } }") }
        .to raise_error(Unplannable, /\ANote lives in b, and this operation runs in a —/)

      split.execute("{ search { ... on Doc { id } } }") # the same shape, one subgraph
      expect(split.trace.map { |fetch| fetch[:subgraph] }).to eq ["a"]
    end

    it "refuses a subscription" do
      expect { split.execute("subscription { ticks }") }
        .to raise_error(Unplannable, /\Athis document is a subscription — the local router plans/)
    end

    # query roots resolve independently, so the router just fetches each in
    # its own subgraph; mutation roots run in series, and splitting them
    # would run them in whatever order the plan happened to
    it "refuses a mutation whose root fields span subgraphs" do
      begin
        split.execute("mutation { publish { id } annotate { id } }")
        raise "expected a refusal"
      rescue Unplannable => e
        expect(e.category).to eq :root_fields_span
        expect(e.detail).to eq "this mutation's root fields span subgraphs: " \
          "Mutation.publish (a), Mutation.annotate (b)"
      end

      split.execute("mutation { publish { id } }") # the same shape, one subgraph
      expect(split.trace.map { |fetch| fetch[:subgraph] }).to eq ["a"]
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
        "naming one of them."
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
    it "works out the subgraph map from what each schema defines" do
      auto = described_class.new(supergraph: RouterGraph::SUPERGRAPH)

      expect(auto.execute("{ me { username reviews { body } } }").dig("data", "me", "username"))
        .to eq "dpep"
      expect(auto.trace.map { |fetch| fetch[:subgraph] }).to eq ["accounts", "reviews"]
    end

    it "fills in the entries a partial map leaves out" do
      partial = described_class.new(
        supergraph: RouterGraph::SUPERGRAPH,
        subgraphs: { "reviews" => RouterGraph::Reviews::Schema },
      )

      expect(partial.execute("{ me { username } }").dig("data", "me", "username")).to eq "dpep"
    end

    # a swapped pair used to surface as a mystery three fetches later
    it "names what a mis-wired entry doesn't define" do
      expect {
        described_class.new(
          supergraph: RouterGraph::SUPERGRAPH,
          subgraphs: RouterGraph::SUBGRAPHS.merge("accounts" => RouterGraph::Products::Schema),
        )
      }.to raise_error(ArgumentError, /\Asubgraphs\["accounts"\] is RouterGraph::Products::Schema, which doesn't define .*Query\.me/)
    end

    it "names a subgraph the supergraph doesn't have" do
      expect {
        described_class.new(
          supergraph: RouterGraph::SUPERGRAPH,
          subgraphs: RouterGraph::SUBGRAPHS.merge("billing" => RouterGraph::Accounts::Schema),
        )
      }.to raise_error(ArgumentError, /names billing, which this supergraph doesn't have/)
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
