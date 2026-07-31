require "socket"
require "graph_weaver/transport/faraday"
require_relative "generated/person_query"

describe GraphWeaver::Transport::Faraday do
  include_context "graphql http server"

  it "builds a default connection from a url" do
    executor = described_class.new(url)
    result = PersonQuery.execute(executor, id: "1").data!

    expect(result.person&.name).to eq "Daniel"
    expect(result.person&.birthday).to eq Date.new(1990, 6, 15)
  end

  it "accepts an existing Faraday connection" do
    connection = Faraday.new(url:, headers: { "X-Client" => "custom" })
    executor = described_class.new(connection)

    expect(PersonQuery.execute(executor, id: "1").data!.person&.name).to eq "Daniel"
    expect(@requests.last[:headers]["x-client"]).to eq ["custom"]
  end

  it "lets callers add middleware while building" do
    executor = described_class.new(url) do |conn|
      conn.request :authorization, "Bearer", "t0ken"
    end

    PersonQuery.execute(executor, id: "1")
    expect(@requests.last[:headers]["authorization"]).to eq ["Bearer t0ken"]
  end

  it "raises ServerError on a non-2xx response" do
    executor = described_class.new("http://127.0.0.1:#{@port}/nope")

    expect { PersonQuery.execute(executor, id: "1") }
      .to raise_error(GraphWeaver::ServerError) { |e| expect(e.status).to eq 404 }
  end

  it "raises TransportError when the connection never lands" do
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr[1]
    probe.close
    executor = described_class.new("http://127.0.0.1:#{port}/")

    expect { PersonQuery.execute(executor, id: "1") }.to raise_error(GraphWeaver::TransportError)
  end

  it "rejects headers: with a prebuilt connection (they'd be silently ignored)" do
    conn = Faraday.new(url: "http://example.test/graphql")
    expect { GraphWeaver::Transport::Faraday.new(conn, headers: { "X-A" => "b" }) }
      .to raise_error(ArgumentError, /prebuilt/)
    expect { GraphWeaver::Transport::Faraday.new(conn) }.not_to raise_error # bare prebuilt is fine
  end
end
