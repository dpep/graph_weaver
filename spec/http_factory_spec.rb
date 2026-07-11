require "graph_weaver/faraday_executor"

describe "GraphWeaver.http" do
  let(:url) { "http://example.com/graphql" }

  it "prefers Faraday when the app has it loaded" do
    executor = GraphWeaver.http(url, headers: { "X-Api" => "k" })

    expect(executor).to be_a GraphWeaver::FaradayExecutor
  end

  it "passes middleware blocks through to the Faraday connection" do
    customized = false
    GraphWeaver.http(url) { |_conn| customized = true }

    expect(customized).to be true
  end

  it "falls back to the zero-dependency executor without faraday" do
    hide_const("Faraday")

    expect(GraphWeaver.http(url)).to be_a GraphWeaver::HttpExecutor
  end

  it "rejects middleware blocks when faraday is unavailable" do
    hide_const("Faraday")

    expect {
      GraphWeaver.http(url) { |conn| conn }
    }.to raise_error(ArgumentError, /faraday/)
  end
end
