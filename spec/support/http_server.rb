require "json"
require "webrick"

# boots a real GraphQL HTTP endpoint (backed by Demo::Schema) and records
# incoming requests for header/body assertions
RSpec.shared_context "graphql http server" do
  before(:all) do
    @requests = []
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: [],
    )
    @server.mount_proc("/graphql") do |request, response|
      @requests << { headers: request.header.dup, body: request.body }
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

  let(:url) { "http://127.0.0.1:#{@port}/graphql" }
end
