require "graph_weaver/faraday_executor"
require "graph_weaver/testing"


describe "GraphWeaver.connect" do
  # parsed WITHOUT executor:, so it follows GraphWeaver.executor — the
  # thing connect wires (generated fixtures bake Demo::Schema and would
  # never hit the network)
  let(:mod) do
    GraphWeaver.parse(schema: Demo::Schema, query: "query Who { person(id: 1) { name } }")
  end
  include_context "graphql http server"

  after { GraphWeaver.executor = nil }

  it "wires up transport + global executor in one call; retries are opt-in" do
    executor = GraphWeaver.connect(url)

    expect(executor).to be_a GraphWeaver::FaradayExecutor # no retry wrapper by default
    expect(GraphWeaver.executor).to equal executor
    expect(mod.execute!.person&.name).to eq "Daniel" # no executor: needed

    expect(GraphWeaver.connect(url, retries: true)).to be_a GraphWeaver::RetryExecutor
  end

  it "sends bearer auth, or a verbatim scheme, or custom headers" do
    GraphWeaver.connect(url, auth: "t0ken")
    mod.execute!
    expect(@requests.last[:headers]["authorization"]).to eq ["Bearer t0ken"]

    GraphWeaver.connect(url, auth: "Basic dXNlcg==")
    mod.execute!
    expect(@requests.last[:headers]["authorization"]).to eq ["Basic dXNlcg=="]

    GraphWeaver.connect(url, headers: { "X-Api-Key" => "k" })
    mod.execute!
    expect(@requests.last[:headers]["x-api-key"]).to eq ["k"]
  end

  it "prefers Faraday when loaded, with middleware pass-through" do
    executor = GraphWeaver.connect(url, retries: false) { |conn| conn.options.timeout = 3 }

    expect(executor).to be_a GraphWeaver::FaradayExecutor
  end

  it "falls back to the built-in transport without faraday, rejecting middleware" do
    hide_const("Faraday")

    expect(GraphWeaver.connect(url, retries: false)).to be_a GraphWeaver::HttpExecutor
    expect {
      GraphWeaver.connect(url) { |conn| conn }
    }.to raise_error(ArgumentError, /faraday/)
  end

  it "tunes retries with a Hash, or disables them" do
    slept = []
    # nothing listens on port 1: every attempt is a connection refusal
    GraphWeaver.connect("http://127.0.0.1:1/graphql", retries: { tries: 3, sleeper: ->(s) { slept << s } })

    expect { mod.execute! }.to raise_error(GraphWeaver::TransportError)
    expect(slept.size).to eq 2 # the Hash reached the RetryExecutor

    expect(GraphWeaver.connect(url, retries: false)).to be_a GraphWeaver::FaradayExecutor
  end
end
