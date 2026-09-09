# typed: true
# frozen_string_literal: true

require "json"
require "sorbet-runtime"

require_relative "errors"
require_relative "internal"
require_relative "version"

# Base class for the bundled network transports — Transport::HTTP
# (zero-dependency net/http, loaded by default) and Transport::Faraday
# (opt-in). A transport speaks GraphQL-over-HTTP and satisfies the same
# execute(query, variables:, operation_name:) => {"data" => ..., "errors" => ...}
# contract as a schema class or a fake — anything in a client slot.
#
# The base class owns the shared flow — encode the request, reclassify
# network-level failures as TransportError, raise ServerError on a
# non-2xx status, parse the body — so a subclass only implements post:
# take the request body, return [status, body].
class GraphWeaver::Transport
  extend T::Sig
  extend T::Helpers
  abstract!

  # What every request sends unless the caller says otherwise.
  # graphql-over-http requires a conforming client to accept
  # application/graphql-response+json; the q=0.9 fallback keeps servers
  # that only speak the legacy media type working. The User-Agent is what
  # lets a server operator attribute the traffic.
  DEFAULT_HEADERS = {
    "Content-Type" => "application/json",
    "Accept" => "application/graphql-response+json, application/json;q=0.9",
    "User-Agent" => "graph_weaver/#{GraphWeaver::VERSION}",
  }.freeze

  # Timeouts, in seconds, shared by the bundled transports — a missing
  # timeout is an outage, and net/http's own 60s/60s is far too patient
  # for an API call.
  DEFAULT_OPEN_TIMEOUT = 10
  DEFAULT_READ_TIMEOUT = 30

  # the endpoint this transport talks to — recorded into cached schema
  # dumps as provenance (see SchemaLoader.introspect)
  attr_reader :url

  # operation_name: names the operation to run — sent on the wire as
  # `operationName`, which is what an APM keys its traces, rate limits and
  # slow-query reports on. Generated modules pass their OPERATION_NAME;
  # a raw query string falls back to the name in the document itself.
  def execute(query, variables: {}, operation_name: nil)
    operation_name ||= GraphWeaver::Internal::Wire.operation_name(query)
    payload = { url:, operation: operation_name }

    GraphWeaver.instrument(GraphWeaver::EXECUTE_EVENT, payload) do
      perform(query, variables, operation_name, payload)
    end
  end

  # The request itself. Separate from execute so the instrumenter wraps
  # a call rather than a block this method returns out of.
  private def perform(query, variables, operation_name, payload)
    # tag pairs this request's log lines (threads interleave), and names
    # the operation so the log says WHICH query, not just the url
    tag = GraphWeaver.logger && GraphWeaver::Internal::Wire.log_tag(operation_name)

    # full query + variables at debug only — they can carry PII, and the
    # sensitive keys are scrubbed even there (GraphWeaver.filter_parameters)
    GraphWeaver.log(:debug) do
      filtered = JSON.generate(GraphWeaver.filter_variables(variables))
      "POST #{url} #{tag} variables=#{filtered}\n#{GraphWeaver::Internal::Wire.truncate_for_log(query)}"
    end

    # camelCase because it's the graphql-over-http request field, not a
    # Ruby name; omitted rather than null when the operation is anonymous
    request = { query:, variables: }
    request[:operationName] = operation_name if operation_name

    encoded = begin
      JSON.generate(request)
    rescue JSON::GeneratorError => e
      # a value with no JSON form (NaN, Infinity, binary) — the caller's
      # bug, surfaced under the umbrella instead of a raw JSON:: error
      raise GraphWeaver::Error, "variables are not JSON-serializable: #{e.message}"
    end

    # headers is optional: a third-party subclass returning the
    # documented [status, body] pair simply has none
    status, body, headers = begin
      GraphWeaver.log_timed(:debug, "POST #{url} #{tag} completed") do
        post(encoded)
      end
    rescue *GraphWeaver.transport_errors.to_a => e
      # never got a response — DNS, connection refused/reset, TLS, timeout
      raise GraphWeaver::TransportError, "#{e.class}: #{e.message}"
    end

    payload[:status] = status
    GraphWeaver.log(:debug) { "HTTP #{status} #{tag} from #{url} (#{body.to_s.bytesize} bytes)" }

    parsed = parse_body(body)

    # reached the server, but it returned a non-2xx status. Per
    # graphql-over-http, routers (Apollo Server/Router) send request
    # errors as 4xx WITH a GraphQL errors body — those flow into the
    # envelope so QueryError machinery sees the structured errors; only
    # a body that isn't GraphQL (proxy pages, HTML 500s) is a ServerError.
    unless (200..299).cover?(status)
      # only a body carrying actual GraphQL errors flows through — a 4xx with
      # `"errors": null` (or []) isn't a structured error response, so the
      # status stays the signal
      return parsed if parsed.is_a?(Hash) && parsed["errors"].is_a?(Array) && parsed["errors"].any?

      raise GraphWeaver::ServerError.new(status:, body: body.to_s, headers: headers || {})
    end

    unless parsed.is_a?(Hash)
      # a 200 that isn't a GraphQL object — an HTML error page from a proxy, a
      # captive portal, or a bare JSON array/string: the server misbehaved
      raise GraphWeaver::ServerError.new(
        status:, body: "non-GraphQL response: #{body.to_s[0, 500]}", headers: headers || {}
      )
    end

    parsed
  end

  # the parsed body, or nil when it isn't JSON (a caller's connection may
  # already parse via middleware — pass that through)
  private def parse_body(body)
    return body unless body.is_a?(String)

    JSON.parse(body)
  rescue JSON::ParserError
    nil
  end

  # never leak Authorization headers through logs/exceptions — a
  # transport inspects as its class + endpoint, nothing more
  def inspect
    "#<#{self.class.name} url=#{url.inspect}>"
  end
  alias to_s inspect

  private

  # POST the JSON body to the endpoint; return [status code, raw body]
  # — optionally with a third element, the response headers as a Hash
  # with downcased names, which ServerError then carries (Retry-After,
  # x-ratelimit-*). Two elements remains a complete answer.
  sig { abstract.params(body: String).returns(T::Array[T.untyped]) }
  def post(body); end
end
