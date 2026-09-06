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
  def coverage_of(queries)
    Dir.mktmpdir do |dir|
      queries.each { |name, source| File.write(File.join(dir, name), source) }
      return described_class.new(supergraph: RouterGraph::SUPERGRAPH, queries: dir, fragments: [])
    end
  end

  it "counts what the router can plan, and where it lands" do
    expect(coverage.plannable).to eq 16
    expect(coverage.results.size).to eq 17
    expect(coverage.percent).to eq 94
    expect(coverage.report.lines.first).to eq "16/17 queries plannable locally (94%)\n"
    # a query that stitches names every subgraph it touches
    expect(coverage.report.lines[1]).to eq "  accounts 4, reviews 4, accounts+reviews 2, " \
      "products 2, products+reviews 2, accounts+products 1, accounts+products+reviews 1\n"
  end

  # the reason column is the product: which construct is left decides
  # whether closing the rest of the gap is worth it
  it "says what stopped the rest" do
    expect(coverage.refused.map(&:category).tally).to eq({ requires: 1 })

    expect(coverage.report).to include "  @requires needs a fetch chain (1)"
    expect(coverage.report)
      .to include "    reviewed_product_shipping.graphql", 'Product.shippingEstimate runs in reviews'
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

  it "groups the refusals by what stopped them, largest first" do
    report = coverage_of(
      "shadowed.graphql" => "{ me { id: username reviews { body } } }",
      "aliased.graphql" => "{ me { id: username reviews { id } } }",
      "chained.graphql" => "{ reviews { product { shippingEstimate } } }",
    )

    expect(report.refused.map(&:category).tally).to eq({ shadowed_key: 2, requires: 1 })
    expect(report.report).to include "  an alias shadowing an injected @key (2)"
    expect(report.report.index("an alias shadowing an injected @key"))
      .to be < report.report.index("@requires needs a fetch chain")
  end

  it "plans without any subgraph being loadable" do
    # nothing here names a subgraph schema — the supergraph is the whole input
    expect(coverage.results.filter_map(&:subgraph).flat_map { |where| where.split("+") }.uniq)
      .to contain_exactly("accounts", "products", "reviews")
  end

  describe "a query set it can't read" do
    it "reports a query that no longer validates, rather than crashing on it" do
      report = coverage_of("stale.graphql" => "{ me { nosuch } }", "ok.graphql" => "{ me { id } }")

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
