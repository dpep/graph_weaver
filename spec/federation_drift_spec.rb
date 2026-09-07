# typed: ignore — the fixture schemas are built from SDL, invisible to srb
# frozen_string_literal: true

require "rake"

require "graph_weaver/federation"
require "graph_weaver/testing"

# The supergraph you committed, read against the subgraph schemas running
# here — the question no other check asks: has someone changed a subgraph
# without recomposing?
describe GraphWeaver::Federation::Drift do
  let(:supergraph) { DriftGraph::SUPERGRAPH }

  def drift(*schemas, source: supergraph, subgraphs: nil)
    described_class.new(supergraph: source, subgraphs:, schemas:)
  end

  CLEAN = { "stale" => {}, "uncomposed" => {}, "skipped" => {}, "faked" => [] }.freeze

  it "reports clean when every local schema matches the supergraph" do
    result = drift(DriftGraph::Widgets, DriftGraph::Depots)

    expect(result.to_h).to eq CLEAN
    expect(result.drift?).to be false
    expect(result.checked).to eq %w[widgets depots]
    expect(result.report).to include "matches the schemas here (checked 2 of 2 subgraphs)"
  end

  # the supergraph still promises a field the subgraph dropped
  it "reports a field the supergraph carries that no local schema defines" do
    result = drift(DriftGraph::WidgetsStale, DriftGraph::Depots)

    expect(result.to_h["stale"]).to eq("Widget.weight" => ["widgets"])
    expect(result.drift?).to be true
    expect(result.report).to include "  Widget.weight (widgets)"
  end

  # a field with no @join__field lives wherever its type does — the
  # supergraph names no subgraph for it, and dropping one is still drift
  it "reports a dropped field the supergraph routes to nobody in particular" do
    result = drift(DriftGraph::WidgetsUnkeyed, DriftGraph::Depots)

    expect(result.to_h["stale"]).to eq("Widget.sku" => ["widgets"])
  end

  # the subgraph moved first; the supergraph doesn't know the field exists
  it "reports a field a local schema defines that the supergraph doesn't carry" do
    result = drift(DriftGraph::WidgetsAhead, DriftGraph::Depots)

    expect(result.to_h["uncomposed"]).to eq("Widget.dimensions" => ["DriftGraph::WidgetsAhead"])
    expect(result.drift?).to be true
    expect(result.report).to include "  Widget.dimensions (DriftGraph::WidgetsAhead)"
  end

  # a supergraph is routinely only partly local — saying nothing about the
  # rest is right, saying nothing *about saying nothing* would let a green
  # report pass for a complete one
  it "skips a subgraph that isn't in this process, and lists it" do
    result = drift(DriftGraph::Widgets)

    expect(result.to_h["skipped"]).to eq("depots" => ["Depot"])
    expect(result.checked).to eq ["widgets"]
    expect(result.drift?).to be false
    expect(result.report).to include "(checked 1 of 2 subgraphs)"
    expect(result.report).to include "  depots (Depot)"
  end

  # a faked subgraph is absent by choice rather than by accident, and the
  # report says so — there is still no real schema to compare against
  it "distinguishes a subgraph answered with fabricated data" do
    result = drift(DriftGraph::Widgets, subgraphs: { "depots" => GraphWeaver::Testing::Subgraphs::FAKE })

    expect(result.to_h).to eq CLEAN.merge("faked" => ["depots"])
    expect(result.report).to include "not checked — answered with fabricated data:\n  depots"
  end

  # a named schema is taken as given: detection is what drift breaks, so
  # the map is how you keep checking through it
  it "compares against a schema the caller names" do
    result = drift(subgraphs: { "widgets" => DriftGraph::WidgetsStale, "depots" => DriftGraph::Depots })

    expect(result.to_h["stale"]).to eq("Widget.weight" => ["widgets"])
    expect(result.checked).to eq %w[widgets depots]
  end

  it "refuses a subgraph name the supergraph doesn't have" do
    expect { drift(subgraphs: { "ledger" => DriftGraph::Depots }) }
      .to raise_error(ArgumentError, /names ledger, which this supergraph doesn't have/)
  end

  # federation plumbing (_entities/_service), @external copies and a field
  # that legitimately sits in two subgraphs are all NOT drift — the real
  # composed demo graph carries every one of them
  it "tolerates what a real subgraph carries beyond the supergraph" do
    result = drift(
      RouterGraph::Accounts::Schema, RouterGraph::Products::Schema, RouterGraph::Reviews::Schema,
      source: RouterGraph::SUPERGRAPH,
    )

    expect(result.to_h).to eq CLEAN
  end

  it "refuses a schema that carries no routing table" do
    expect { drift(source: "type Query { hi: String }") }
      .to raise_error(GraphWeaver::Error, /no routing table here/)
  end

  describe "rake graph_weaver:federation:diff" do
    def run_task(**env)
      original = Rake.application
      Rake.application = Rake::Application.new
      load "graph_weaver/tasks.rb"
      env.each { |name, value| ENV[name.to_s] = value }

      capture = StringIO.new
      begin
        $stdout = capture
        Rake::Task["graph_weaver:federation:diff"].invoke
      ensure
        $stdout = STDOUT
      end
      capture.string
    ensure
      env.each_key { |name| ENV.delete(name.to_s) }
      Rake.application = original
    end

    it "exits non-zero on drift, so CI can gate on it" do
      expect { run_task(SUPERGRAPH: DriftGraph::SUPERGRAPH) }
        .to raise_error(SystemExit)
        .and output(/the supergraph is out of date/).to_stderr
    end

    # absence is a supported setup, not a failure — the report names it and
    # the task still exits clean
    it "passes, saying what it couldn't see, when a subgraph runs elsewhere" do
      expect(run_task(SUPERGRAPH: UNREACHABLE))
        .to include("checked 0 of 1 subgraphs").and include("  ledger (LedgerEntry)")
    end

    # a graph whose only subgraph runs somewhere else: nothing to check,
    # and nothing that should fail a build
    UNREACHABLE = <<~SDL
      schema @link(url: "https://specs.apollo.dev/link/v1.0")
        @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
      { query: Query }
      directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT
      enum join__Graph { LEDGER @join__graph(name: "ledger", url: "http://ledger") }
      type Query @join__type(graph: LEDGER) { entries: [LedgerEntry!]! @join__field(graph: LEDGER) }
      type LedgerEntry @join__type(graph: LEDGER) { amount: Int! @join__field(graph: LEDGER) }
    SDL
  end
end
