require "webrick"
require_relative "../lib/http_executor"
require_relative "../lib/generated/person_query"

# Generated modules run against a remote server by swapping the executor:
# same structs, same casting, HTTP transport.
describe HttpExecutor do
  before(:all) do
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: [],
    )
    @server.mount_proc("/graphql") do |request, response|
      payload = JSON.parse(request.body)
      result = Demo::Schema.execute(payload["query"], variables: payload["variables"] || {})
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(result.to_h)
    end
    @thread = Thread.new { @server.start }
    @port = @server.listeners.first.addr[1]
  end

  after(:all) do
    @server.shutdown
    @thread.join
  end

  let(:executor) { described_class.new("http://127.0.0.1:#{@port}/graphql") }

  it "runs generated queries over HTTP" do
    result = PersonQuery.execute(id: "1", executor:)
    person = result.person

    expect(person&.name).to eq "Daniel"
    expect(person&.birthday).to eq Date.new(1990, 6, 15)
    expect(person&.pets&.map(&:name)).to eq %w[Shelby Brownie]
  end

  it "surfaces transport errors" do
    bad = described_class.new("http://127.0.0.1:#{@port}/nope")

    expect { PersonQuery.execute(id: "1", executor: bad) }.to raise_error(/HTTP 404/)
  end
end
