# typed: true
# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

require_relative "../transport"

module GraphWeaver
  class Transport
    # Minimal net/http transport — zero dependencies, loaded by default:
    #
    #      GraphWeaver::Transport::HTTP.new(url, headers: { ... }, read_timeout: 10)
    #
    # Timeouts surface as TransportError (retriable). Connections are
    # persistent (keep-alive) and pooled: up to pool_size: sockets, opened
    # lazily, reused warmest-first, and dropped on any failure so the next
    # call starts fresh. For a middleware ecosystem, use Transport::Faraday.
    class HTTP < Transport
      # net/http's own network-level failures (Errno/SocketError/IOError
      # are already seeded) — added to the shared, extensible
      # transport-error set.
      GraphWeaver.register_transport_error(Timeout::Error, OpenSSL::SSL::SSLError)

      def initialize(url, headers: {}, open_timeout: DEFAULT_OPEN_TIMEOUT,
        read_timeout: DEFAULT_READ_TIMEOUT, keep_alive_timeout: 2, pool_size: 5)
        raise ArgumentError, "pool_size: must be >= 1" unless pool_size >= 1

        @url = url
        @uri = URI(url)
        @headers = headers
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @keep_alive_timeout = keep_alive_timeout

        # One permit per allowed socket: holding a permit is the right to
        # hold a connection, so at most pool_size requests are in flight
        # and the rest queue rather than opening unbounded sockets.
        @permits = SizedQueue.new(pool_size)
        pool_size.times { @permits.push(true) }

        # live connections, LIFO — a warm socket beats opening a cold one,
        # so a single-threaded caller keeps reusing the same one
        @idle = []
        @idle_lock = Mutex.new
      end

      private

      sig { override.params(body: String).returns([Integer, T.untyped]) }
      def post(body)
        request = Net::HTTP::Post.new(@uri, DEFAULT_HEADERS.merge(@headers))
        request.body = body

        response = with_connection { |http| http.request(request) }

        [response.code.to_i, response.body]
      end

      # Lease a connection for one round trip. The permit is held across
      # the whole trip — opening the socket included — so pool_size really
      # is the concurrency ceiling.
      def with_connection
        @permits.pop
        http = nil

        begin
          http = @idle_lock.synchronize { @idle.pop } || connect
          result = yield http
          @idle_lock.synchronize { @idle.push(http) }
          result
        rescue
          # socket state is unknown — drop it, leaving the slot empty so
          # the next call starts fresh (retry policy belongs to Retry)
          disconnect(http)
          raise
        ensure
          @permits.push(true)
        end
      end

      # A fresh persistent connection. net/http proactively reconnects
      # when idle past keep_alive_timeout, so a server-closed keep-alive
      # socket doesn't produce spurious failures.
      def connect
        GraphWeaver.log(:debug) { "connecting to #{@uri.hostname}:#{@uri.port}" }
        Net::HTTP.start(
          @uri.hostname, @uri.port,
          use_ssl: @uri.scheme == "https",
          open_timeout: @open_timeout, read_timeout: @read_timeout,
          keep_alive_timeout: @keep_alive_timeout,
        )
      end

      def disconnect(http)
        return unless http

        GraphWeaver.log(:debug) { "dropping connection to #{@uri.hostname}:#{@uri.port}" }
        http.finish if http.started?
      rescue IOError
        # already closed
      end
    end
  end
end
