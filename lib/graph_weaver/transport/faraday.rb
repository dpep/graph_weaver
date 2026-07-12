# typed: true
# frozen_string_literal: true

require "faraday"

require_relative "../transport"

module GraphWeaver
  class Transport
    # Faraday-backed transport. Opt-in (faraday is not a hard dependency):
    #
    #      require "graph_weaver/transport/faraday"
    #
    #      # simplest: build a default connection from a url
    #      GraphWeaver::Transport::Faraday.new("https://api.example.com/graphql")
    #
    #      # customize middleware while building
    #      GraphWeaver::Transport::Faraday.new(url) do |conn|
    #        conn.request :authorization, "Bearer", -> { Tokens.fetch }
    #        conn.response :logger
    #      end
    #
    #      # or bring a fully configured connection
    #      GraphWeaver::Transport::Faraday.new(Faraday.new(url:) { |conn| ... })
    class Faraday < Transport
      # Faraday's network-level failures — added to the shared, extensible
      # transport-error set.
      GraphWeaver.register_transport_error(
        ::Faraday::ConnectionFailed, ::Faraday::TimeoutError, ::Faraday::SSLError
      )

      def initialize(url_or_connection, headers: {}, &block)
        @connection = case url_or_connection
        when ::Faraday::Connection
          url_or_connection
        else
          # Faraday appends the default adapter when the block doesn't set one
          ::Faraday.new(url: url_or_connection, headers:, &block)
        end
        @url = @connection.url_prefix.to_s
      end

      private

      sig { override.params(body: String).returns([Integer, T.untyped]) }
      def post(body)
        response = @connection.post do |request|
          request.headers["Content-Type"] = "application/json"
          request.body = body
        end

        [response.status, response.body]
      end
    end
  end
end
