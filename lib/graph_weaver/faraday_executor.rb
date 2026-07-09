# typed: true
# frozen_string_literal: true

require "faraday"
require "json"

require_relative "errors"

# Faraday-backed transport. Opt-in (faraday is not a hard dependency):
#
#   require "graph_weaver/faraday_executor"
#
#   # simplest: build a default connection from a url
#   GraphWeaver::FaradayExecutor.new("https://api.example.com/graphql")
#
#   # customize middleware while building
#   GraphWeaver::FaradayExecutor.new(url) do |conn|
#     conn.request :authorization, "Bearer", -> { Tokens.fetch }
#     conn.response :logger
#   end
#
#   # or bring a fully configured connection
#   GraphWeaver::FaradayExecutor.new(Faraday.new(url:) { |conn| ... })
class GraphWeaver::FaradayExecutor
  # Faraday's network-level failures — added to the shared, extensible
  # transport-error set.
  GraphWeaver.register_transport_error(
    Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError
  )

  def initialize(url_or_connection, headers: {}, &block)
    @connection = case url_or_connection
    when Faraday::Connection
      url_or_connection
    else
      # Faraday appends the default adapter when the block doesn't set one
      Faraday.new(url: url_or_connection, headers:, &block)
    end
  end

  def execute(query, variables: {})
    response = begin
      @connection.post do |request|
        request.headers["Content-Type"] = "application/json"
        request.body = JSON.generate(query:, variables:)
      end
    rescue *GraphWeaver.transport_errors.to_a => e
      # never got a response — connection refused/reset, TLS, timeout
      raise GraphWeaver::TransportError, "#{e.class}: #{e.message}"
    end

    # reached the server, but it returned a non-2xx status
    unless response.success?
      raise GraphWeaver::ServerError.new(status: response.status, body: response.body.to_s)
    end

    body = response.body
    # a caller's connection may already parse json via middleware
    body.is_a?(String) ? JSON.parse(body) : body
  end
end
