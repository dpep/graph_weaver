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
    "include on an injected key's own field" => ['query($show: Boolean!) { me { id @include(if: $show) reviews { body } } }', { "show" => false }],
    "entity list under an entity list" => ['{ users { username reviews { body product { name } } } }', {}],
    "same entity, two aliases" => ['{ a: me { username } b: me { email } }', {}],
    "same entity, two aliases, one stitching" => ['{ a: me { username } b: me { email reviews { body } } }', {}],
    "null hole" => ['{ user(id: "99") { username } }', {}],
    "null parent, so no representation" => ['{ user(id: "99") { username reviews { body } } }', {}],
    "typename everywhere" => ['{ __typename me { __typename username } }', {}],
    "introspection" => ["{ __schema { queryType { name } } }", {}],
    "duplicate field, merged" => ["{ reviews { body } reviews { id } }", {}],
    "duplicate stitched field, merged" => ["{ me { reviews { body } reviews { id } } }", {}],
    "one response key, two subplans" => ["{ reviews { product { name } product { upc } } }", {}],
    "variable in a nested selection" => ['query($upc: String!) { product(upc: $upc) { name } }', { "upc" => "p3" }],
    "variable used only inside a stitched subtree" => ['query($id: ID!) { review(id: $id) { body author { email } } }', { "id" => "r3" }],
    "@provides copy beside a field only the owner has" => ["{ reviews { author { username email } } }", {}],
    "an entity reached from two directions at once" => ["{ topProducts(first: 1) { name shippingEstimate reviews { body } } }", {}],
    "@requires fetched from a third subgraph first" => ["{ reviews { product { shippingEstimate } } }", {}],
    "a @requires chain beside a plain join" => ["{ reviews { id product { name shippingEstimate } } }", {}],
    "a @requires chain over an entity list" => ["{ users { reviews { product { name shippingEstimate reviews { body } } } } }", {}],
    "root fields split three ways" => ["{ me { username } topProducts(first: 1) { name } reviews { body } }", {}],
    # serial execution governs the ROOTS; what stitches below one is an
    # ordinary read, and the gateway is the proof of that
    "a mutation stitching below its root" => ['mutation { addReview(upc: "p1", body: "Sturdy") { body product { name } author { email } } }', {}],
  }.freeze

  # Probes where a subgraph *fails*. A stitched fetch can leave a null where
  # the composed schema says non-null, and what the router does with that —
  # null the whole subtree, and re-path the error out of `_entities` — is the
  # part a merge gets silently wrong. These are the ones that would answer
  # differently rather than not at all, so they're the point of the oracle.
  FAULTS = {
    "resolver error under a stitched fetch" => ["{ topProducts(first: 4) { name shippingEstimate } }", {}],
    "error re-pathed out of _entities" => ["{ topProducts(first: 4) { name reviews { body } shippingEstimate } }", {}],
    "entity fetch nulls a non-null field" => ["{ orphanReviews { body product { name price } } }", {}],
    "the null a whole response propagates to" => ["{ orphanReviews { product { name } } }", {}],
    "a @requires chain whose first fetch finds nothing" => ["{ orphanReviews { product { shippingEstimate } } }", {}],
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
      rescue StandardError => e
        # a planner that blows up is wrong, not refusing — report it as the
        # diff it is rather than ending the run
        return [:wrong, "gateway: #{JSON.generate(expected)}\n  local: #{e.class}: #{e.message}"]
      end

    return [:match, nil] if expected == actual

    [:wrong, "gateway: #{JSON.generate(expected)}\n  local: #{JSON.generate(actual)}"]
  end

  # yields [name, query, variables, clean] — clean meaning the gateway
  # answers it without errors, which every case but FAULTS does
  def each_case
    Dir[File.join(QUERY_DIR, "*.graphql")].sort.each do |path|
      name = File.basename(path)
      yield name, File.read(path), VARIABLES.fetch(name, {}), true
    end
    PROBES.each { |name, (query, variables)| yield name, query, variables, true }
    FAULTS.each { |name, (query, variables)| yield name, query, variables, false }
  end

  it "never answers differently from the router — it matches or it refuses" do
    tally = Hash.new(0)
    wrong = []
    refusals = []

    each_case do |name, query, variables, _clean|
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
    each_case do |name, query, variables, clean|
      next unless clean
      next unless compare(query, variables).first == :refused

      expect(via_gateway(query, variables)["errors"]).to be_nil, "#{name} fails on the gateway too"
    end
  end

  # The planner replaced a pass-through with a stitcher, and the one thing
  # that must not have cost anything is a query the pass-through answered.
  it "plans every query it planned before stitching, in one fetch" do
    each_case do |name, query, variables, _clean|
      next unless VERBATIM.include?(name)

      expect(compare(query, variables)).to eq([:match, nil]), name
      expect(router.trace.size).to eq(1), "#{name} now takes #{router.trace.size} fetches"
    end
  end

  # what the single-subgraph router planned, before the planner existed
  VERBATIM = %w[
    account_badge.graphql catalog.graphql feed.graphql product_detail.graphql profile.graphql
    recent_reviews.graphql review_bylines.graphql review_detail.graphql user_directory.graphql
    user_lookup.graphql
  ].freeze
end
