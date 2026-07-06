# typed: true
# frozen_string_literal: true

require "json"
require "sorbet-runtime"
require "net/http"
require "uri"

# Minimal HTTP transport satisfying the generated modules' executor
# interface: execute(query, variables:) => {"data" => ..., "errors" => ...}
class HttpExecutor
  def initialize(url, headers: {})
    @uri = URI(url)
    @headers = headers
  end

  def execute(query, variables: {})
    request = Net::HTTP::Post.new(@uri, { "Content-Type" => "application/json" }.merge(@headers))
    request.body = JSON.generate(query:, variables:)

    response = Net::HTTP.start(@uri.hostname, @uri.port, use_ssl: @uri.scheme == "https") do |http|
      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise "HTTP #{response.code}: #{response.body}"
    end

    JSON.parse(T.must(response.body))
  end
end
