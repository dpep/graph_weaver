# typed: ignore — exercises eval-defined constants
require "graph_weaver/testing"

# A module generated with `client:` — the one thing a `graphql:` tag couldn't
# reach. The baked constant sits above GraphWeaver.client, which is the slot
# the tag swapped, so the example ran against the real thing.
module BoundClient
  # records rather than calls anything: under a mode it must see nothing
  class Spy
    attr_reader :requests

    def initialize = @requests = []

    def execute(query, variables: {}, operation_name: nil)
      @requests << query
      { "data" => { "person" => { "id" => "1", "name" => "Ada", "birthday" => nil, "pets" => [] } } }
    end
  end

  SPY = Spy.new

  QUERY = <<~GRAPHQL
    query PersonQuery($id: ID!) { person(id: $id) { id name birthday pets { name } } }
  GRAPHQL
end

describe GraphWeaver::Internal::TestClients do
  # generated the way a checked-in file is — a baked DEFAULT_CLIENT naming a
  # constant, not the live object `parse(client:)` sets on the module itself
  let(:bound) do
    GraphWeaver::Codegen.parse(schema: Demo::Schema, query: BoundClient::QUERY,
      client: "BoundClient::SPY")
  end
  let(:fake) { GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema) }

  around do |example|
    prior = GraphWeaver.client
    example.run
  ensure
    described_class.reset!
    GraphWeaver.client = prior
    GraphWeaver.reset_graphs!
    BoundClient::SPY.requests.clear
  end

  it "runs a bound module against the mode's client, not the one baked in" do
    GraphWeaver.client = fake
    described_class.install(:fake)
    # what the rspec hook installs: the mode's own client for this app's one
    # graph, which is also what GraphWeaver.client then reads back as
    installed = described_class.standin(GraphWeaver.graphs.first)

    expect(bound.execute!(id: "1").person.name).to be_a String
    expect(BoundClient::SPY.requests).to be_empty
    expect(fake.requests).to be_empty
    expect(installed.requests.size).to eq 1
  end

  it "leaves the baked client alone with no mode installed" do
    GraphWeaver.client = fake

    bound.execute!(id: "1")
    expect(BoundClient::SPY.requests.size).to eq 1
    expect(fake.requests).to be_empty
  end

  it "leaves the baked client alone again after the example" do
    GraphWeaver.client = fake
    described_class.install(:fake)
    described_class.reset!

    bound.execute!(id: "1")
    expect(BoundClient::SPY.requests.size).to eq 1
  end

  # :wire is the one mode that takes no client slot — the transport you ship
  # running unchanged is the whole point, so it stubs the endpoint instead
  it "leaves every client where it is under :wire" do
    GraphWeaver.client = fake
    described_class.install(:wire)

    bound.execute!(id: "1")
    expect(BoundClient::SPY.requests.size).to eq 1
  end

  # a module's own `client =` is the example talking; the mode stands in for
  # what CODEGEN decided, not for what the example just said
  it "yields to a client the example set on the module" do
    GraphWeaver.client = fake
    described_class.install(:fake)
    bound.client = BoundClient::SPY

    bound.execute!(id: "1")
    expect(BoundClient::SPY.requests.size).to eq 1
  end

  it "refuses to guess which graph a module that doesn't say belongs to" do
    GraphWeaver.graph(:pets) { schema Demo::Schema }
    GraphWeaver.graph(:billing) { schema Demo::Schema }
    described_class.install(:fake)

    expect { bound.execute!(id: "1") }
      .to raise_error(GraphWeaver::Error, /which of this app's graphs.*:pets, :billing/m)
  end
end
