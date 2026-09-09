# typed: false
# frozen_string_literal: true

require "tmpdir"

# Probe doubles for the concurrency specs. Namespaced because a bare
# `class Socket` in a spec file reopens the one net/http already owns.
module ThreadProbe
  # Stands in for a Net::HTTP connection and reports when it is in use, so
  # the spec can catch one socket being handed to two threads at once.
  class Connection
    Response = Struct.new(:code, :body) do
      def each_header = [].each
    end

    def initialize(log, fail: false)
      @log = log
      @fail = fail
      @open = true
    end

    def request(_request)
      @log.enter(self)
      Thread.pass
      raise Errno::ECONNRESET if @fail

      Response.new("200", '{"data":{}}')
    ensure
      @log.leave(self)
    end

    def started? = @open
    def finish = @open = false
  end

  class Log
    attr_reader :sockets, :peak, :shared

    def initialize
      @lock = Mutex.new
      @sockets = []
      @live = []
      @peak = 0
      @shared = 0
    end

    def opened(socket) = @lock.synchronize { @sockets << socket }

    def enter(socket)
      @lock.synchronize do
        @shared += 1 if @live.include?(socket)
        @live << socket
        @peak = [@peak, @live.size].max
      end
    end

    def leave(socket) = @lock.synchronize { @live.delete_at(@live.index(socket)) }
  end
end

RSpec.describe "thread safety" do
  # Under Puma every request is a thread sharing one process. Almost all of
  # the request path is locals — client resolution, the request body, from_h —
  # and a custom scalar's cast is baked into the generated file rather than
  # looked up in a registry, so a `to_prepare` re-registration can't race a
  # request. The connection pool is the exception, so it gets the scrutiny.
  describe GraphWeaver::Transport::HTTP do
    def build(pool_size:, fail: false)
      log = ThreadProbe::Log.new
      transport = described_class.new("https://example.test/graphql", pool_size:)
      transport.define_singleton_method(:connect) do
        ThreadProbe::Connection.new(log, fail:).tap { |socket| log.opened(socket) }
      end
      [transport, log]
    end

    def permits(transport) = transport.instance_variable_get(:@permits).size
    def idle(transport) = transport.instance_variable_get(:@idle)

    # Failures are the point in most of these, so they're swallowed in the
    # thread rather than reported — the assertions read the pool, not the calls.
    def storm(transport, threads: 24)
      Array.new(threads) do
        Thread.new do
          transport.execute("query Q { x }")
        rescue Exception # rubocop:disable Lint/RescueException
          nil
        end
      end.each(&:join)
    end

    it "never hands one connection to two threads at once" do
      transport, log = build(pool_size: 4)
      storm(transport)

      expect(log.shared).to eq 0
      expect(log.peak).to be <= 4
      expect(log.sockets.size).to be <= 4
      expect(permits(transport)).to eq 4
    end

    it "returns the permit when the request fails" do
      transport, log = build(pool_size: 2, fail: true)
      storm(transport, threads: 10)

      expect(permits(transport)).to eq 2
      # a socket whose state is unknown is dropped, never pooled for reuse
      expect(idle(transport)).to be_empty
      expect(log.sockets.size).to eq 10
      expect(log.sockets).to all(satisfy { |socket| !socket.started? })
    end

    # rescue Exception, not StandardError: a fiber scheduler cancels with
    # Async::Stop, and Timeout/Rack::Timeout raise their own non-StandardError
    # — an interrupted request must still give the permit back.
    it "returns the permit when the request is interrupted, not merely failed" do
      transport, = build(pool_size: 2)
      cancel = Class.new(Exception) # rubocop:disable Lint/InheritException
      transport.define_singleton_method(:connect) { Object.new.tap { |o| o.define_singleton_method(:request) { |_| raise cancel } } }

      storm(transport, threads: 6)

      expect(permits(transport)).to eq 2
    end

    it "returns the permit when the connection can't be opened" do
      transport, = build(pool_size: 2)
      transport.define_singleton_method(:connect) { raise Errno::ECONNREFUSED }

      storm(transport, threads: 6)

      expect(permits(transport)).to eq 2
    end
  end

  describe ".atomic_write" do
    let(:path) { File.join(@dir, "schema.graphql") }

    around do |example|
      Dir.mktmpdir { |dir| (@dir = dir) && example.run }
    end

    it "replaces the file and leaves nothing behind" do
      GraphWeaver::Internal::Util.atomic_write(path, "type Query { a: Int }")
      GraphWeaver::Internal::Util.atomic_write(path, "type Query { b: Int }")

      expect(File.read(path)).to eq "type Query { b: Int }"
      expect(Dir.children(@dir)).to eq ["schema.graphql"]
    end

    it "leaves the previous file intact when the write fails" do
      GraphWeaver::Internal::Util.atomic_write(path, "type Query { a: Int }")
      allow(File).to receive(:write).and_raise(Errno::ENOSPC)

      expect { GraphWeaver::Internal::Util.atomic_write(path, "type Query { b: Int }") }.to raise_error(Errno::ENOSPC)
      expect(File.read(path)).to eq "type Query { a: Int }"
      expect(Dir.children(@dir)).to eq ["schema.graphql"]
    end
  end

  describe GraphWeaver::Client do
    # A cold Puma process serves its first requests concurrently, and the
    # schema is introspected lazily — over the network, and into a cache file
    # if one is configured.
    let(:counting) do
      Class.new do
        attr_reader :calls

        def initialize = @calls = 0
        def url = "https://example.test/graphql"

        def execute(query, variables: {}, operation_name: nil)
          @calls += 1
          sleep 0.01 # widen the window a real round trip would open anyway
          Demo::Schema.execute(query, variables:, operation_name:).to_h
        end
      end.new
    end

    it "introspects once when several threads reach the schema together" do
      client = GraphWeaver.new("https://example.test/graphql")
      client.instance_variable_set(:@transport, counting)

      schemas = Array.new(8) { Thread.new { client.schema } }.map(&:value)

      expect(counting.calls).to eq 1
      expect(schemas.uniq.size).to eq 1
    end
  end
end
