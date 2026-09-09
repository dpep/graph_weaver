# typed: ignore — the subgraph classes are graphql-ruby DSL, invisible to srb
# frozen_string_literal: true

require "rake"
require "tmpdir"

require "graph_weaver/testing"

# Which Ruby schema serves which subgraph, derived from what each one
# defines. The point is that a match is evidence rather than a guess — so
# what it does when the evidence isn't conclusive is the whole spec.
describe GraphWeaver::Testing::Subgraphs do
  let(:table) { GraphWeaver::SchemaLoader.routing_table(RouterGraph::SUPERGRAPH) }
  let(:split) { GraphWeaver::SchemaLoader.routing_table(SplitGraph::SUPERGRAPH) }

  it "derives the whole map from what each schema defines" do
    expect(described_class.resolve(table).served).to eq RouterGraph::SUBGRAPHS
  end

  it "judges a schema on the types and fields the supergraph says it resolves" do
    products = [
      "Bundle", "Dimensions", "Dimensions.length", "Dimensions.unit", "Dimensions.width",
      "Listing", "Listing.name", "Listing.sku", "Product", "Product.dimensions", "Product.name",
      "Product.price", "Product.weight", "Purchasable", "Query", "Query.listings", "Query.product",
      "Query.purchasables", "Query.topProducts", "Region", "Store", "Store.name", "Store.region",
      "Unit", "Unit.code",
    ]

    expect(described_class.expected(table, "products")).to eq products
    # accounts defines Query and nothing else products resolves
    expect(described_class.missing(table, "products", RouterGraph::Accounts::Schema))
      .to eq products - ["Query"]
  end

  # both fit the evidence, so it can't say which — but that isn't a fact
  # about any query, so it's reported rather than raised (see Router)
  it "reports a subgraph two schemas fit, naming both" do
    resolution = described_class.resolve(split)

    expect(resolution.served.keys).to eq ["a"]
    expect(resolution.ambiguous).to eq("b" => ["SplitGraph::B::Schema", "SplitGraph::Twin::Schema"])
  end

  # a dev reload leaves two class objects spelled the same, and the list
  # read as a bug in the message
  it "names each candidate once" do
    resolution = described_class.resolve(
      split, schemas: [SplitGraph::B::Schema, SplitGraph::B::Schema, SplitGraph::Twin::Schema],
    )

    expect(resolution.ambiguous["b"]).to eq ["SplitGraph::B::Schema", "SplitGraph::Twin::Schema"]
  end

  # a subgraph nothing here defines is served elsewhere — routine in a
  # migration, and not a reason to refuse a suite that never touches it
  it "leaves out a subgraph nothing defines rather than refusing" do
    expect(described_class.resolve(table, schemas: [RouterGraph::Accounts::Schema]).served)
      .to eq("accounts" => RouterGraph::Accounts::Schema)
  end

  it "takes :fake for a subgraph to answer with fabricated data" do
    expect(described_class.resolve(table, { "reviews" => :fake }).served)
      .to eq RouterGraph::SUBGRAPHS.merge("reviews" => :fake)
  end

  it "names the one symbol an entry takes" do
    expect { described_class.resolve(table, { "reviews" => :faked }) }
      .to raise_error(GraphWeaver::ConfigurationError, /is :faked — the only symbol an entry takes is :fake/)
  end

  it "names an entry the caller got wrong rather than letting it run" do
    expect {
      described_class.resolve(table, RouterGraph::SUBGRAPHS.merge("reviews" => RouterGraph::Accounts::Schema))
    }.to raise_error(GraphWeaver::ConfigurationError, /\Asubgraphs\["reviews"\] is RouterGraph::Accounts::Schema, which doesn't define Announcement/)
  end

  # graphql-ruby builds anonymous schemas from SDL — the router's own view of
  # the supergraph is one — and none of them is an app's subgraph
  it "only ever considers named schemas" do
    GraphQL::Schema.from_definition("type Query { hi: String }")

    expect(GraphWeaver::Schemas.loaded).to all(satisfy { |schema| schema.name })
    expect(GraphWeaver::Schemas.loaded).to include RouterGraph::Reviews::Schema
  end

  # the router derives the map itself; the task is for reading what detection
  # sees when it refuses, and for committing the map instead of deriving it
  describe "rake graph_weaver:federation:subgraphs" do
    # Shared with every other spec file that exercises these tasks (see
    # rake_tasks_spec's header comment on TASKS for why this must be a
    # single process-wide load rather than one per file).
    unless defined?(TASKS)
      TASKS = Rake::Application.new
      begin
        previous, Rake.application = Rake.application, TASKS
        require "graph_weaver/tasks"
      ensure
        Rake.application = previous
      end
    end

    def run_task(supergraph)
      original = Rake.application
      Rake.application = TASKS
      TASKS.tasks.each(&:reenable) # rake runs a task once per process otherwise
      ENV["SUPERGRAPH"] = supergraph

      capture = StringIO.new
      begin
        $stdout = capture
        Rake::Task["graph_weaver:federation:subgraphs"].invoke
      ensure
        $stdout = STDOUT
      end
      capture.string
    ensure
      ENV.delete("SUPERGRAPH")
      Rake.application = original
    end

    it "prints a paste-ready map, with the evidence for each match" do
      expect(run_task(RouterGraph::SUPERGRAPH)).to eq <<~MAP
        subgraphs: {
          "accounts" => RouterGraph::Accounts::Schema,  # matched: defines Query.directory, Query.me, Query.user
          "products" => RouterGraph::Products::Schema,  # matched: defines Dimensions.length, Dimensions.unit, Dimensions.width
          "reviews" => RouterGraph::Reviews::Schema,    # matched: defines Listing.shelfCode, Product.crateSize, Product.reviews
        }
      MAP
    end

    it "leaves a gap it can't settle, and says what it looked for" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "supergraph.graphql")
        File.write(path, UNKNOWN_SUBGRAPH)

        expect(run_task(path)).to include(
          %(  "ledger" => nil,  # no loaded schema defines Query.entries, Entry.amount, Query — fill this in),
        )
      end
    end

    UNKNOWN_SUBGRAPH = <<~SDL
      schema @link(url: "https://specs.apollo.dev/link/v1.0")
        @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
      { query: Query }
      directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT
      enum join__Graph { LEDGER @join__graph(name: "ledger", url: "http://ledger") }
      type Query @join__type(graph: LEDGER) { entries: [Entry!]! @join__field(graph: LEDGER) }
      type Entry @join__type(graph: LEDGER) { amount: Int! @join__field(graph: LEDGER) }
    SDL
  end
end
