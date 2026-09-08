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
      expect(router).to have_fetched_subgraphs "accounts"
    end

    it "includes it when the condition says so" do
      result = router.execute(spread, variables: { "s" => true })
      expect(result.dig("data", "me", "reviews")).to be_an Array
      expect(router).to have_fetched_subgraphs "accounts", "reviews"
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
      expect { router.execute(clash, variables: { "s" => true }) }.to refuse_to_plan(:conditional_fragment)
    end
  end

  # a router is built once for the suite, so an example has to start from the
  # same place whether it runs alone or after two hundred others
  describe "#reset!" do
    it "restarts a faked subgraph's fabricated data" do
      faked = described_class.new(
        supergraph: RouterGraph::SUPERGRAPH,
        subgraphs: RouterGraph::SUBGRAPHS.merge("reviews" => :fake),
      )
      query = "{ me { username reviews { body } } }"

      first = faked.execute(query).dig("data", "me", "reviews", 0, "body")
      faked.reset!
      expect(faked.execute(query).dig("data", "me", "reviews", 0, "body")).to eq first
    end

    it "clears the trace, as reset_trace does" do
      router.execute("{ me { username } }")

      expect(router.reset!).to be router
      expect(router).not_to have_fetched_subgraphs
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
      expect(router).to have_fetched_subgraphs "accounts"

      router.execute("{ reviews { body } }")
      expect(router).to have_fetched_subgraphs "accounts", "reviews"
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
      expect(router).to have_fetched_subgraphs "reviews"
    end

    it "runs a mutation-free document's __typename against whichever subgraph runs it" do
      expect(router.execute("{ __typename me { username } }").fetch("data"))
        .to eq({ "__typename" => "Query", "me" => { "username" => "dpep" } })
    end
  end

  # A service object under test runs more than one query, and "which
  # subgraphs did this code path touch" is the assertion the trace exists
  # for — so it accumulates, and the reset is explicit.
  describe "#trace" do
    it "accumulates across executes until it is reset" do
      router.execute("{ me { username } }")
      router.execute("{ me { username reviews { body } } }")
      expect(router).to have_fetched_subgraphs "accounts", "accounts", "reviews"

      expect(router.reset_trace).to be router
      expect(router).not_to have_fetched_subgraphs
    end
  end

  describe "a query that crosses a subgraph boundary" do
    it "splits at the crossing and stitches the entity back" do
      response = router.execute("{ me { username reviews { id body } } }")

      expect(response.fetch("data")).to eq({
        "me" => {
          "username" => "dpep",
          "reviews" => [{ "id" => "r1", "body" => "Love it" }, { "id" => "r2", "body" => "Too expensive" }],
        },
      })
      expect(router).to have_fetched_subgraphs "accounts", "reviews"
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
      expect(router).to have_fetched_subgraphs "accounts", "reviews", "products"
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
      expect(router).to have_fetched_subgraphs "reviews", "products", "reviews"
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
      expect(router).to have_fetched_subgraphs "accounts", "products"
    end

    it "reads a @provides copy in place and fetches only the rest" do
      response = router.execute("{ reviews { author { username email } } }")

      expect(response.dig("data", "reviews", 0, "author"))
        .to eq({ "username" => "dpep", "email" => "pepper.daniel@gmail.com" })
      expect(router).to have_fetched_subgraphs "reviews", "accounts"
    end

    # a sub-document carries no fragment definitions, so a spread that reached
    # one names a fragment the subgraph has never seen
    it "spells a named fragment inline once it crosses a boundary" do
      query = <<~GQL
        query($h: Boolean!) { me { username reviews { author { ...ids } } } }
        fragment ids on User { id username @skip(if: $h) }
      GQL

      expect(router.execute(query, variables: { "h" => false }).fetch("data"))
        .to eq({
          "me" => {
            "username" => "dpep",
            "reviews" => [
              { "author" => { "id" => "1", "username" => "dpep" } },
              { "author" => { "id" => "1", "username" => "dpep" } },
            ],
          },
        })
      expect(router.trace.last[:query]).to include "... on User"
    end

    it "leaves a skipped stitched field absent rather than null" do
      query = "query($hide: Boolean!) { me { username reviews @skip(if: $hide) { body } } }"

      expect(router.execute(query, variables: { "hide" => true }).fetch("data"))
        .to eq({ "me" => { "username" => "dpep" } })
    end

    # the deferral is filtered by @skip; the prefetch feeding it has to be too,
    # or the router runs a resolver production never reaches
    it "skips the prefetch feeding a skipped @requires" do
      query = "query($hide: Boolean!) { reviews { id product { crateSize @skip(if: $hide) } } }"

      expect(router.execute(query, variables: { "hide" => true }).dig("data", "reviews", 0))
        .to eq({ "id" => "r1", "product" => {} })
      expect(router).to have_fetched_subgraphs "reviews"
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

    # A field set is a selection set, so a nested one crosses as an object
    # rather than as one field per dotted path. What has to be right is the
    # representation's SHAPE: spec/integration/router_parity_spec.rb diffs
    # every one of these against a real gateway.
    describe "a nested field set" do
      # Listing is keyed "upc store { id }" in both subgraphs
      it "sends a @key that is part flat and part nested" do
        response = router.execute("{ listings { name shelfCode } }")

        expect(response.dig("data", "listings").map { |l| l["shelfCode"] })
          .to eq %w[p1/s1 p2/s2 p3/online]
        expect(router.trace.last[:variables].fetch("representations")).to eq [
          { "upc" => "p1", "store" => { "id" => "s1" }, "__typename" => "Listing" },
          { "upc" => "p2", "store" => { "id" => "s2" }, "__typename" => "Listing" },
          # l3 has no store: the inner object is null, which is a
          # representation a real router sends too
          { "upc" => "p3", "store" => nil, "__typename" => "Listing" },
        ]
      end

      # Product.crateSize @requires "weight dimensions { length width unit
      # { code } }" — flat, nested, and nested again, in one field set
      it "carries a @requires nested two levels deep in one representation" do
        response = router.execute("{ topProducts(first: 1) { crateSize } }")

        expect(response.dig("data", "topProducts", 0, "crateSize")).to eq "60x30cm@100"
        expect(router.trace.last[:variables].fetch("representations")).to eq [{
          "upc" => "p1", "weight" => 100,
          "dimensions" => { "length" => 60, "width" => 30, "unit" => { "code" => "cm" } },
          "__typename" => "Product",
        }]
      end

      # the subgraph in hand holds none of the field set, so it is fetched
      # from the one that does and handed back in the representation
      it "prefetches a nested @requires from the subgraph that holds it" do
        response = router.execute("{ reviews { product { crateSize } } }")

        expect(response.dig("data", "reviews").map { |r| r.dig("product", "crateSize") })
          .to eq ["60x30cm@100", "84x36cm@900", "20x20cm@50"]
        expect(router).to have_fetched_subgraphs "reviews", "products", "reviews"
      end

      it "leaves no injected object in the answer" do
        response = router.execute("{ listings { name store { name } shelfCode } }")

        expect(response.dig("data", "listings", 0))
          .to eq({ "name" => "Table, Downtown", "store" => { "name" => "Downtown" }, "shelfCode" => "p1/s1" })
      end

      # Apollo injects a field set under its own names, so an alias over the
      # object a nested key arrives in is the same collision a flat one has
      it "refuses an alias shadowing the object an injected key arrives in" do
        expect { router.execute("{ listings { store: name shelfCode } }") }
          .to refuse_to_plan(:shadowed_key).with_detail(
            'Listing.shelfCode is fetched on Listing\'s "upc", "store", and this selection ' \
            'aliases name as "store" over it',
          )
      end
    end
  end

  # A representation names ONE concrete __typename, and which one an object
  # has isn't in the query — so the plan carries a branch per possible type
  # and execution picks by the __typename that came back.
  describe "an abstract type at a subgraph boundary" do
    it "buckets the objects by __typename and fetches each bucket's own entity" do
      response = router.execute(<<~GQL)
        { search(term: "all") { __typename ... on User { username } ... on Product { name } } }
      GQL

      expect(response.fetch("data").fetch("search")).to eq [
        { "__typename" => "User", "username" => "dpep" },
        { "__typename" => "Product", "name" => "Table" },
        { "__typename" => "Review" },
        { "__typename" => "Announcement" },
      ]
      expect(router).to have_fetched_subgraphs "reviews", "products", "accounts"
      expect(router.trace[1][:variables])
        .to eq({ "representations" => [{ "upc" => "p1", "__typename" => "Product" }] })
    end

    # the __typename rides under the router's own response key, so the answer
    # gains one only when the caller asked for it
    it "asks for the __typename it buckets on, and doesn't hand it back" do
      response = router.execute('{ search(term: "all") { ... on Product { name } } }')

      expect(router.trace.first[:query]).to include "_gw___typename: __typename"
      expect(response.fetch("data").fetch("search"))
        .to eq [{}, { "name" => "Table" }, {}, {}]
    end

    it "crosses from inside a subtree that already crossed" do
      response = router.execute("{ me { reviews { subject { ... on Product { name } } } } }")

      expect(response.dig("data", "me", "reviews", 0, "subject")).to eq({ "name" => "Table" })
      expect(router).to have_fetched_subgraphs "accounts", "reviews", "products"
    end

    # an interface's own fields resolve for every implementation; only the
    # per-implementation ones decide where a branch goes
    it "splits an interface's implementations and leaves the local one alone" do
      response = router.execute(<<~GQL)
        { purchasables { upc ... on Product { reviews { body } } ... on Bundle { items { name } } } }
      GQL

      expect(response.fetch("data").fetch("purchasables")).to eq [
        { "upc" => "p1", "reviews" => [{ "body" => "Love it" }] },
        { "upc" => "p4", "reviews" => [] },
        { "upc" => "b1", "items" => [{ "name" => "Table" }, { "name" => "Chair" }] },
      ]
      expect(router).to have_fetched_subgraphs "products", "reviews"
    end

    it "sends no entity fetch for a bucket nothing lands in" do
      expect(router.execute('{ search(term: "users") { ... on Product { name } } }'))
        .to eq({ "data" => { "search" => [{}, {}] } })
      expect(router).to have_fetched_subgraphs "reviews"
    end

    # one branch's entity fetch comes back null where the composed schema
    # says String!, and the null has to bubble the way it would in production
    it "propagates a null out of one branch's entity fetch" do
      expect(router.execute('{ search(term: "gone") { ... on Product { name } } }'))
        .to eq({ "data" => nil })
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
      expect(router).to have_fetched_subgraphs "reviews", "products", "accounts"
    end

    it "hands it over verbatim when nothing below the root crosses" do
      expect(router.execute(add % "id body").fetch("data"))
        .to eq({ "addReview" => { "id" => "r99", "body" => "Sturdy" } })
      expect(router).to have_fetched_subgraphs "reviews"
    end
  end

  describe "refusing" do
    it "refuses before any subgraph runs" do
      expect { router.execute("{ me { id: username reviews { body } } }") }
        .to refuse_to_plan(:shadowed_key)
      expect(router).not_to have_fetched_subgraphs
    end

    # the umbrella and the machine side, plus the shape every refusal
    # message has: what stopped this query, then what to do about it
    it "is a GraphWeaver::Error, so one rescue catches it" do
      expect { router.execute("{ me { id: username reviews { body } } }") }
        .to raise_error(GraphWeaver::Error) do |error|
          expect(error.to_h).to include("category" => "shadowed_key")
          expect(error.message).to eq "#{error.detail} — the local router injects the @key it " \
            "crosses on under a reserved response key and Apollo injects it under the field's " \
            "own name, so either way this alias claims a key the fetch needs. Rename the alias."
        end
    end

    # Apollo's router injects the @key under its own name and lets it win, so
    # this comes back as the user's id rather than their username. Matching
    # the router matters more than being right — and we can be neither.
    it "names the alias colliding with a @key the fetch needs" do
      expect { router.execute("{ me { id: username reviews { body } } }") }
        .to refuse_to_plan(:shadowed_key).with_detail(
          'User.reviews is fetched on User\'s "id", and this selection aliases username as "id" over it',
        )
    end

    # The other half of the same collision: an alias spelling the reserved key
    # itself. The fetch strips that key, taking the caller's field with it —
    # and silently, since by then the two are one response key.
    it "names an alias spelling the response key a @key is carried under" do
      expect { router.execute("{ topProducts(first: 1) { _gw_weight: name shippingEstimate } }") }
        .to refuse_to_plan(:shadowed_key).with_detail(
          'Product crosses on a field set the router carries under "_gw_upc", "_gw_price", ' \
          '"_gw_weight", and this selection aliases name as "_gw_weight" over it',
        )
    end

    # Bucketing an abstract type needs the list of concrete types the subgraph
    # can answer with, and only @join__unionMember/@join__implements record it.
    # Without them the router would have to guess what a fetch may name.
    it "names an abstract type the supergraph doesn't break down" do
      sdl = File.read(RouterGraph::SUPERGRAPH)
        .gsub(/^  @join__unionMember\(graph: \w+, member: "\w+"\)\n/, "")
      opaque = described_class.new(supergraph: sdl, subgraphs: RouterGraph::SUBGRAPHS)

      expect { opaque.execute('{ search(term: "all") { ... on Product { name } } }') }
        .to refuse_to_plan(:abstract_boundary).with_detail(
          "Query.search returns SearchHit, and the supergraph doesn't record which concrete types " \
            "reviews answers it with (no @join__unionMember or @join__implements, and SearchHit " \
            "is in more than one subgraph)",
        )
    end

    # a keyless member is only unanswerable if something on it resolves
    # elsewhere, which composition can't produce — but a hand-built supergraph
    # can, and the refusal has to name the type rather than the abstract one
    it "names the union member it can't build a representation for" do
      keyless = described_class.new(supergraph: <<~SDL, subgraphs: { "a" => SplitGraph::A::Schema, "b" => :fake })
        schema @link(url: "https://specs.apollo.dev/link/v1.0")
          @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
        { query: Query }
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
        union Result @join__type(graph: A) @join__unionMember(graph: A, member: "Doc") = Doc
        type Doc @join__type(graph: A) @join__type(graph: B) {
          id: ID! @join__field(graph: A)
          note: String @join__field(graph: B)
        }
      SDL

      expect { keyless.execute("{ search { ... on Doc { note } } }") }
        .to refuse_to_plan(:no_key).with_detail("Doc.note resolves in b, and Doc has no resolvable @key there")
    end

    # A field set is a selection set, so a nested one crosses as one: the
    # fetch asks for the object, and the representation carries it back in
    # the shape the SDL spells. What is left to refuse is a set no single
    # subgraph can answer — and a refusal spells it the way the schema does,
    # since dotted paths are this library's parse of it and nothing a reader
    # can grep their own SDL for.
    describe "a nested field set" do
      subject(:nested) do
        described_class.new(supergraph: <<~SDL, subgraphs: { "a" => :fake, "b" => :fake, "c" => :fake })
          schema @link(url: "https://specs.apollo.dev/link/v1.0")
            @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
          { query: Query }
          directive @join__field(graph: join__Graph, requires: join__FieldSet) repeatable on FIELD_DEFINITION
          directive @join__graph(name: String!, url: String!) on ENUM_VALUE
          directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT
          scalar join__FieldSet
          enum join__Graph {
            A @join__graph(name: "a", url: "http://a")
            B @join__graph(name: "b", url: "http://b")
            C @join__graph(name: "c", url: "http://c")
          }
          type Query @join__type(graph: A) @join__type(graph: B) @join__type(graph: C) {
            shipments: [Shipment!]! @join__field(graph: A)
            listings: [Listing!]! @join__field(graph: A)
            parcels: [Parcel!]! @join__field(graph: A)
            vouchers: [Voucher!]! @join__field(graph: A)
            crates: [Crate!]! @join__field(graph: A)
          }
          type Shipment @join__type(graph: A, key: "id") @join__type(graph: B, key: "id") {
            id: ID!
            origin: Place! @join__field(graph: A)
            originZone: String! @join__field(graph: B, requires: "origin { lat lon }")
          }
          type Listing @join__type(graph: A, key: "id organization { id }")
            @join__type(graph: B, key: "id organization { id }") {
            id: ID!
            organization: Org! @join__field(graph: A)
            note: String @join__field(graph: B)
          }
          type Parcel @join__type(graph: A, key: "id") @join__type(graph: B, key: "id") {
            id: ID!
            box: Box! @join__field(graph: A)
            boxLabel: String! @join__field(graph: B, requires: "box { width depth }")
          }
          type Box @join__type(graph: A) @join__type(graph: C) {
            width: Int! @join__field(graph: A)
            depth: Int! @join__field(graph: C)
          }
          type Voucher @join__type(graph: A, key: "code")
            @join__type(graph: B, key: "id organization { id }") @join__type(graph: B, key: "code") {
            id: ID! @join__field(graph: B)
            organization: Org! @join__field(graph: B)
            code: String!
            label: String @join__field(graph: B)
          }
          type Crate @join__type(graph: A, key: "id lid { id }")
            @join__type(graph: B, key: "id lid { id }") {
            id: ID!
            lid: Lid!
            seal: String! @join__field(graph: B, requires: "lid { code }")
          }
          type Lid @join__type(graph: A) @join__type(graph: B) {
            id: ID!
            code: String! @join__field(graph: B)
          }
          type Place @join__type(graph: A) @join__type(graph: B) { lat: Float! lon: Float! }
          type Org @join__type(graph: A) @join__type(graph: B) { id: ID! }
        SDL
      end

      # the injected selection is nested, not a dotted alias no schema has
      it "asks for a nested @requires as one object and hands it back nested" do
        nested.execute("{ shipments { originZone } }")

        expect(nested.trace.first[:query]).to match(/_gw_origin: origin \{\s+lat\s+lon\s+\}/)
        expect(nested.trace.last[:variables]["representations"].first).to match(
          "__typename" => "Shipment", "id" => anything,
          "origin" => { "lat" => anything, "lon" => anything },
        )
      end

      it "crosses a boundary on a @key that is part flat and part nested" do
        nested.execute("{ listings { note } }")

        expect(nested.trace.last[:variables]["representations"].first)
          .to match("__typename" => "Listing", "id" => anything, "organization" => { "id" => anything })
      end

      # One rule, stated once: the first @key the source subgraph can supply.
      # b keys Voucher on "id organization { id }" and on "code", and a holds
      # neither id nor organization — so the nested one isn't a candidate.
      it "takes the first @key the fetching subgraph can supply" do
        nested.execute("{ vouchers { label } }")

        expect(nested.trace.last[:variables]["representations"].first)
          .to match("__typename" => "Voucher", "code" => anything)
      end

      # the injected keys are the router's own bookkeeping, nested or not
      it "leaves no injected selection in the answer" do
        response = nested.execute("{ listings { note } shipments { originZone } }")

        expect(response.dig("data", "listings").flat_map(&:keys).uniq).to eq %w[note]
        expect(response.dig("data", "shipments").flat_map(&:keys).uniq).to eq %w[originZone]
      end

      # a representation is built from ONE fetch, so a nested set answered a
      # level at a time is answered by nobody — and that is a different
      # refusal from a @requires naming another @requires field
      it "refuses a nested field set no one subgraph holds whole" do
        expect { nested.execute("{ parcels { boxLabel } }") }
          .to refuse_to_plan(:nested_field_set).with_detail(
            'Parcel.boxLabel @requires a nested field set ("box { depth }") no one subgraph ' \
            "holds whole (Parcel.box in a, Box.depth in c)",
          )
      end

      # Crate is keyed on "id lid { id }" and its seal @requires "lid { code }",
      # which only b holds — so `lid` would arrive twice, each fetch knowing
      # half of it and overwriting the other
      it "refuses a nested object two fetches would each half-build" do
        expect { nested.execute("{ crates { seal } }") }
          .to refuse_to_plan(:nested_field_set).with_detail(
            'Crate\'s "lid" is part of a field set this fetch would have to build from more than ' \
            "one subgraph (lid.id from a, lid.code from b)",
          )
      end
    end

    # One @interfaceObject used to cost you the whole supergraph — the router
    # refused at construction, so a corpus had to be split into two graphs
    # over a directive most of its queries never reached.
    describe "an @interfaceObject" do
      subject(:media) do
        described_class.new(supergraph: <<~SDL, subgraphs: { "a" => :fake, "b" => :fake })
          schema @link(url: "https://specs.apollo.dev/link/v1.0")
            @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
          { query: Query }
          directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
          directive @join__graph(name: String!, url: String!) on ENUM_VALUE
          directive @join__implements(graph: join__Graph!, interface: String!) repeatable on OBJECT | INTERFACE
          directive @join__type(graph: join__Graph!, key: join__FieldSet, isInterfaceObject: Boolean) repeatable on OBJECT | INTERFACE
          scalar join__FieldSet
          enum join__Graph {
            A @join__graph(name: "a", url: "http://a")
            B @join__graph(name: "b", url: "http://b")
          }
          type Query @join__type(graph: A) @join__type(graph: B) {
            media: Media @join__field(graph: A)
            books: [Book!]! @join__field(graph: A)
          }
          interface Media @join__type(graph: A, key: "id")
            @join__type(graph: B, key: "id", isInterfaceObject: true) {
            id: ID!
            rating: Float
          }
          type Book implements Media @join__type(graph: A, key: "id")
            @join__implements(graph: A, interface: "Media") {
            id: ID!
            rating: Float
            title: String!
          }
        SDL
      end

      it "refuses only the queries that reach it" do
        expect { media.execute("{ media { id } }") }
          .to refuse_to_plan(:interface_object).with_detail(
            "Query.media returns Media, which b resolves as an @interfaceObject",
          )
      end

      it "plans everything else, and the router builds at all" do
        expect(media.execute("{ books { title } }").dig("data", "books")).to be_an Array
        expect(media).to have_fetched_subgraphs "a"
      end
    end

    # a @requires the supergraph places nowhere is a graph nothing can serve,
    # so there is no fetch to chain
    it "names a @requires field no subgraph holds" do
      sdl = File.read(RouterGraph::SUPERGRAPH)
        .sub('price: Int! @join__field(graph: PRODUCTS) @join__field(graph: REVIEWS, external: true)',
          'price: Int! @join__field(graph: REVIEWS, external: true)')
      unplaced = described_class.new(supergraph: sdl, subgraphs: RouterGraph::SUBGRAPHS)

      expect { unplaced.execute("{ reviews { product { shippingEstimate } } }") }
        .to refuse_to_plan(:no_owner).with_detail(
          'Product.shippingEstimate @requires "price", and the supergraph places Product.price in no subgraph',
        )
    end

    # a union split across subgraphs, a mutation whose roots are, and a
    # subscription — none of them shapes the demo graph has
    let(:split) do
      described_class.new(supergraph: SplitGraph::SUPERGRAPH, subgraphs: SplitGraph::SUBGRAPHS)
    end

    # a's Result holds only Doc, so nothing search returns can be a Note and
    # the fragment never matches — which is what a real router answers too
    it "drops a fragment on a member the answering subgraph can't produce" do
      expect(split.execute("{ search { ... on Note { id } } }"))
        .to eq({ "data" => { "search" => [{}] } })
      expect(split).to have_fetched_subgraphs "a"

      split.reset_trace
      split.execute("{ search { ... on Doc { id } } }") # the same shape, one subgraph
      expect(split).to have_fetched_subgraphs "a"
    end

    it "refuses a subscription" do
      expect { split.execute("subscription { ticks }") }
        .to refuse_to_plan(:operation_type).with_detail("this document is a subscription")
    end

    # query roots resolve independently, so the router just fetches each in
    # its own subgraph; mutation roots run in series, and splitting them
    # would run them in whatever order the plan happened to
    it "refuses a mutation whose root fields span subgraphs" do
      expect { split.execute("mutation { publish { id } annotate { id } }") }
        .to refuse_to_plan(:root_fields_span).with_detail(
          "this mutation's root fields span subgraphs: Mutation.publish (a), Mutation.annotate (b)",
        )

      split.execute("mutation { publish { id } }") # the same shape, one subgraph
      expect(split).to have_fetched_subgraphs "a"
    end

    it "refuses introspection mixed with data fields" do
      expect { router.execute("{ __schema { queryType { name } } me { id } }") }
        .to refuse_to_plan(:mixed_introspection)
    end

    it "asks which operation when the document holds more than one" do
      document = "query A { me { username } } query B { me { email } }"

      expect { router.execute(document) }
        .to refuse_to_plan(:ambiguous_operation).with_detail("the document holds 2 operations (A, B)")
      expect(router.execute(document, operation_name: "B"))
        .to eq({ "data" => { "me" => { "email" => "pepper.daniel@gmail.com" } } })
    end
  end

  # The refusal boundary is the product, and docs/federation.md's table is
  # where a reader meets it — so a category added here has to land there.
  # (Two had drifted out of it before this existed.)
  it "documents every refusal category" do
    docs = File.read(File.expand_path("../docs/federation.md", __dir__)).delete("`")
    labels = Unplannable::CATEGORIES.each_value.map(&:first)

    expect(labels.reject { |label| docs.include?(label) }).to be_empty
  end

  describe "answering as a router does" do
    # a subgraph would answer with its own slice, and its own root type
    it "answers introspection from the composed API schema" do
      response = router.execute("{ __schema { types { name } } }")
      names = response.dig("data", "__schema", "types").map { |type| type["name"] }

      expect(names).to include "Product", "Review", "User"
      expect(names.grep(/join__|_Entity|_Any/)).to be_empty
      expect(router).not_to have_fetched_subgraphs
    end

    it "reports a query that no longer validates, without asking a subgraph" do
      response = router.execute("{ me { nosuch } }")

      expect(response["data"]).to be_nil
      expect(response).to have_graphql_error(code: "GRAPHQL_VALIDATION_FAILED")
      expect(router).not_to have_fetched_subgraphs
    end

    it "reports an unparseable query" do
      expect(router.execute("{ me {")).to have_graphql_error(code: "GRAPHQL_PARSE_FAILED")
    end
  end

  describe "construction" do
    it "works out the subgraph map from what each schema defines" do
      auto = described_class.new(supergraph: RouterGraph::SUPERGRAPH)

      expect(auto.execute("{ me { username reviews { body } } }").dig("data", "me", "username"))
        .to eq "dpep"
      expect(auto).to have_fetched_subgraphs "accounts", "reviews"
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
      expect(partial).to have_fetched_subgraphs "accounts", "reviews"
    end

    it "refuses a root field the absent subgraph owns, before fetching anything" do
      # the cause first (the class isn't loaded), then the surface an rspec
      # example can actually reach — there's no Router.new in one
      expect { partial.execute("{ shipments { carrier } }") }
        .to refuse_to_plan(:absent_subgraph).with_detail(
          'Query.shipments resolves in "shipping", which no schema here serves — nothing loaded ' \
            'defines what the supergraph says "shipping" resolves. Rails autoloads, so the class ' \
            "is probably just not loaded yet: eager-load it (config.eager_load, or " \
            "config.rake_eager_load under rake). If it runs elsewhere, fabricate its answers " \
            'instead — subgraphs: { "shipping" => :fake } (GraphWeaver::Testing.config.router = ' \
            "{ subgraphs: … } under the rspec tag, or subgraphs: on Router.new) — or a schema " \
            "class in place of :fake.",
        )
      expect(partial).not_to have_fetched_subgraphs
    end

    # Eager loading on means the autoload guess is wrong, and the library can
    # ask rather than lead with it — the subgraph genuinely runs elsewhere.
    it "drops the autoload guess when eager loading is already on" do
      config = Struct.new(:eager_load, :rake_eager_load).new(true, false)
      stub_const("Rails", Module.new.tap { |mod|
        mod.define_singleton_method(:application) { Struct.new(:config).new(config) }
      })

      expect { partial.execute("{ shipments { carrier } }") }
        .to refuse_to_plan(:absent_subgraph).with_detail(
          a_string_including("Eager loading is on, so it isn't a class waiting to be autoloaded " \
            "— it runs elsewhere. Fabricate its answers: subgraphs: { \"shipping\" => :fake }"),
        )
    end

    it "names the field that reached across the boundary into it" do
      expect { partial.execute("{ reviews { body shipment { carrier } } }") }
        .to refuse_to_plan(:absent_subgraph)
        .with_detail(a_string_starting_with('Review.shipment resolves in "shipping"'))
      expect(partial).not_to have_fetched_subgraphs
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
        expect { partial.execute("{ invoices { total } }") }
          .to refuse_to_plan(:absent_subgraph)
          .with_detail(a_string_starting_with('Query.invoices resolves in "billing"'))
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
      expect(router).to have_fetched_subgraphs "products"
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
