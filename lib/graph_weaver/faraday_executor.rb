# typed: true
# frozen_string_literal: true

require "faraday"
require "json"

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
    response = @connection.post do |request|
      request.headers["Content-Type"] = "application/json"
      request.body = JSON.generate(query:, variables:)
    end

    unless response.success?
      raise "HTTP #{response.status}: #{response.body}"
    end

    body = response.body
    # a caller's connection may already parse json via middleware
    body.is_a?(String) ? JSON.parse(body) : body
  end
end
