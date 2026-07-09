# typed: true
# frozen_string_literal: true

require "json"
require "sorbet-runtime"
require "net/http"
require "openssl"
require "uri"

# Minimal HTTP transport satisfying the generated modules' executor
# interface: execute(query, variables:) => {"data" => ..., "errors" => ...}
class GraphWeaver::HttpExecutor
  def initialize(url, headers: {})
    @uri = URI(url)
    @headers = headers
  end

  def execute(query, variables: {})
    request = Net::HTTP::Post.new(@uri, { "Content-Type" => "application/json" }.merge(@headers))
    request.body = JSON.generate(query:, variables:)

    response = begin
      Net::HTTP.start(@uri.hostname, @uri.port, use_ssl: @uri.scheme == "https") do |http|
        http.request(request)
      end
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError => e
      # never got a response — DNS, connection refused/reset, TLS, timeout
      raise GraphWeaver::TransportError, "#{e.class}: #{e.message}"
    end

    # reached the server, but it returned a non-2xx status
    unless response.is_a?(Net::HTTPSuccess)
      raise GraphWeaver::ServerError.new(status: response.code.to_i, body: response.body)
    end

    JSON.parse(T.must(response.body))
  end
end
