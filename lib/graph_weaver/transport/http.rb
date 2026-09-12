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
      # transport-error set. A garbage status line and a mangled compressed
      # body are as much "never got a usable response" as a reset socket is,
      # and both recover on a fresh connection when the cause was a desynced
      # keep-alive socket; Faraday's transport classifies them the same way.
      GraphWeaver.register_transport_error(
        Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      )
      # net/http gunzips through zlib, so a build without it can't receive a
      # compressed body in the first place
      GraphWeaver.register_transport_error(Zlib::Error) if defined?(Zlib::Error)

      # How many requests this process can have in flight at once. Rails sizes
      # its own connection pool from RAILS_MAX_THREADS and this is the same
      # question, so it answers both. A fiber server (Falcon) sets no such
      # ceiling of its own — pass pool_size: there.
      def self.default_pool_size
        threads = ENV["RAILS_MAX_THREADS"].to_i
        threads.positive? ? threads : 5
      end

      def initialize(url, headers: {}, open_timeout: DEFAULT_OPEN_TIMEOUT,
        read_timeout: DEFAULT_READ_TIMEOUT, keep_alive_timeout: 2, pool_size: nil,
        ca_file: nil, ca_path: nil, cert: nil, key: nil, verify_mode: nil)
        pool_size ||= self.class.default_pool_size
        raise ArgumentError, "pool_size: must be >= 1" unless pool_size >= 1

        @url = url
        # a scheme-less url parses as a *path* with no host, and the failure
        # then lands as far away as Net::HTTP.start(nil, nil)
        uri = begin
          URI(url)
        rescue URI::InvalidURIError
          nil
        end
        unless uri && %w[http https].include?(uri.scheme)
          raise ArgumentError, "expected an http(s) url, got #{url.inspect}"
        end

        @uri = uri
        @headers = headers
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @keep_alive_timeout = keep_alive_timeout

        # TLS, forwarded verbatim to Net::HTTP.start: a private CA
        # (ca_file:/ca_path:), a client certificate (cert:/key:), or a
        # verify_mode: — so mTLS doesn't mean reaching for Faraday
        @ssl = { ca_file:, ca_path:, cert:, key:, verify_mode: }.compact
        if @ssl.any? && @uri.scheme != "https"
          raise ArgumentError, "TLS options need an https url — got #{url}"
        end

        # One permit per allowed socket: holding a permit is the right to
        # hold a connection, so at most pool_size requests are in flight
        # and the rest queue rather than opening unbounded sockets.
        @pool_size = pool_size
        @permits = SizedQueue.new(pool_size)
        pool_size.times { @permits.push(true) }

        # live connections, LIFO — a warm socket beats opening a cold one,
        # so a single-threaded caller keeps reusing the same one
        @idle = []
        @pid = Process.pid
        @lock = Mutex.new # guards @idle, @pid and @saturated
      end

      private

      sig { override.params(body: String).returns(T::Array[T.untyped]) }
      def post(body)
        request = Net::HTTP::Post.new(@uri, request_headers)
        request.body = body

        response = with_connection { |http| http.request(request) }

        # each_header yields downcased names with repeats already joined
        [response.code.to_i, response.body, response.each_header.to_h]
      end

      # What this request sends. A value answering #call is resolved here
      # rather than at construction, so a header that expires — a rotating
      # token — is asked for per request; nil drops the header, which is how
      # an optional one says "not this time". Everything else ships as its
      # #to_s: net/http calls #strip on the value, so the documented
      # `-> { Current.tenant&.id }` was a bare NoMethodError in any app whose
      # ids are Integers.
      def request_headers
        DEFAULT_HEADERS.merge(@headers).filter_map do |name, value|
          value = value.call if value.respond_to?(:call)
          [name, value.to_s] unless value.nil?
        end.to_h
      end

      # Lease a connection for one round trip. The permit is held across
      # the whole trip — opening the socket included — so pool_size really
      # is the concurrency ceiling.
      def with_connection
        @lock.synchronize { reset_after_fork }
        acquire_permit
        # nothing between acquiring the permit and the ensure that returns it:
        # an async interrupt (Rack::Timeout, a fiber cancel) landing in that
        # gap would leak a permit, shrinking the pool for the process's life
        begin
          http = nil
          http = @lock.synchronize { @idle.pop } || connect
          result = yield http
          @lock.synchronize { @idle.push(http) }
          result
        rescue Exception
          # socket state is unknown — drop it, leaving the slot empty so
          # the next call starts fresh (retry policy belongs to Retry).
          # Exception, not StandardError: a fiber scheduler cancels with
          # Async::Stop, which descends from Exception.
          disconnect(http)
          raise
        ensure
          @permits.push(true)
        end
      end

      # A pool belongs to the process that built it. A socket idle at fork
      # time is inherited by every child — and nothing in a round trip says
      # which process opened it, so workers interleave requests on one fd and
      # a caller receives a well-formed answer to another process's query.
      # The inherited sockets are dropped WITHOUT #finish (closing would take
      # down the fd the parent is still using; they go with the child when it
      # exits), and the permits are rebuilt, since any held at fork time went
      # with the threads that held them.
      def reset_after_fork
        return if @pid == Process.pid

        @idle.clear
        @permits = SizedQueue.new(@pool_size)
        @pool_size.times { @permits.push(true) }
        @saturated = false
        @pid = Process.pid
      end

      # A fresh persistent connection. net/http proactively reconnects
      # when idle past keep_alive_timeout, so a server-closed keep-alive
      # socket doesn't produce spurious failures.
      def connect
        GraphWeaver::Internal::Log.log(:debug) { "connecting to #{@uri.hostname}:#{@uri.port}" }
        http = Net::HTTP.start(
          @uri.hostname, @uri.port,
          use_ssl: @uri.scheme == "https",
          open_timeout: @open_timeout, read_timeout: @read_timeout,
          keep_alive_timeout: @keep_alive_timeout,
          **@ssl,
        )
        # net/http otherwise returns the bytes that did arrive, so a
        # connection dying mid-body reads as a server answering with garbage —
        # a permanent ServerError — instead of the retriable EOFError it is
        http.ignore_eof = false
        http
      end

      # Take a permit, saying so when none is free. A queued request is
      # indistinguishable from a slow server from the outside, which is the
      # whole problem: pool_size is a hard ceiling under fibers exactly as
      # under threads. Warned once — a saturated pool stays saturated, and a
      # line per request would bury it.
      def acquire_permit
        @permits.pop(true)
      rescue ThreadError
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @permits.pop
        waited = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

        first = @lock.synchronize { !@saturated && (@saturated = true) }
        GraphWeaver::Internal::Log.log(first ? :warn : :debug) do
          "connection pool saturated: waited #{waited}ms for 1 of #{@pool_size} connections to " \
            "#{@uri.hostname} — raise pool_size: to this process's concurrency"
        end
      end

      def disconnect(http)
        return unless http

        GraphWeaver::Internal::Log.log(:debug) { "dropping connection to #{@uri.hostname}:#{@uri.port}" }
        http.finish if http.started?
      rescue IOError
        # already closed
      end
    end
  end
end
