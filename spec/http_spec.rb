require "socket"
require "tempfile"
require "webrick/https"
require_relative "generated/person_query"
require_relative "generated/search_query"

# Generated modules run against a remote server by swapping the client:
# same structs, same casting, HTTP transport.
describe GraphWeaver::Transport::HTTP do
  include_context "graphql http server"

  let(:executor) { described_class.new(url) }

  it "runs generated queries over HTTP" do
    person = PersonQuery.execute(client: executor, id: "1").data!.person

    expect(person&.name).to eq "Daniel"
    expect(person&.birthday).to eq Date.new(1990, 6, 15)
    expect(person&.pets&.map(&:name)).to eq %w[Shelby Brownie]
  end

  it "sends the graphql-over-http Accept header and an attributable User-Agent" do
    PersonQuery.execute(client: executor, id: "1")

    headers = @requests.last[:headers]
    expect(headers["content-type"]).to eq ["application/json"]
    expect(headers["accept"]).to eq ["application/graphql-response+json, application/json;q=0.9"]
    expect(headers["user-agent"]).to eq ["graph_weaver/#{GraphWeaver::VERSION}"]
  end

  it "sends an operation name for every generated query, named or not" do
    SearchQuery.execute(client: executor, term: "el")
    expect(JSON.parse(@requests.last[:body])["operationName"]).to eq "Search"

    # person.graphql declares an anonymous operation — the documented shape —
    # so the module names it after itself, in the document and on the wire.
    # Sending a name the document doesn't declare would be rejected.
    PersonQuery.execute(client: executor, id: "1")
    body = JSON.parse(@requests.last[:body])
    expect(body["operationName"]).to eq "PersonQuery"
    expect(body["query"]).to start_with "query PersonQuery($id: ID!)"
  end

  it "lets the caller override the defaults" do
    custom = described_class.new(url, headers: { "Accept" => "application/json", "User-Agent" => "myapp/1" })
    PersonQuery.execute(client: custom, id: "1")

    headers = @requests.last[:headers]
    expect(headers["accept"]).to eq ["application/json"]
    expect(headers["user-agent"]).to eq ["myapp/1"]
  end

  it "reuses one connection across calls (keep-alive)" do
    expect(Net::HTTP).to receive(:start).once.and_call_original

    2.times do
      expect(PersonQuery.execute(client: executor, id: "1").data!.person&.name).to eq "Daniel"
    end
  end

  it "drops a failed connection and reconnects on the next call" do
    PersonQuery.execute(client: executor, id: "1")
    http = executor.instance_variable_get(:@idle).last
    expect(http).to receive(:request).and_raise(Errno::ECONNRESET)

    expect { PersonQuery.execute(client: executor, id: "1") }
      .to raise_error(GraphWeaver::TransportError)
    expect(executor.instance_variable_get(:@idle)).to be_empty
    expect(PersonQuery.execute(client: executor, id: "1").data!.person&.name).to eq "Daniel"
  end

  # A fiber scheduler cancels an in-flight task with Async::Stop, which
  # descends from Exception rather than StandardError — so a bare rescue
  # walks past the cleanup and the socket stays open until GC.
  it "closes the socket when the request is cancelled by a non-StandardError" do
    cancel = Class.new(Exception)
    executor.execute(PersonQuery::QUERY, variables: { "id" => "1" })
    http = executor.instance_variable_get(:@idle).last
    expect(http).to receive(:request).and_raise(cancel)

    expect { executor.execute(PersonQuery::QUERY, variables: { "id" => "1" }) }
      .to raise_error(cancel)
    expect(http.started?).to be false
  end

  describe "connection pool" do
    # 4 threads, one call each, against a server that holds every request
    # open. Serialized behind one socket the calls can only queue; with
    # room in the pool they overlap — which is the whole point, and is
    # invisible to a correctness-only spec.
    def call_concurrently(transport, threads: 4)
      reset_inflight!
      Array.new(threads) { Thread.new { PersonQuery.execute(client: transport, id: "1") } }.each(&:join)
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
      expect { PersonQuery.execute(client: described_class.new(slow_url, read_timeout: 0.01), id: "1") }
        .to raise_error(GraphWeaver::TransportError, /Timeout/)
    end

    # a queued request looks exactly like a slow server from outside, so the
    # ceiling has to announce itself
    it "warns once when the pool is saturated" do
      io = StringIO.new
      GraphWeaver.logger = Logger.new(io, level: Logger::WARN)

      call_concurrently(serial, threads: 3)

      expect(io.string).to include("connection pool saturated")
      expect(io.string).to include("1 of 1 connections")
      expect(io.string.scan("connection pool saturated").size).to eq 1
    ensure
      GraphWeaver.logger = nil
    end

    it "sizes the pool from RAILS_MAX_THREADS" do
      expect(described_class.default_pool_size).to eq 5

      ENV["RAILS_MAX_THREADS"] = "16"
      expect(described_class.default_pool_size).to eq 16
      expect(described_class.new(url).instance_variable_get(:@pool_size)).to eq 16

      # garbage falls back rather than raising at boot
      ENV["RAILS_MAX_THREADS"] = "lots"
      expect(described_class.default_pool_size).to eq 5
    ensure
      ENV.delete("RAILS_MAX_THREADS")
    end

    it "rejects a pool that can't hold a connection" do
      expect { described_class.new(url, pool_size: 0) }.to raise_error(ArgumentError, /pool_size/)
    end
  end

  it "raises ServerError on a non-2xx response (reached the server)" do
    bad = described_class.new("http://127.0.0.1:#{@port}/nope")

    expect { PersonQuery.execute(client: bad, id: "1") }
      .to raise_error(GraphWeaver::ServerError) { |e| expect(e.status).to eq 404 }
  end

  it "carries the response headers on a ServerError" do
    throttled = described_class.new(throttled_url)

    expect { PersonQuery.execute(client: throttled, id: "1") }
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

    expect { PersonQuery.execute(client: bad, id: "1") }
      .to raise_error(GraphWeaver::TransportError)
  end

  # net/http's ignore_eof default hands back whatever arrived before the
  # socket died, so a half-sent body looks like a server that answered with
  # garbage — permanent, and not retried — rather than a dropped connection.
  it "raises TransportError when the connection dies mid-body" do
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      socket.readpartial(4096)
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nContent-Type: application/json\r\n\r\n{\"da")
      socket.close
    end
    truncated = described_class.new("http://127.0.0.1:#{server.addr[1]}/graphql")

    expect { truncated.execute("query { x }") }.to raise_error(GraphWeaver::TransportError)
  ensure
    thread&.join
    server&.close
  end

  it "reclassifies a user-registered exception (e.g. a pool error) as TransportError" do
    pool_error = Class.new(StandardError)
    GraphWeaver.register_transport_error(pool_error)
    allow(Net::HTTP).to receive(:start).and_raise(pool_error.new("pool exhausted"))

    expect { PersonQuery.execute(client: executor, id: "1") }
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
    expect(raw).to have_graphql_error(code: "GRAPHQL_VALIDATION_FAILED")

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

  # a self-signed https endpoint: the CA the client must be told to trust
  describe "TLS options" do
    before(:all) do
      @tls = WEBrick::HTTPServer.new(
        Port: 0,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: [],
        SSLEnable: true,
        SSLCertName: [["CN", "127.0.0.1"]],
      )
      @tls.mount_proc("/graphql") do |request, response|
        payload = JSON.parse(request.body)
        result = Demo::Schema.execute(payload["query"], variables: payload["variables"] || {})
        response["Content-Type"] = "application/json"
        response.body = JSON.generate(result.to_h)
      end
      @tls_thread = Thread.new { @tls.start }
      @ca = Tempfile.new(["ca", ".pem"])
      @ca.write(@tls.ssl_context.cert.to_pem)
      @ca.flush
      @tls_url = "https://127.0.0.1:#{@tls.listeners.first.addr[1]}/graphql"
    end

    after(:all) do
      @tls.shutdown
      @tls_thread.join
      @ca.close!
    end

    it "trusts a private CA given ca_file:" do
      transport = described_class.new(@tls_url, ca_file: @ca.path)

      expect(PersonQuery.execute(client: transport, id: "1").data!.person&.name).to eq "Daniel"
    end

    it "still verifies by default, and honours verify_mode:" do
      expect { PersonQuery.execute(client: described_class.new(@tls_url), id: "1") }
        .to raise_error(GraphWeaver::TransportError, /certificate verify failed/)

      unverified = described_class.new(@tls_url, verify_mode: OpenSSL::SSL::VERIFY_NONE)
      expect(PersonQuery.execute(client: unverified, id: "1").data!.person&.name).to eq "Daniel"
    end

    it "refuses TLS options on a plain http url rather than ignoring them" do
      expect { described_class.new(url, ca_file: @ca.path) }
        .to raise_error(ArgumentError, /https/)
    end
  end

  it "never leaks auth headers through inspect/to_s" do
    secretive = described_class.new(url, headers: { "Authorization" => "Bearer s3cret" })

    expect(secretive.inspect).not_to include("s3cret")
    expect(secretive.to_s).not_to include("s3cret")
    expect(secretive.inspect).to include(url)
  end

  # What goes on the wire and how long we wait for it are the two things a
  # reader checks docs/transports.md for, and it quotes them verbatim — the
  # timeouts in four places, each header value in full.
  it "sends and waits for what docs/transports.md says" do
    docs = File.read(File.expand_path("../docs/transports.md", __dir__))
    stated = GraphWeaver::Transport::DEFAULT_HEADERS.values +
      [GraphWeaver::Transport::DEFAULT_OPEN_TIMEOUT, GraphWeaver::Transport::DEFAULT_READ_TIMEOUT]

    # the User-Agent carries the version, which the doc writes as <version>
    expect(stated.reject { |value| docs.include?(value.to_s.sub(GraphWeaver::VERSION, "<version>")) })
      .to be_empty
  end
end
