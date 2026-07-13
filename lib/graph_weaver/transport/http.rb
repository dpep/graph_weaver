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
    # Timeouts surface as TransportError (retriable). For connection
    # pooling and a middleware ecosystem, use Transport::Faraday.
    class HTTP < Transport
      # net/http's own network-level failures (Errno/SocketError/IOError
      # are already seeded) — added to the shared, extensible
      # transport-error set.
      GraphWeaver.register_transport_error(Timeout::Error, OpenSSL::SSL::SSLError)

      def initialize(url, headers: {}, open_timeout: 10, read_timeout: 30)
        @url = url
        @uri = URI(url)
        @headers = headers
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      private

      sig { override.params(body: String).returns([Integer, T.untyped]) }
      def post(body)
        request = Net::HTTP::Post.new(@uri, { "Content-Type" => "application/json" }.merge(@headers))
        request.body = body

        response = Net::HTTP.start(
          @uri.hostname, @uri.port,
          use_ssl: @uri.scheme == "https",
          open_timeout: @open_timeout, read_timeout: @read_timeout,
        ) do |http|
          http.request(request)
        end

        [response.code.to_i, response.body]
      end
    end
  end
end
