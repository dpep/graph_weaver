require "json"
require "webrick"

# how long /slow holds a request open — the transport's concurrency is
# only observable while the server is holding requests, since the cost
# a pool removes is network wait, not CPU
SLOW_ENDPOINT_DELAY = 0.05

# boots a real GraphQL HTTP endpoint (backed by Demo::Schema) and records
# incoming requests for header/body assertions. /slow answers the same
# way but slowly, tracking the high-water mark of in-flight requests.
RSpec.shared_context "graphql http server" do
  before(:all) do
    @requests = []
    @server = WEBrick::HTTPServer.new(
      Port: 0,
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: [],
    )

    answer = lambda do |request, response|
      payload = JSON.parse(request.body)
      result = Demo::Schema.execute(
        payload["query"],
        variables: payload["variables"] || {},
        operation_name: payload["operationName"],
      )
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(result.to_h)
    end

    @server.mount_proc("/graphql") do |request, response|
      @requests << { headers: request.header.dup, body: request.body }
      answer.call(request, response)
    end

    @inflight = { current: 0, max: 0 }
    @inflight_lock = Mutex.new
    @server.mount_proc("/slow") do |request, response|
      @inflight_lock.synchronize do
        @inflight[:current] += 1
        @inflight[:max] = [@inflight[:max], @inflight[:current]].max
      end
      sleep SLOW_ENDPOINT_DELAY
      @inflight_lock.synchronize { @inflight[:current] -= 1 }
      answer.call(request, response)
    end

    # a rate-limiting API's 429: a Retry-After, and a body that isn't
    # GraphQL, so it raises rather than flowing into the envelope
    @server.mount_proc("/throttled") do |_request, response|
      response.status = 429
      response["Retry-After"] = "7"
      response["X-RateLimit-Remaining"] = "0"
      response.body = "Too Many Requests"
    end

    # Surface a boot failure here rather than as every request in this
    # file failing at once — a swallowed exception in the server thread
    # reads as a burst of unrelated flakes that won't reproduce.
    ready = Queue.new
    @server.config[:StartCallback] = -> { ready << :up }
    @thread = Thread.new { @server.start }
    @thread.abort_on_exception = true
    @port = @server.listeners.first.addr[1]

    raise "test HTTP server did not start within 5s" if ready.pop(timeout: 5).nil?
  end

  after(:all) do
    @server.shutdown
    @thread.join
  end

  let(:url) { "http://127.0.0.1:#{@port}/graphql" }
  let(:slow_url) { "http://127.0.0.1:#{@port}/slow" }
  let(:throttled_url) { "http://127.0.0.1:#{@port}/throttled" }

  # the most requests /slow ever had open at once, since the last reset
  def peak_inflight
    @inflight_lock.synchronize { @inflight[:max] }
  end

  # Let stragglers drain before zeroing the mark. A client that abandons a
  # /slow request (the read_timeout example) leaves the handler sleeping with
  # :current still raised, and it would otherwise count toward the next
  # example's peak — which only shows up under a random spec order.
  def reset_inflight!
    deadline = Time.now + (SLOW_ENDPOINT_DELAY * 10)
    sleep 0.005 while @inflight_lock.synchronize { @inflight[:current] }.positive? && Time.now < deadline
    @inflight_lock.synchronize { @inflight[:max] = 0 }
  end
end
