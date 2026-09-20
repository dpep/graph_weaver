# typed: ignore — the fixture schemas are built from SDL, invisible to srb
# frozen_string_literal: true

require "open3"
require "rake"

require "graph_weaver/federation"
require "graph_weaver/testing"

# The supergraph you committed, read against the subgraph schemas running
# here — the question no other check asks: has someone changed a subgraph
# without recomposing?
# An input object exposes its members as arguments, not fields, so a
# fields-only check reported every input field as missing — and a correct
# supergraph failed the CI gate it was supposed to pass.
describe "GraphWeaver::Internal::Schemas.defines? on an input object" do
  let(:schema) do
    input = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "TicketInput"
      argument :event_id, String, required: true
    end
    query = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      # an input type is reachable only through an argument
      field :book, String do
        argument :input, input, required: true
      end
    end
    Class.new(GraphQL::Schema) { query(query) }
  end

  it "finds an input field, and still refuses one that isn't there" do
    expect(GraphWeaver::Internal::Schemas.defines?(schema, "TicketInput.eventId")).to be true
    expect(GraphWeaver::Internal::Schemas.defines?(schema, "TicketInput.nope")).to be false
  end
end

describe GraphWeaver::Federation::Drift do
  let(:supergraph) { DriftGraph::SUPERGRAPH }

  def drift(*schemas, source: supergraph, subgraphs: nil)
    described_class.new(supergraph: source, subgraphs:, schemas:)
  end

  CLEAN = { "stale" => {}, "shape" => {}, "uncomposed" => {}, "skipped" => {}, "faked" => [] }.freeze

  it "reports clean when every local schema matches the supergraph" do
    result = drift(DriftGraph::Widgets, DriftGraph::Depots)

    expect(result.to_h).to eq CLEAN
    expect(result.drift?).to be false
    expect(result.checked).to eq %w[widgets depots]
    expect(result.report).to include "matches the schemas here, field for field and type for " \
      "type (checked 2 of 2 subgraphs)"
  end

  # The pass is the verdict that overclaims: a @key change and a same-name
  # collision both compose differently and report clean here, so the line
  # that says "matches" also says what "matches" covered.
  it "says what a clean report didn't compare, and doesn't repeat it over drift" do
    expect(drift(DriftGraph::Widgets, DriftGraph::Depots).report)
      .to include "not compared: @key", "without @shareable"
    expect(drift(DriftGraph::WidgetsAhead, DriftGraph::Depots).report).not_to include "not compared:"
  end

  # Both are ordinary subgraph evolutions that break the NEXT composition,
  # and the check is field-coordinate presence and type, so neither moves it.
  it "reports clean for a @key the supergraph doesn't have, and for a colliding field" do
    unkeyed = GraphQL::Schema.from_definition(<<~SDL)
      directive @key(fields: String!) repeatable on OBJECT
      type Query { widget(sku: String!): Widget }
      type Widget @key(fields: "name") { sku: String! name: String! weight: Int! }
    SDL
    expect(drift(unkeyed, DriftGraph::Depots).drift?).to be false

    # depots grows a Widget.name of its own — a coordinate the supergraph
    # already carries, from widgets, and neither copy is @shareable
    colliding = GraphQL::Schema.from_definition(<<~SDL)
      type Query { depot(id: ID!): Depot }
      type Depot { id: ID! location: String! }
      type Widget { sku: String! name: String! }
    SDL
    expect(drift(DriftGraph::Widgets, colliding).drift?).to be false
  end

  # `stale` asks the supergraph's side of this; every check here walks its
  # subgraph list, so a schema the composition no longer places was on the
  # only side nothing looked at.
  it "names a federated schema here that is no subgraph of this supergraph" do
    result = described_class.new(
      supergraph: RouterGraph::SUPERGRAPH,
      schemas: RouterGraph::SUBGRAPHS.values + [Chain::A::Schema],
    )

    expect(result.unplaced).to eq [Chain::A::Schema]
    expect(result.subgraphs).to eq %w[accounts products reviews]
    # not drift — Chain::A::Schema is in fact another supergraph's subgraph,
    # which is exactly what a retired one also looks like
    expect(result.drift?).to be false
  end

  # every subgraph serves Query._service, and that is the whole test: an
  # app's own API schema is not a subgraph that went missing
  it "counts only schemas that serve _service" do
    plain = Class.new(GraphQL::Schema) do
      query(Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :hi, String
      end)
    end

    expect(drift(DriftGraph::Widgets, DriftGraph::Depots, plain).unplaced).to be_empty
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

  # Every coordinate is still there, so a presence check called this a match
  # and CI passed on a supergraph that describes a graph nobody serves.
  it "reports a field both carry with a different type" do
    result = drift(DriftGraph::WidgetsRetyped, DriftGraph::Depots)

    expect(result.to_h["shape"]).to eq(
      "Widget.sku" => { "subgraphs" => ["widgets"], "supergraph" => "String!", "here" => ["ID!"] },
      "Widget.weight" => { "subgraphs" => ["widgets"], "supergraph" => "Int!", "here" => ["Float"] },
    )
    expect(result.to_h["stale"]).to be_empty
    expect(result.drift?).to be true
    expect(result.report).to include "2 shape"
    expect(result.report).to include "  Widget.weight (widgets): Int! in the supergraph, Float here"
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

    expect(result.to_h["skipped"]).to eq("depots" => ["Depot", "Query.depot", "Depot.id", "Depot.location"])
    expect(result.checked).to eq ["widgets"]
    expect(result.drift?).to be false
    # it checked something, so the clean verdict means something
    expect(result.vacuous?).to be false
    expect(result.report).to include "(checked 1 of 2 subgraphs)"
    expect(result.report).to include "  depots (Depot, Query.depot, Depot.id, Depot.location)"
  end

  # Every coordinate a subgraph resolves alone is a wall rather than a
  # report, so the evidence stops at the first few and a count.
  it "holds a long evidence list to its first few and a count" do
    result = drift(source: RouterGraph::SUPERGRAPH)

    expect(result.report)
      .to include "  accounts (Query.directory, Query.me, Query.user, Query.users, User.email and 1 more)"
  end

  # An entity two subgraphs extend says nothing about which of them a schema
  # is. Taking the shared type as evidence matched the absent subgraph to its
  # neighbour and reported the fields only the absent one resolves as stale —
  # a red CI gate, advising a recompose that would change nothing, on the
  # supported setup docs/federation.md calls "not here".
  it "calls a subgraph sharing its only type with a local one absent, not stale" do
    result = drift(DriftGraph::Roster, source: DriftGraph::SHARED_ENTITY)

    expect(result.to_h["stale"]).to be_empty
    expect(result.drift?).to be false
    expect(result.checked).to eq ["roster"]
    expect(result.to_h["skipped"]).to eq("shifts" => ["Crew.nextShift"])
    expect(result.report).to include "  shifts (Crew.nextShift)"
  end

  # a faked subgraph is absent by choice rather than by accident, and the
  # report says so — there is still no real schema to compare against
  it "distinguishes a subgraph answered with fabricated data" do
    result = drift(DriftGraph::Widgets, subgraphs: { "depots" => GraphWeaver::Internal::Subgraphs::FAKE })

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

  # Why naming it matters: detection unions every candidate that fits a
  # subgraph, so a console session that builds the CHANGED schema while the
  # unmodified class is still loaded asks about both at once and reports clean.
  it "clears a coordinate any candidate for the subgraph still declares" do
    result = drift(DriftGraph::Widgets, DriftGraph::WidgetsStale, DriftGraph::Depots)

    expect(result.to_h).to eq CLEAN
    expect(drift(subgraphs: { "widgets" => DriftGraph::WidgetsStale, "depots" => DriftGraph::Depots })
      .to_h["stale"]).to eq("Widget.weight" => ["widgets"])
  end

  # Drift never calls a resolver, so a subgraph published as SDL by a team that
  # doesn't write Ruby is a first-class citizen here — which is the whole answer
  # to "what does a non-Ruby subgraph look like to federation:diff".
  it "compares a resolver-less schema loaded from a subgraph's own SDL" do
    published = GraphWeaver::SchemaLoader.load(<<~SDL)
      type Query { widget(sku: String!): Widget }
      type Widget @key(fields: "sku") { sku: String! name: String! }
    SDL

    result = drift(DriftGraph::Depots, subgraphs: { "widgets" => published })

    expect(result.to_h["stale"]).to eq("Widget.weight" => ["widgets"])
  end

  it "refuses a subgraph name the supergraph doesn't have" do
    expect { drift(subgraphs: { "ledger" => DriftGraph::Depots }) }
      .to raise_error(GraphWeaver::ConfigurationError, /names ledger, which this supergraph doesn't have/)
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
      Rake.application = RakeHarness.application
      RakeHarness.application.tasks.each(&:reenable) # rake runs a task once per process otherwise
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

    # "checked 0 of N" attached to exit 0 is a gate that passes whatever the
    # subgraphs say. Absence of *some* subgraphs is a supported setup; a
    # comparison against none of them proved nothing.
    it "fails when it compared against nothing, rather than passing a check it never made" do
      expect { run_task(SUPERGRAPH: UNREACHABLE) }
        .to raise_error(SystemExit)
        .and output(/this checked nothing, so it proved nothing/).to_stderr
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

  # Drift asks which schema classes are loaded — the same question
  # Testing::Subgraphs asks, and used to own, so it reached for the harness
  # to get it. That dragged faker into `rake graph_weaver:federation:diff`.
  it "loads none of the test harness" do
    script = <<~RUBY
      require "graph_weaver/federation"
      puts defined?(Faker) ? "faker" : "no faker"
      puts $LOADED_FEATURES.grep(%r{graph_weaver/testing}).empty? ? "no harness" : "harness"
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script)

    expect(status).to be_success, out
    expect(out.lines.map(&:chomp)).to eq ["no faker", "no harness"]
  end
end
