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
    # Timeouts surface as TransportError (retriable). The connection is
    # persistent (keep-alive), serialized behind a mutex — one socket per
    # transport, dropped on any failure so the next call starts fresh.
    # For real connection pooling and a middleware ecosystem, use
    # Transport::Faraday.
    class HTTP < Transport
      # net/http's own network-level failures (Errno/SocketError/IOError
      # are already seeded) — added to the shared, extensible
      # transport-error set.
      GraphWeaver.register_transport_error(Timeout::Error, OpenSSL::SSL::SSLError)

      def initialize(url, headers: {}, open_timeout: 10, read_timeout: 30, keep_alive_timeout: 2)
        @url = url
        @uri = URI(url)
        @headers = headers
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @keep_alive_timeout = keep_alive_timeout
        @mutex = Mutex.new
        @http = T.let(nil, T.nilable(Net::HTTP))
      end

      private

      sig { override.params(body: String).returns([Integer, T.untyped]) }
      def post(body)
        request = Net::HTTP::Post.new(@uri, { "Content-Type" => "application/json" }.merge(@headers))
        request.body = body

        response = @mutex.synchronize do
          begin
            connection.request(request)
          rescue => e
            # socket state is unknown — drop it so the next call starts
            # fresh (retry policy belongs to Retry, not here)
            disconnect
            raise e
          end
        end

        [response.code.to_i, response.body]
      end

      # The persistent connection. net/http proactively reconnects when
      # idle past keep_alive_timeout, so a server-closed keep-alive
      # socket doesn't produce spurious failures.
      def connection
        @http ||= begin
          GraphWeaver.log(:debug) { "connecting to #{@uri.hostname}:#{@uri.port}" }
          Net::HTTP.start(
            @uri.hostname, @uri.port,
            use_ssl: @uri.scheme == "https",
            open_timeout: @open_timeout, read_timeout: @read_timeout,
            keep_alive_timeout: @keep_alive_timeout,
          )
        end
      end

      def disconnect
        http = @http
        return unless http

        GraphWeaver.log(:debug) { "dropping connection to #{@uri.hostname}:#{@uri.port}" }
        http.finish if http.started?
      rescue IOError
        # already closed
      ensure
        @http = nil
      end
    end
  end
end
