# typed: ignore — modules are eval'd at runtime
require "json"
require "timeout"
require "webrick"

require_relative "../support/federation_subgraphs"

# The real thing, end to end: two Ruby federation subgraphs (USERS owns
# User, PETS extends it via entity resolution), a genuine Apollo gateway
# composing and routing over them (node, @apollo/gateway), and
# GraphWeaver as the client — introspection through the router, typed
# codegen, and a query whose fields the router must stitch from BOTH
# subgraphs.
#
# Needs node + the harness deps (npm install in spec/support/federation,
# run automatically on first use). Part of `make integration`.
describe "Apollo Federation, live", :integration do
  HARNESS = File.expand_path("../support/federation", __dir__)

  def mount_subgraph(server, schema)
    server.mount_proc("/graphql") do |request, response|
      payload = JSON.parse(request.body)
      result = schema.execute(
        payload["query"],
        variables: payload["variables"] || {},
        operation_name: payload["operationName"],
      )
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(result.to_h)
    end
  end

  before(:all) do
    @servers = [FederationDemo::Users::Schema, FederationDemo::Pets::Schema].map do |schema|
      server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
      mount_subgraph(server, schema)
      Thread.new { server.start }
      server
    end
    users_url, pets_url = @servers.map { |s| "http://127.0.0.1:#{s.listeners.first.addr[1]}/graphql" }

    system("npm", "install", "--silent", chdir: HARNESS, exception: true) unless Dir.exist?(File.join(HARNESS, "node_modules"))

    reader, writer = IO.pipe
    @gateway_pid = spawn(
      { "USERS_URL" => users_url, "PETS_URL" => pets_url },
      "node", "gateway.mjs",
      chdir: HARNESS, out: writer, err: File::NULL,
    )
    writer.close
    ready = Timeout.timeout(30) { reader.gets }
    @gateway_url = JSON.parse(ready).fetch("url")
  end

  after(:all) do
    Process.kill("TERM", @gateway_pid) if @gateway_pid
    Process.wait(@gateway_pid) if @gateway_pid
    @servers&.each(&:shutdown)
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  end

  it "introspects through the router and runs a cross-subgraph query, typed" do
    router = GraphWeaver.new(@gateway_url)

    # the router's API schema is clean — join__/link machinery stays internal
    expect(router.schema.types).to have_key "User"
    expect(router.schema.types.keys.grep(/join__|link__/)).to be_empty

    user_query = router.parse(<<~GRAPHQL)
      query($id: ID!) {
        user(id: $id) {
          id
          name      # resolved by the USERS subgraph
          petNames  # resolved by the PETS subgraph via entity resolution
        }
      }
    GRAPHQL

    user = user_query.execute!(id: "1").user
    expect(user&.name).to eq "Daniel"          # from USERS
    expect(user&.pet_names).to eq %w[Shelby Brownie] # from PETS — the router stitched
  end

  it "surfaces router-shaped errors" do
    router = GraphWeaver.new(@gateway_url)

    # unknown user: USERS returns null user; no stitch, no data drama
    response = router.execute("query($id: ID!) { user(id: $id) { name petNames } }", id: "999")
    expect(response.data!.user).to be_nil

    # a stale query hitting the ROUTER directly (raw transport — the
    # client's own validation would catch this before the wire) comes
    # back with Apollo's validation code, which schema_stale? recognizes
    raw = router.executor.execute("query { nosuch }", variables: {})
    error = GraphWeaver::GraphQLError.from_h(raw["errors"].first)
    expect(error.code).to eq "GRAPHQL_VALIDATION_FAILED"
    expect(error.validation?).to be true
  end
end
