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

  it "counts what the router can plan, and where it lands" do
    expect(coverage.plannable).to eq 10
    expect(coverage.results.size).to eq 17
    expect(coverage.percent).to eq 59
    expect(coverage.report.lines.first).to eq "10/17 queries plannable locally (59%)\n"
    expect(coverage.report.lines[1]).to eq "  accounts 4, reviews 4, products 2\n"
  end

  # the reason column is the product: one construct or many decides whether
  # the full planner is worth building
  it "groups the refusals by what stopped them, largest first" do
    expect(coverage.refused.map(&:category).tally)
      .to eq({ crosses_subgraph: 5, requires: 1, root_fields_span: 1 })

    expect(coverage.report).to include "  crosses a subgraph boundary (5)"
    expect(coverage.report).to include "    dashboard.graphql", "User.reviews is resolved by reviews"
    expect(coverage.report.index("crosses a subgraph boundary"))
      .to be < coverage.report.index("@requires needs a fetch chain")
  end

  it "plans without any subgraph being loadable" do
    # nothing here names a subgraph schema — the supergraph is the whole input
    expect(coverage.results.map(&:subgraph).compact.uniq).to contain_exactly("accounts", "products", "reviews")
  end

  describe "a query set it can't read" do
    around do |example|
      Dir.mktmpdir { |dir| example.run(@dir = dir) }
    end

    def coverage_of(queries)
      queries.each { |name, source| File.write(File.join(@dir, name), source) }
      described_class.new(supergraph: RouterGraph::SUPERGRAPH, queries: @dir, fragments: [])
    end

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
