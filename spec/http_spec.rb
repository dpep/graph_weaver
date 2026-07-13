require "socket"
require_relative "generated/person_query"

# Generated modules run against a remote server by swapping the executor:
# same structs, same casting, HTTP transport.
describe GraphWeaver::Transport::HTTP do
  include_context "graphql http server"

  let(:executor) { described_class.new(url) }

  it "runs generated queries over HTTP" do
    person = PersonQuery.execute(id: "1", executor:).data!.person

    expect(person&.name).to eq "Daniel"
    expect(person&.birthday).to eq Date.new(1990, 6, 15)
    expect(person&.pets&.map(&:name)).to eq %w[Shelby Brownie]
  end

  it "reuses one connection across calls (keep-alive)" do
    expect(Net::HTTP).to receive(:start).once.and_call_original

    2.times do
      expect(PersonQuery.execute(id: "1", executor:).data!.person&.name).to eq "Daniel"
    end
  end

  it "drops a failed connection and reconnects on the next call" do
    PersonQuery.execute(id: "1", executor:)
    http = executor.instance_variable_get(:@http)
    expect(http).to receive(:request).and_raise(Errno::ECONNRESET)

    expect { PersonQuery.execute(id: "1", executor:) }
      .to raise_error(GraphWeaver::TransportError)
    expect(PersonQuery.execute(id: "1", executor:).data!.person&.name).to eq "Daniel"
  end

  it "raises ServerError on a non-2xx response (reached the server)" do
    bad = described_class.new("http://127.0.0.1:#{@port}/nope")

    expect { PersonQuery.execute(id: "1", executor: bad) }
      .to raise_error(GraphWeaver::ServerError) { |e| expect(e.status).to eq 404 }
  end

  it "raises TransportError when the connection never lands" do
    # grab a port, then free it so the connection is refused
    probe = TCPServer.new("127.0.0.1", 0)
    port = probe.addr[1]
    probe.close
    bad = described_class.new("http://127.0.0.1:#{port}/")

    expect { PersonQuery.execute(id: "1", executor: bad) }
      .to raise_error(GraphWeaver::TransportError)
  end

  it "reclassifies a user-registered exception (e.g. a pool error) as TransportError" do
    pool_error = Class.new(StandardError)
    GraphWeaver.register_transport_error(pool_error)
    allow(Net::HTTP).to receive(:start).and_raise(pool_error.new("pool exhausted"))

    expect { PersonQuery.execute(id: "1", executor:) }
      .to raise_error(GraphWeaver::TransportError, /pool exhausted/)
  ensure
    GraphWeaver.transport_errors.delete(pool_error)
  end

  it "classifies a non-JSON 200 body as ServerError (proxy pages, captive portals)" do
    html = Class.new(described_class) do
      def post(_body) = [200, "<html>Service Temporarily Unavailable</html>"]
    end

    expect { html.new(url).execute("query { x }") }
      .to raise_error(GraphWeaver::ServerError, /non-JSON response: <html>/)
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
