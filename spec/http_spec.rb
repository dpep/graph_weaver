require "socket"
require_relative "generated/person_query"

# Generated modules run against a remote server by swapping the executor:
# same structs, same casting, HTTP transport.
describe GraphWeaver::HttpExecutor do
  include_context "graphql http server"

  let(:executor) { described_class.new(url) }

  it "runs generated queries over HTTP" do
    person = PersonQuery.execute(id: "1", executor:).data!.person

    expect(person&.name).to eq "Daniel"
    expect(person&.birthday).to eq Date.new(1990, 6, 15)
    expect(person&.pets&.map(&:name)).to eq %w[Shelby Brownie]
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
end
