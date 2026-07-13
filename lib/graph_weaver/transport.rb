# typed: true
# frozen_string_literal: true

require "json"
require "sorbet-runtime"

require_relative "errors"

# Base class for the bundled network transports — Transport::HTTP
# (zero-dependency net/http, loaded by default) and Transport::Faraday
# (opt-in). A transport is just an executor that speaks GraphQL-over-HTTP:
# it satisfies the same execute(query, variables:) => {"data" => ...,
# "errors" => ...} contract as a schema class or a fake.
#
# The base class owns the shared flow — encode the request, reclassify
# network-level failures as TransportError, raise ServerError on a
# non-2xx status, parse the body — so a subclass only implements post:
# take the request body, return [status, body].
class GraphWeaver::Transport
  extend T::Sig
  extend T::Helpers
  abstract!

  # the endpoint this transport talks to — recorded into cached schema
  # dumps as provenance (see SchemaLoader.introspect)
  attr_reader :url

  def execute(query, variables: {})
    # full query + variables at debug only — they can carry PII
    GraphWeaver.log(:debug) { "POST #{url} variables=#{JSON.generate(variables)}\n#{query}" }

    status, body = begin
      GraphWeaver.log_timed(:debug, "POST #{url}") do
        post(JSON.generate(query:, variables:))
      end
    rescue *GraphWeaver.transport_errors.to_a => e
      # never got a response — DNS, connection refused/reset, TLS, timeout
      raise GraphWeaver::TransportError, "#{e.class}: #{e.message}"
    end

    GraphWeaver.log(:debug) { "HTTP #{status} from #{url} (#{body.to_s.bytesize} bytes)" }

    # reached the server, but it returned a non-2xx status
    unless (200..299).cover?(status)
      raise GraphWeaver::ServerError.new(status:, body: body.to_s)
    end

    # a caller's connection may already parse json via middleware
    body.is_a?(String) ? JSON.parse(body) : body
  end

  private

  # POST the JSON body to the endpoint; return [status code, raw body].
  sig { abstract.params(body: String).returns([Integer, T.untyped]) }
  def post(body); end
end
