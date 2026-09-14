require "open3"
require "socket"
require "graph_weaver/transport/faraday"
require_relative "generated/person_query"

# The docs show `GraphWeaver::Transport::Faraday.new(url) { |conn| … }` in an
# initializer, and without the autoload that is a NameError at boot: the file
# is opt-in and nothing in `require "graph_weaver"` pulls it. Opt-in has to
# stay true in the other direction too — the gem must not load faraday for
# everyone who doesn't name it.
describe "GraphWeaver::Transport::Faraday, unrequired" do
  def run(ruby)
    out, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", ruby)
    raise out unless status.success?

    out.lines.map(&:chomp)
  end

  it "resolves the constant on first mention, and not before" do
    expect(run(<<~RUBY)).to eq ["no faraday", "GraphWeaver::Transport::Faraday", "faraday"]
      require "graph_weaver"
      puts defined?(::Faraday) ? "faraday" : "no faraday"
      puts GraphWeaver::Transport::Faraday.name
      puts defined?(::Faraday) ? "faraday" : "no faraday"
    RUBY
  end
end

describe GraphWeaver::Transport::Faraday do
  include_context "graphql http server"

  it "builds a default connection from a url" do
    executor = described_class.new(url)
    result = PersonQuery.execute(client: executor, id: "1").data!

    expect(result.person&.name).to eq "Daniel"
    expect(result.person&.birthday).to eq Date.new(1990, 6, 15)
  end

  it "sends the graphql-over-http Accept header and an attributable User-Agent" do
    PersonQuery.execute(client: described_class.new(url), id: "1")

    headers = @requests.last[:headers]
    expect(headers["content-type"]).to eq ["application/json"]
    expect(headers["accept"]).to eq ["application/graphql-response+json, application/json;q=0.9"]
    expect(headers["user-agent"]).to eq ["graph_weaver/#{GraphWeaver::VERSION}"]
  end

  it "names itself to the graph, here as much as on Transport::HTTP" do
    PersonQuery.execute(client: described_class.new(url), id: "1")

    headers = @requests.last[:headers]
    expect(headers["apollographql-client-name"]).to eq ["graph_weaver"]
    expect(headers["apollographql-client-version"]).to eq [GraphWeaver::VERSION]
  end

  it "lets the caller override the defaults" do
    executor = described_class.new(url, headers: {
      "Accept" => "application/json", "User-Agent" => "myapp/1",
      "apollographql-client-name" => "checkout",
    })
    PersonQuery.execute(client: executor, id: "1")

    headers = @requests.last[:headers]
    expect(headers["accept"]).to eq ["application/json"]
    expect(headers["user-agent"]).to eq ["myapp/1"]
    expect(headers["apollographql-client-name"]).to eq ["checkout"]
  end

  it "fills in the defaults a prebuilt connection left blank" do
    executor = described_class.new(Faraday.new(url:, headers: { "User-Agent" => "mine/1" }))
    PersonQuery.execute(client: executor, id: "1")

    headers = @requests.last[:headers]
    expect(headers["user-agent"]).to eq ["mine/1"]
    expect(headers["accept"]).to eq ["application/graphql-response+json, application/json;q=0.9"]
  end

  it "defaults its timeouts to Transport::HTTP's, not net/http's 60s/60s" do
    options = described_class.new(url).instance_variable_get(:@connection).options

    expect(options.open_timeout).to eq 10
    expect(options.read_timeout).to eq 30
  end

  it "applies read_timeout: to the socket" do
    executor = described_class.new(slow_url, read_timeout: 0.01)

    expect { PersonQuery.execute(client: executor, id: "1") }
      .to raise_error(GraphWeaver::TransportError, /Timeout/)
  end

  it "accepts an existing Faraday connection" do
    connection = Faraday.new(url:, headers: { "X-Client" => "custom" })
    executor = described_class.new(connection)

    expect(PersonQuery.execute(client: executor, id: "1").data!.person&.name).to eq "Daniel"
    expect(@requests.last[:headers]["x-client"]).to eq ["custom"]
  end

  it "lets callers add middleware while building" do
    executor = described_class.new(url) do |conn|
      conn.request :authorization, "Bearer", "t0ken"
    end

    PersonQuery.execute(client: executor, id: "1")
    expect(@requests.last[:headers]["authorization"]).to eq ["Bearer t0ken"]
  end

  # Faraday stringifies a connection header as it is set, so a callable there
  # would go out as "#<Proc:0x…>" — it used to raise and send you to
  # middleware, which made a rotating token mean something different on each
  # transport. Resolved per request instead, the way Transport::HTTP does.
  it "resolves a callable header value on every request" do
    tokens = %w[one two].each
    rotating = described_class.new(url, headers: { "Authorization" => -> { "Bearer #{tokens.next}" } })

    2.times { PersonQuery.execute(client: rotating, id: "1") }

    expect(@requests.last(2).map { |r| r[:headers]["authorization"] })
      .to eq [["Bearer one"], ["Bearer two"]]
  end

  it "omits a header whose value resolves to nil" do
    anonymous = described_class.new(url, headers: { "Authorization" => -> {}, "X-Later" => -> { 7 } })
    PersonQuery.execute(client: anonymous, id: "1")

    expect(@requests.last[:headers]).not_to have_key "authorization"
    expect(@requests.last[:headers]["x-later"]).to eq ["7"]
  end

  it "raises ServerError on a non-2xx response" do
    executor = described_class.new("http://127.0.0.1:#{@port}/nope")

    expect { PersonQuery.execute(client: executor, id: "1") }
      .to raise_error(GraphWeaver::ServerError) { |e| expect(e.status).to eq 404 }
  end

  it "carries the response headers on a ServerError" do
    executor = described_class.new(throttled_url)

    expect { PersonQuery.execute(client: executor, id: "1") }
      .to raise_error(GraphWeaver::ServerError) { |e|
        expect(e.headers["x-ratelimit-remaining"]).to eq "0"
        expect(e.retry_after).to eq 7.0
      }
  end

  it "raises TransportError when the connection never lands" do
    executor = described_class.new("http://127.0.0.1:1/") # nothing listens

    expect { PersonQuery.execute(client: executor, id: "1") }.to raise_error(GraphWeaver::TransportError)
  end

  # Faraday moves a url's query into the connection's default params and
  # strips it from url_prefix, so #url named an endpoint no request goes to —
  # and #url is what `graphql: :wire` stubs and what the boot log prints
  it "reports the url it actually posts to, query string included" do
    request = Queue.new
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      request << socket.readpartial(4096).lines.first
      body = JSON.generate("data" => { "person" => nil })
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      socket.close
    end
    endpoint = "http://127.0.0.1:#{server.addr[1]}/graphql?apiKey=abc"
    executor = described_class.new(endpoint)

    expect(executor.url).to eq endpoint

    PersonQuery.execute(client: executor, id: "1")
    expect(request.pop).to start_with "POST /graphql?apiKey=abc "
  ensure
    thread&.kill # a failure above leaves it blocked in accept
    server&.close
  end

  # url-encoding a param is Faraday's job, not URI.encode_www_form's: an Array
  # ships as a[]=1&a[]=2 and a Hash as a[b]=c, so #url — the string `graphql: :wire`
  # keys its stub on — has to come out of the same encoder the request does
  it "reports Array and Hash connection params the way the wire carries them" do
    request = Queue.new
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      request << socket.readpartial(4096).lines.first
      body = JSON.generate("data" => { "person" => nil })
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      socket.close
    end
    connection = Faraday.new(url: "http://127.0.0.1:#{server.addr[1]}/graphql") do |conn|
      conn.params.update("fields" => %w[a b], "filter" => { "kind" => "dog" })
    end
    executor = described_class.new(connection)

    PersonQuery.execute(client: executor, id: "1")
    expect(executor.url).to end_with request.pop[%r{POST (\S+) }, 1]
  ensure
    thread&.kill # a failure above leaves it blocked in accept
    server&.close
  end

  # net/http calls #strip on a header value, so both transports raised a bare
  # NoMethodError naming neither graph_weaver nor the header
  it "sends a non-String header value as its to_s" do
    executor = described_class.new(url, headers: { "X-Tenant" => 42, "X-Mode" => :live })
    PersonQuery.execute(client: executor, id: "1")

    headers = @requests.last[:headers]
    expect(headers["x-tenant"]).to eq ["42"]
    expect(headers["x-mode"]).to eq ["live"]
  end

  # Faraday pre-fills its own User-Agent, so `||=` never fired and graph_weaver's
  # traffic attributed to Faraday. A connection that never chose one isn't
  # expressing a preference.
  it "replaces Faraday's stock User-Agent on a prebuilt connection" do
    executor = described_class.new(Faraday.new(url:))
    PersonQuery.execute(client: executor, id: "1")

    expect(@requests.last[:headers]["user-agent"]).to eq ["graph_weaver/#{GraphWeaver::VERSION}"]
  end

  it "rejects headers:/timeouts with a prebuilt connection (they'd be silently ignored)" do
    conn = Faraday.new(url: "http://example.test/graphql")
    expect { GraphWeaver::Transport::Faraday.new(conn, headers: { "X-A" => "b" }) }
      .to raise_error(ArgumentError, /prebuilt/)
    expect { GraphWeaver::Transport::Faraday.new(conn, read_timeout: 5) }
      .to raise_error(ArgumentError, /prebuilt/)
    expect { GraphWeaver::Transport::Faraday.new(conn) }.not_to raise_error # bare prebuilt is fine
  end
end
