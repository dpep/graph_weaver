# typed: ignore — harness plumbing
# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
require "tmpdir"
require "webrick"

require "graph_weaver/testing"

# Ground truth for Testing::Router. Serve the three Ruby subgraphs over HTTP,
# boot a real @apollo/gateway on the SAME committed supergraph SDL, and diff
# every query in the corpus against the local router.
#
# There are three outcomes and only one of them is a defect:
#
#   match    — the local router answered exactly what the gateway answered
#   refused  — it declined to plan, loudly, before running anything
#   WRONG    — it answered, and differently. That is the failure this whole
#              design exists to make impossible: a test that passes on
#              semantics production doesn't have.
#
# Needs node + the harness deps (npm install in spec/support/federation, run
# automatically on first use). Part of `make integration`.
describe "Testing::Router parity with a real Apollo gateway", :integration do
  PARITY_HARNESS = File.expand_path("../support/federation", __dir__)
  QUERY_DIR = File.expand_path("../support/federation/queries", __dir__)

  # the variables the corpus's declared ones need; every other query takes none
  VARIABLES = {
    "catalog.graphql" => { "first" => 2 },
    "product_detail.graphql" => { "upc" => "p2" },
    "product_page.graphql" => { "upc" => "p1" },
    "review_detail.graphql" => { "id" => "r2" },
    "shipping_quotes.graphql" => { "first" => 3 },
    "user_lookup.graphql" => { "id" => "2" },
  }.freeze

  # shapes past the corpus: the ones that decide where the boundary falls
  PROBES = {
    "aliased key" => ['{ me { id: username reviews { body } } }', {}],
    "skip on a crossing field" => ['query($hide: Boolean!) { me { username reviews @skip(if: $hide) { body } } }', { "hide" => true }],
    "entity list under an entity list" => ['{ users { username reviews { body product { name } } } }', {}],
    "same entity, two aliases" => ['{ a: me { username } b: me { email } }', {}],
    "null hole" => ['{ user(id: "99") { username } }', {}],
    "typename everywhere" => ['{ __typename me { __typename username } }', {}],
    "introspection" => ["{ __schema { queryType { name } } }", {}],
    "duplicate field, merged" => ["{ reviews { body } reviews { id } }", {}],
    "variable in a nested selection" => ['query($upc: String!) { product(upc: $upc) { name } }', { "upc" => "p3" }],
  }.freeze

  before(:all) do
    unless Dir.exist?(File.join(PARITY_HARNESS, "node_modules"))
      system("npm", "install", "--silent", chdir: PARITY_HARNESS, exception: true)
    end

    @servers = {}
    urls = RouterGraph::SUBGRAPHS.to_h do |name, schema|
      server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
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
      Thread.new { server.start }
      @servers[name] = server

      [name, "http://127.0.0.1:#{server.listeners.first.addr[1]}/graphql"]
    end

    # the committed supergraph, with its placeholder subgraph urls pointed at
    # the servers we just started — the gateway routes over the same table
    sdl = File.read(RouterGraph::SUPERGRAPH)
    urls.each { |name, url| sdl = sdl.sub("http://localhost/#{name}", url) }
    @dir = Dir.mktmpdir("graph_weaver-parity")
    routed = File.join(@dir, "supergraph.graphql")
    File.write(routed, sdl)

    reader, writer = IO.pipe
    @gateway_pid = spawn(
      { "SUPERGRAPH" => routed }, "node", "gateway_static.mjs",
      chdir: PARITY_HARNESS, out: writer, err: File::NULL,
    )
    writer.close
    @gateway_url = JSON.parse(Timeout.timeout(60) { reader.gets }).fetch("url")
  end

  after(:all) do
    Process.kill("TERM", @gateway_pid) if @gateway_pid
    Process.wait(@gateway_pid) if @gateway_pid
    @servers&.each_value(&:shutdown)
    FileUtils.remove_entry(@dir) if @dir
  rescue Errno::ESRCH, Errno::ECHILD
    # already gone
  end

  let(:router) do
    GraphWeaver::Testing::Router.new(
      supergraph: RouterGraph::SUPERGRAPH,
      subgraphs: RouterGraph::SUBGRAPHS,
    )
  end

  def via_gateway(query, variables)
    response = Net::HTTP.post(
      URI(@gateway_url), JSON.generate({ query:, variables: }), "Content-Type" => "application/json"
    )
    JSON.parse(response.body)
  end

  # the gateway brands errors with its own extensions and locations; compare
  # what a client actually consumes
  def normalize(result)
    {
      "data" => result["data"],
      "errors" => Array(result["errors"]).map { |error| error.slice("message", "path") },
    }
  end

  # => [:match, nil] / [:refused, reason] / [:wrong, the diff]
  def compare(query, variables)
    expected = normalize(via_gateway(query, variables))
    actual =
      begin
        normalize(router.execute(query, variables:))
      rescue GraphWeaver::Testing::Unplannable => e
        return [:refused, e.detail]
      end

    return [:match, nil] if expected == actual

    [:wrong, "gateway: #{JSON.generate(expected)}\n  local: #{JSON.generate(actual)}"]
  end

  def each_case
    Dir[File.join(QUERY_DIR, "*.graphql")].sort.each do |path|
      name = File.basename(path)
      yield name, File.read(path), VARIABLES.fetch(name, {})
    end
    PROBES.each { |name, (query, variables)| yield name, query, variables }
  end

  it "never answers differently from the router — it matches or it refuses" do
    tally = Hash.new(0)
    wrong = []
    refusals = []

    each_case do |name, query, variables|
      verdict, detail = compare(query, variables)
      tally[verdict] += 1
      wrong << "#{name}\n  #{detail}" if verdict == :wrong
      refusals << "#{name} — #{detail}" if verdict == :refused
    end

    # printed either way: the refusal list is the measurement, not noise
    warn "\nrouter parity: #{tally[:match]} identical, #{tally[:refused]} refused, #{tally[:wrong]} wrong"
    refusals.each { |line| warn "  refused: #{line}" }

    expect(wrong).to be_empty
    expect(tally[:match]).to be > 0
  end

  it "refuses only queries the gateway can actually answer" do
    # a refusal has to be a capability gap, not a broken query — otherwise
    # the local router is hiding bugs rather than declining work
    each_case do |name, query, variables|
      next unless compare(query, variables).first == :refused

      expect(via_gateway(query, variables)["errors"]).to be_nil, "#{name} fails on the gateway too"
    end
  end
end
