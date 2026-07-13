# typed: true
# frozen_string_literal: true

require "json"
require "sorbet-runtime"

require_relative "errors"

# Base class for the bundled network transports — Transport::HTTP
# (zero-dependency net/http, loaded by default) and Transport::Faraday
# (opt-in). A transport speaks GraphQL-over-HTTP and satisfies the
# same execute(query, variables:) => {"data" => ..., "errors" => ...}
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

  # the endpoint this transport talks to — recorded into cached schema
  # dumps as provenance (see SchemaLoader.introspect)
  attr_reader :url

  def execute(query, variables: {})
    # tag pairs this request's log lines (threads interleave), and names
    # the operation so the log says WHICH query, not just the url
    tag = GraphWeaver.logger && GraphWeaver::Transport.log_tag(query)

    # full query + variables at debug only — they can carry PII
    GraphWeaver.log(:debug) do
      "POST #{url} #{tag} variables=#{JSON.generate(variables)}\n#{GraphWeaver::Transport.truncate_for_log(query)}"
    end

    encoded = begin
      JSON.generate(query:, variables:)
    rescue JSON::GeneratorError => e
      # a value with no JSON form (NaN, Infinity, binary) — the caller's
      # bug, surfaced under the umbrella instead of a raw JSON:: error
      raise GraphWeaver::Error, "variables are not JSON-serializable: #{e.message}"
    end

    status, body = begin
      GraphWeaver.log_timed(:debug, "POST #{url} #{tag} completed") do
        post(encoded)
      end
    rescue *GraphWeaver.transport_errors.to_a => e
      # never got a response — DNS, connection refused/reset, TLS, timeout
      raise GraphWeaver::TransportError, "#{e.class}: #{e.message}"
    end

    GraphWeaver.log(:debug) { "HTTP #{status} #{tag} from #{url} (#{body.to_s.bytesize} bytes)" }

    parsed = parse_body(body)

    # reached the server, but it returned a non-2xx status. Per
    # graphql-over-http, routers (Apollo Server/Router) send request
    # errors as 4xx WITH a GraphQL errors body — those flow into the
    # envelope so QueryError machinery sees the structured errors; only
    # a body that isn't GraphQL (proxy pages, HTML 500s) is a ServerError.
    unless (200..299).cover?(status)
      return parsed if parsed.is_a?(Hash) && parsed.key?("errors")

      raise GraphWeaver::ServerError.new(status:, body: body.to_s)
    end

    unless parsed
      # a 200 that isn't GraphQL — an HTML error page from a proxy, a
      # captive portal: the server misbehaved, classify it that way
      raise GraphWeaver::ServerError.new(status:, body: "non-JSON response: #{body.to_s[0, 500]}")
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

  # "[req 3 FilteredPokemon]" — a per-process request id plus the
  # operation name (when the document declares one)
  REQUEST_MUTEX = Mutex.new

  def self.log_tag(query)
    id = REQUEST_MUTEX.synchronize { @request_count = (@request_count || 0) + 1 }
    name = query[/\A\s*(?:query|mutation|subscription)\s+([A-Za-z_]\w*)/, 1]
    "[req #{id}#{" #{name}" if name}]"
  end

  # keep debug readable: a 100-line introspection query would drown the
  # log — the INFO introspection line already carries the timing
  LOG_QUERY_LIMIT = 600
  def self.truncate_for_log(query)
    return query if query.length <= LOG_QUERY_LIMIT

    "#{query[0, LOG_QUERY_LIMIT]}... (truncated, #{query.bytesize} bytes total)"
  end

  private

  # POST the JSON body to the endpoint; return [status code, raw body].
  sig { abstract.params(body: String).returns([Integer, T.untyped]) }
  def post(body); end
end
