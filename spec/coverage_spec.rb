# typed: ignore — the subgraph classes are graphql-ruby DSL, invisible to srb
# frozen_string_literal: true

require "tmpdir"
require "graph_weaver/testing"

# How much of a query set the local router can plan. The number is the whole
# point of the tool, so the corpus is checked in and the number is asserted:
# spec/support/federation/queries is a hand-written stand-in for one app's
# query mix — screens, lookups, lists — against the demo graph.
describe GraphWeaver::Testing::Coverage do
  subject(:coverage) do
    described_class.new(
      supergraph: RouterGraph::SUPERGRAPH,
      queries: File.expand_path("support/federation/queries", __dir__),
      fragments: [],
    )
  end

  # everything is read in the constructor, so the directory can go
  def coverage_of(queries, supergraph: RouterGraph::SUPERGRAPH)
    Dir.mktmpdir do |dir|
      queries.each { |name, source| File.write(File.join(dir, name), source) }
      return described_class.new(supergraph:, queries: dir, fragments: [])
    end
  end

  it "counts what the router can plan, and where it lands" do
    expect(coverage.plannable).to eq 17
    expect(coverage.results.size).to eq 17
    expect(coverage.percent).to eq 100
    expect(coverage.servable).to eq 17
    expect(coverage.report.lines.first).to eq "17/17 queries plannable locally (100%), 17 servable here\n"
    # a query that stitches names every subgraph it touches
    expect(coverage.report.lines[1]).to eq "  accounts 4, reviews 4, products+reviews 3, " \
      "accounts+reviews 2, products 2, accounts+products 1, accounts+products+reviews 1"
    expect(coverage.refused).to be_empty
  end

  # docs/federation.md prints this exact run as the worked example for reading
  # a coverage report — the corpus is checked in, so the doc can be held to it
  # rather than kept in step by hand.
  it "prints what docs/federation.md shows" do
    docs = File.read(File.expand_path("../docs/federation.md", __dir__))

    expect(docs).to include(*coverage.report.lines.first(2).map(&:chomp))
  end

  # The planner replaced a pass-through with a stitcher, and what must not
  # have cost anything is a query the pass-through already answered: each of
  # these still resolves in the one subgraph it always did.
  it "still plans every query it planned before stitching, in one subgraph" do
    single = coverage.results.select { |result| result.subgraph && !result.subgraph.include?("+") }

    expect(single.map { |result| File.basename(result.path) }).to eq %w[
      account_badge.graphql catalog.graphql feed.graphql product_detail.graphql profile.graphql
      recent_reviews.graphql review_bylines.graphql review_detail.graphql user_directory.graphql
      user_lookup.graphql
    ]
  end

  # the reason column is the product: which construct is left decides
  # whether closing the rest of the gap is worth it
  it "groups the refusals by what stopped them, largest first" do
    report = coverage_of({
      "shadowed.graphql" => "{ me { id: username reviews { body } } }",
      "aliased.graphql" => "{ me { id: username reviews { id } } }",
      "mixed.graphql" => "{ __schema { queryType { name } } me { id } }",
    })

    expect(report.refused.map(&:category).tally).to eq({ shadowed_key: 2, mixed_introspection: 1 })
    expect(report.report).to include "  an alias shadowing an injected @key (2)"
    expect(report.report).to include "    shadowed.graphql", "aliases username"
    expect(report.report.index("an alias shadowing an injected @key"))
      .to be < report.report.index("introspection mixed with data")
  end

  # "Is it worth wiring up? Measure." is answered by what a suite can
  # actually *run*, and the partly-local graph the docs call the usual
  # migration shape is exactly where that differs from what plans.
  describe "a supergraph only partly served here" do
    subject(:partial) do
      coverage_of({
        "profile.graphql" => "{ me { username } }",
        "tracking.graphql" => "{ reviews { body shipment { carrier } } }",
      }, supergraph: RouterGraph::PARTIAL_SUPERGRAPH)
    end

    it "counts the plannable ones a suite can run, and names what the rest need" do
      expect(partial.plannable).to eq 2
      expect(partial.servable).to eq 1
      expect(partial.report.lines.first)
        .to eq "2/2 queries plannable locally (100%), 1 servable here\n"
      expect(partial.report).to include "tracking.graphql  shipping"
    end
  end

  # The SDL-alone CI run: nothing is loaded, so servability isn't a number
  # this can report — and saying so beats printing a zero that reads as a gap.
  it "says planning is all it counted when nothing here serves the graph" do
    alone = coverage_of({ "widgets.graphql" => "{ widgets { id } }" }, supergraph: <<~SDL)
      schema @link(url: "https://specs.apollo.dev/link/v1.0")
        @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
      { query: Query }
      directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT
      enum join__Graph { X @join__graph(name: "x", url: "http://x") }
      type Query @join__type(graph: X) { widgets: [Widget!]! @join__field(graph: X) }
      type Widget @join__type(graph: X) { id: ID! @join__field(graph: X) }
    SDL

    expect(alone.plannable).to eq 1
    expect(alone.report.lines.first).to eq "1/1 query plannable locally (100%)\n"
    expect(alone.report).to include "nothing here serves any of this supergraph's subgraphs (x), " \
      "so this counts planning only"
  end

  it "plans without any subgraph being loadable" do
    # nothing here names a subgraph schema — the supergraph is the whole input
    expect(coverage.results.filter_map(&:subgraph).flat_map { |where| where.split("+") }.uniq)
      .to contain_exactly("accounts", "products", "reviews")
  end

  describe "a query set it can't read" do
    it "reports a query that no longer validates, rather than crashing on it" do
      report = coverage_of({ "stale.graphql" => "{ me { nosuch } }", "ok.graphql" => "{ me { id } }" })

      expect(report.plannable).to eq 1
      expect(report.refused.first.category).to eq :invalid
      expect(report.report).to include "doesn't validate against the supergraph (1)"
      expect(report.report).to include "Field 'nosuch' doesn't exist on type 'User'"
    end

    it "says so when there are no queries" do
      expect(coverage_of({}).report).to eq "no queries found"
    end
  end

  # with the routing table incomplete, every number it would report is a guess
  it "refuses a supergraph whose federation constructs it doesn't read" do
    sdl = File.read(RouterGraph::SUPERGRAPH)
      .sub("type Announcement\n  @join__type(graph: REVIEWS)",
        "type Announcement\n  @join__type(graph: REVIEWS)\n  @join__directive(graphs: [REVIEWS], name: \"x\")")

    expect { described_class.new(supergraph: sdl, queries: [], fragments: []) }
      .to raise_error(GraphWeaver::Testing::Unplannable, /@join__directive/)
  end
end
