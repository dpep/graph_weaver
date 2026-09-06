require "socket"
require_relative "generated/person_query"

# Generated modules run against a remote server by swapping the client:
# same structs, same casting, HTTP transport.
describe GraphWeaver::Transport::HTTP do
  include_context "graphql http server"

  let(:executor) { described_class.new(url) }

  it "runs generated queries over HTTP" do
    person = PersonQuery.execute(executor, id: "1").data!.person

    expect(person&.name).to eq "Daniel"
    expect(person&.birthday).to eq Date.new(1990, 6, 15)
    expect(person&.pets&.map(&:name)).to eq %w[Shelby Brownie]
  end

  it "sends the graphql-over-http Accept header and an attributable User-Agent" do
    PersonQuery.execute(executor, id: "1")

    headers = @requests.last[:headers]
    expect(headers["content-type"]).to eq ["application/json"]
    expect(headers["accept"]).to eq ["application/graphql-response+json, application/json;q=0.9"]
    expect(headers["user-agent"]).to eq ["graph_weaver/#{GraphWeaver::VERSION}"]
  end

  it "lets the caller override the defaults" do
    custom = described_class.new(url, headers: { "Accept" => "application/json", "User-Agent" => "myapp/1" })
    PersonQuery.execute(custom, id: "1")

    headers = @requests.last[:headers]
    expect(headers["accept"]).to eq ["application/json"]
    expect(headers["user-agent"]).to eq ["myapp/1"]
  end

  it "reuses one connection across calls (keep-alive)" do
    expect(Net::HTTP).to receive(:start).once.and_call_original

    2.times do
      expect(PersonQuery.execute(executor, id: "1").data!.person&.name).to eq "Daniel"
    end
  end

  it "drops a failed connection and reconnects on the next call" do
    PersonQuery.execute(executor, id: "1")
    http = executor.instance_variable_get(:@idle).last
    expect(http).to receive(:request).and_raise(Errno::ECONNRESET)

    expect { PersonQuery.execute(executor, id: "1") }
      .to raise_error(GraphWeaver::TransportError)
    expect(executor.instance_variable_get(:@idle)).to be_empty
    expect(PersonQuery.execute(executor, id: "1").data!.person&.name).to eq "Daniel"
  end

  describe "connection pool" do
    # 4 threads, one call each, against a server that holds every request
    # open. Serialized behind one socket the calls can only queue; with
    # room in the pool they overlap — which is the whole point, and is
    # invisible to a correctness-only spec.
    def call_concurrently(transport, threads: 4)
      reset_inflight!
      Array.new(threads) { Thread.new { PersonQuery.execute(transport, id: "1") } }.each(&:join)
    end

    let(:slow) { described_class.new(slow_url, pool_size: 4) }
    let(:serial) { described_class.new(slow_url, pool_size: 1) }

    it "overlaps requests up to pool_size" do
      call_concurrently(slow)
      expect(peak_inflight).to be > 1
    end

    it "serializes when pool_size is 1" do
      call_concurrently(serial)
      expect(peak_inflight).to eq 1
    end

    it "applies read_timeout: to a pooled socket" do
      expect { PersonQuery.execute(described_class.new(slow_url, read_timeout: 0.01), id: "1") }
        .to raise_error(GraphWeaver::TransportError, /Timeout/)
    end

    it "rejects a pool that can't hold a connection" do
      expect { described_class.new(url, pool_size: 0) }.to raise_error(ArgumentError, /pool_size/)
    end
  end

  it "raises ServerError on a non-2xx response (reached the server)" do
    bad = described_class.new("http://127.0.0.1:#{@port}/nope")

    expect { PersonQuery.execute(bad, id: "1") }
      .to raise_error(GraphWeaver::ServerError) { |e| expect(e.status).to eq 404 }
  end

  it "carries the response headers on a ServerError" do
    throttled = described_class.new(throttled_url)

    expect { PersonQuery.execute(throttled, id: "1") }
      .to raise_error(GraphWeaver::ServerError) { |e|
        expect(e.status).to eq 429
        expect(e.headers["x-ratelimit-remaining"]).to eq "0"
        expect(e.retry_after).to eq 7.0
        expect(e).to be_throttled
      }
  end

  it "raises TransportError when the connection never lands" do
    # grab a port, then free it so the connection is refused
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr[1]
    probe.close
    bad = described_class.new("http://127.0.0.1:#{port}/")

    expect { PersonQuery.execute(bad, id: "1") }
      .to raise_error(GraphWeaver::TransportError)
  end

  it "reclassifies a user-registered exception (e.g. a pool error) as TransportError" do
    pool_error = Class.new(StandardError)
    GraphWeaver.register_transport_error(pool_error)
    allow(Net::HTTP).to receive(:start).and_raise(pool_error.new("pool exhausted"))

    expect { PersonQuery.execute(executor, id: "1") }
      .to raise_error(GraphWeaver::TransportError, /pool exhausted/)
  ensure
    GraphWeaver.transport_errors.delete(pool_error)
  end

  it "classifies a non-JSON 200 body as ServerError (proxy pages, captive portals)" do
    html = Class.new(described_class) do
      def post(_body) = [200, "<html>Service Temporarily Unavailable</html>"]
    end

    expect { html.new(url).execute("query { x }") }
      .to raise_error(GraphWeaver::ServerError, /non-GraphQL response: <html>/)
  end

  it "lets a 4xx with a GraphQL errors body flow into the envelope (graphql-over-http routers)" do
    apollo_style = Class.new(described_class) do
      def post(_body) = [400, JSON.generate("errors" => [{ "message" => "unknown field", "extensions" => { "code" => "GRAPHQL_VALIDATION_FAILED" } }])]
    end

    raw = apollo_style.new(url).execute("query { nosuch }")
    expect(raw.dig("errors", 0, "extensions", "code")).to eq "GRAPHQL_VALIDATION_FAILED"

    # a 4xx WITHOUT GraphQL shape stays a ServerError
    html = Class.new(described_class) do
      def post(_body) = [502, "<html>Bad Gateway</html>"]
    end
    expect { html.new(url).execute("query { x }") }
      .to raise_error(GraphWeaver::ServerError) { |e| expect(e.status).to eq 502 }
  end

  it "wraps unserializable variables (NaN) instead of leaking JSON errors" do
    expect { executor.execute("query", variables: { "amount" => Float::NAN }) }
      .to raise_error(GraphWeaver::Error, /not JSON-serializable/)
  end

  it "never leaks auth headers through inspect/to_s" do
    secretive = described_class.new(url, headers: { "Authorization" => "Bearer s3cret" })

    expect(secretive.inspect).not_to include("s3cret")
    expect(secretive.to_s).not_to include("s3cret")
    expect(secretive.inspect).to include(url)
  end
end
