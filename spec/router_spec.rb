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

  def refusal_from(client, query, variables: {})
    client.execute(query, variables:)
    raise "expected #{query.inspect} to be refused"
  rescue Unplannable => e
    e
  end

  def refusal(query, variables: {}) = refusal_from(router, query, variables:)

  # Folding a same-type fragment into its parent drops the fragment node.
  # Its @skip/@include went with it, so a stitched plan answered a selection
  # the operation had excluded — and ran an extra fetch to do it.
  describe "@skip/@include on a fragment that crosses a boundary" do
    let(:spread) do
      <<~GQL
        query($s: Boolean!) { me { username ...R @include(if: $s) } }
        fragment R on User { reviews { body } }
      GQL
    end

    it "excludes the guarded selection, and doesn't fetch for it" do
      expect(router.execute(spread, variables: { "s" => false }))
        .to eq({ "data" => { "me" => { "username" => "dpep" } } })
      expect(router.trace.map { |fetch| fetch[:subgraph] }).to eq ["accounts"]
    end

    it "includes it when the condition says so" do
      result = router.execute(spread, variables: { "s" => true })
      expect(result.dig("data", "me", "reviews")).to be_an Array
      expect(router.trace.map { |fetch| fetch[:subgraph] }).to eq %w[accounts reviews]
    end

    it "honours @skip, an inline fragment, and a spread at the root" do
      skipped = <<~GQL
        query { me { username ...R @skip(if: true) } }
        fragment R on User { reviews { body } }
      GQL
      expect(router.execute(skipped)).to eq({ "data" => { "me" => { "username" => "dpep" } } })

      inline = "{ me { username ... on User @include(if: false) { reviews { body } } } }"
      expect(router.execute(inline)).to eq({ "data" => { "me" => { "username" => "dpep" } } })

      root = <<~GQL
        query { ...R @include(if: false) me { username } }
        fragment R on Query { topProducts(first: 1) { name } }
      GQL
      expect(router.execute(root)).to eq({ "data" => { "me" => { "username" => "dpep" } } })
    end

    it "refuses when the fragment and the field both carry the same directive" do
      clash = <<~GQL
        query($s: Boolean!) { me { username ...R @include(if: $s) } }
        fragment R on User { reviews @include(if: $s) { body } }
      GQL
      expect(refusal(clash, variables: { "s" => true }).category).to eq :conditional_fragment
    end
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

    # a @requires field set is supplied by the ROUTER: it fetches those
    # fields from the subgraph that holds them and hands them back in the
    # representation, which makes the plan a chain rather than one pass
    it "fetches a @requires field set before the field that needs it" do
      response = router.execute("{ reviews { id product { shippingEstimate } } }")

      expect(response.dig("data", "reviews").map { |r| r.dig("product", "shippingEstimate") })
        .to eq [50, 450, 25]
      # reviews for the reviews, products for price+weight, reviews again for
      # the estimate those feed
      expect(subgraphs).to eq ["reviews", "products", "reviews"]
      expect(router.trace[1][:variables].fetch("representations").first.keys)
        .to contain_exactly("upc", "__typename")
      expect(router.trace[2][:variables].fetch("representations").first.keys)
        .to contain_exactly("upc", "price", "weight", "__typename")
    end

    # the required fields don't exist, so nothing that needs them can resolve
    it "nulls a @requires field whose first fetch finds no entity" do
      expect(router.execute("{ orphanReviews { product { shippingEstimate } } }"))
        .to eq({ "data" => nil })
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

  # Serial execution is about the ROOTS: sharing a subgraph, they go over as
  # one document and it runs them in order. Stitching below a root is an
  # ordinary read afterwards and has no ordering to preserve.
  describe "a mutation" do
    let(:add) { 'mutation { addReview(upc: "p1", body: "Sturdy") { %s } }' }

    it "runs it in its own subgraph and stitches below the root" do
      response = router.execute(add % "body product { name } author { email }")

      expect(response.fetch("data")).to eq({
        "addReview" => {
          "body" => "Sturdy",
          "product" => { "name" => "Table" },
          "author" => { "email" => "ada@example.com" },
        },
      })
      expect(router.trace.map { |fetch| fetch[:subgraph] }).to eq %w[reviews products accounts]
    end

    it "hands it over verbatim when nothing below the root crosses" do
      expect(router.execute(add % "id body").fetch("data"))
        .to eq({ "addReview" => { "id" => "r99", "body" => "Sturdy" } })
      expect(router.trace.map { |fetch| fetch[:subgraph] }).to eq ["reviews"]
    end
  end

  describe "refusing" do
    it "refuses before any subgraph runs" do
      expect { router.execute("{ me { id: username reviews { body } } }") }.to raise_error(Unplannable)
      expect(router.trace).to be_empty
    end

    it "is a GraphWeaver::Error, so one rescue catches it" do
      expect { router.execute("{ me { id: username reviews { body } } }") }
        .to raise_error(GraphWeaver::Error)
      expect(refusal("{ me { id: username reviews { body } } }").to_h)
        .to include("category" => "shadowed_key")
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

    # a @requires the supergraph places nowhere is a graph nothing can serve,
    # so there is no fetch to chain
    it "names a @requires field no subgraph holds" do
      sdl = File.read(RouterGraph::SUPERGRAPH)
        .sub('price: Int! @join__field(graph: PRODUCTS) @join__field(graph: REVIEWS, external: true)',
          'price: Int! @join__field(graph: REVIEWS, external: true)')
      unplaced = described_class.new(supergraph: sdl, subgraphs: RouterGraph::SUBGRAPHS)

      expect { unplaced.execute("{ reviews { product { shippingEstimate } } }") }
        .to raise_error(Unplannable, /\AProduct\.shippingEstimate @requires "price", and the supergraph places Product\.price in no subgraph —/)
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
      }.to raise_error(GraphWeaver::ConfigurationError, /\Asubgraphs\["accounts"\] is RouterGraph::Products::Schema, which doesn't define .*Query\.me/)
    end

    it "names a subgraph the supergraph doesn't have" do
      expect {
        described_class.new(
          supergraph: RouterGraph::SUPERGRAPH,
          subgraphs: RouterGraph::SUBGRAPHS.merge("billing" => RouterGraph::Accounts::Schema),
        )
      }.to raise_error(GraphWeaver::ConfigurationError, /names billing, which this supergraph doesn't have/)
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

  # The migration shape: a supergraph composed from several services, only
  # some of which run in this process. The rest is served elsewhere, so it
  # can't be a construction error — the suite still has a graph to test
  # against, minus the fields nobody here can answer.
  describe "a supergraph only partly served here" do
    subject(:partial) { described_class.new(supergraph: RouterGraph::PARTIAL_SUPERGRAPH) }

    it "constructs, and says which subgraphs nothing serves" do
      expect(partial.absent).to eq ["shipping", "billing"]
      expect(partial.inspect).to eq '#<GraphWeaver::Testing::Router ' \
        'subgraphs=["accounts", "reviews"] absent=["shipping", "billing"]>'
    end

    it "answers a query that never reaches the absent subgraph" do
      response = partial.execute("{ me { username reviews { body } } }")

      expect(response.fetch("data")).to eq({
        "me" => { "username" => "dpep", "reviews" => [{ "body" => "Love it" }, { "body" => "Too expensive" }] },
      })
      expect(partial.trace.map { |fetch| fetch[:subgraph] }).to eq ["accounts", "reviews"]
    end

    it "refuses a root field the absent subgraph owns, before fetching anything" do
      error = refusal_from(partial, "{ shipments { carrier } }")

      expect(error.category).to eq :absent_subgraph
      expect(error.message).to eq 'Query.shipments resolves in "shipping", which no schema here ' \
        'serves — name it with subgraphs: { "shipping" => YourSchema }, or fake it with ' \
        'subgraphs: { "shipping" => :fake } — a query that never reaches an absent subgraph\'s ' \
        "fields still runs, so nothing else has to change. (Detection only sees loaded schemas " \
        "— an autoloaded one isn't loaded until something references it.)"
      expect(partial.trace).to be_empty
    end

    it "names the field that reached across the boundary into it" do
      error = refusal_from(partial, "{ reviews { body shipment { carrier } } }")

      expect(error.detail).to start_with 'Review.shipment resolves in "shipping"'
      expect(partial.trace).to be_empty
    end

    describe "with the fake opt-in" do
      subject(:partial) do
        described_class.new(supergraph: RouterGraph::PARTIAL_SUPERGRAPH, subgraphs: { "shipping" => :fake })
      end

      it "answers the absent subgraph's root field, and says the answer was fabricated" do
        response = partial.execute("{ shipments { carrier } }")

        expect(response.dig("data", "shipments")).to all(include("carrier" => a_kind_of(String)))
        expect(partial.trace).to contain_exactly(include(subgraph: "shipping", faked: true))
      end

      # an _entities fetch answers as the type its representation names — a
      # fake that picked a random union member would match nothing
      it "answers a stitched fetch into it, alongside the real subgraph's data" do
        response = partial.execute("{ reviews { body shipment { carrier } } }")

        expect(response.dig("data", "reviews", 0, "body")).to eq "Love it"
        expect(response.dig("data", "reviews", 0, "shipment", "carrier")).to be_a String
        expect(partial.trace.map { |fetch| [fetch[:subgraph], fetch[:faked]] })
          .to eq [["reviews", nil], ["shipping", true]]
      end

      it "warns on every faked fetch, since invented data passing quietly is the risk" do
        log = StringIO.new
        GraphWeaver.logger = Logger.new(log, level: Logger::WARN)
        partial.execute("{ shipments { carrier } }")

        expect(log.string).to include "router -> shipping"
        expect(log.string).to include "FAKED: fabricated data, not shipping's"
      ensure
        GraphWeaver.logger = nil
      end

      # per-subgraph is one vocabulary for both answers: this service is
      # faked, that one still isn't here
      it "still refuses the absent subgraph it wasn't asked to fake" do
        expect(partial.faked).to eq ["shipping"]
        expect(partial.absent).to eq ["billing"]
        expect(refusal_from(partial, "{ invoices { total } }").detail)
          .to start_with 'Query.invoices resolves in "billing"'
      end
    end

    # two candidates is a genuine mistake, and picking either would be a coin
    # flip — absence tolerance must not soften that
    it "still refuses a subgraph two loaded schemas fit" do
      expect { described_class.new(supergraph: SplitGraph::SUPERGRAPH) }
        .to raise_error(GraphWeaver::ConfigurationError, /2 loaded schemas define everything the supergraph says "b" resolves/)
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
