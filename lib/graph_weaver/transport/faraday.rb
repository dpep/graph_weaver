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

      def initialize(url_or_connection, headers: {}, open_timeout: nil, read_timeout: nil, &block)
        @connection = case url_or_connection
        when ::Faraday::Connection
          # a prebuilt connection carries its own headers/middleware/
          # timeouts, so they'd be silently dropped — fail loudly instead
          unless headers.empty? && block.nil? && open_timeout.nil? && read_timeout.nil?
            raise ArgumentError,
              "headers:/timeouts/block are ignored when passing a prebuilt Faraday::Connection — configure them on it"
          end

          url_or_connection
        else
          # Faraday appends the default adapter when the block doesn't set
          # one. Our defaults go on the connection so ours is the
          # User-Agent, not Faraday's stock one; caller headers still win.
          # Timeouts default to Transport::HTTP's — Faraday would
          # otherwise inherit net/http's 60s/60s.
          ::Faraday.new(
            url: url_or_connection,
            headers: DEFAULT_HEADERS.merge(headers),
            request: {
              open_timeout: open_timeout || DEFAULT_OPEN_TIMEOUT,
              read_timeout: read_timeout || DEFAULT_READ_TIMEOUT,
            },
            &block
          )
        end
        @url = @connection.url_prefix.to_s

        # which adapter got picked decides socket reuse — Faraday's
        # default net_http one opens a connection per request. Naming it
        # is the cheapest way to make that discoverable.
        GraphWeaver::Internal::Log.log(:info) { "faraday transport #{@url} (adapter: #{@connection.builder.adapter})" }
      end

      private

      sig { override.params(body: String).returns(T::Array[T.untyped]) }
      def post(body)
        response = @connection.post do |request|
          # a prebuilt connection owns its headers — only fill the blanks
          DEFAULT_HEADERS.each { |name, value| request.headers[name] ||= value }
          request.body = body
        end

        [response.status, response.body, response.headers.to_h.transform_keys(&:downcase)]
      end
    end
  end
end
