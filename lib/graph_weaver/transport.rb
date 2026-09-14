# typed: true
# frozen_string_literal: true

require "json"
require "sorbet-runtime"

require_relative "errors"
require_relative "internal"
require_relative "internal/endpoint"
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

  # Opt-in without the require: naming the constant loads the file, which is
  # where `require "faraday"` lives — so an initializer can write
  # Transport::Faraday.new(url) as the docs show, and an app that never names
  # it never loads faraday. Without the gem the LoadError names it.
  autoload :Faraday, "graph_weaver/transport/faraday"

  # The fixed half of what every request sends — see .default_headers for
  # all of it. graphql-over-http requires a conforming client to accept
  # application/graphql-response+json; the q=0.9 fallback keeps servers
  # that only speak the legacy media type working. The User-Agent is what
  # lets a server operator attribute the traffic.
  DEFAULT_HEADERS = {
    "Content-Type" => "application/json",
    "Accept" => "application/graphql-response+json, application/json;q=0.9",
    "User-Agent" => "graph_weaver/#{GraphWeaver::VERSION}",
  }.freeze

  # What every request sends unless the caller says otherwise. Apollo Router
  # and GraphOS key client attribution on the two apollographql-client-*
  # headers — per-client SLOs, per-client rate limits, "who still asks for
  # this deprecated field" — and a client that sends neither is attributed
  # to the empty string along with everyone else. They are plain headers, so
  # headers: overrides them: that is how one app names its several clients
  # apart, which a default can't do for it.
  def self.default_headers
    DEFAULT_HEADERS.merge(
      "apollographql-client-name" => client_name,
      "apollographql-client-version" => GraphWeaver::VERSION,
    )
  end

  # Apollo's client name is the consuming *application*, so a Rails app
  # answers with its own name — asked per request, because Rails.application
  # doesn't exist yet while the Gemfile is being required. The version stays
  # the gem's: graph_weaver can't know what your app calls its releases.
  def self.client_name
    # const_get rather than the constant itself: an app that typechecks this
    # gem without Rails in its sorbet payload can't resolve a bare ::Rails
    rails = Object.const_get(:Rails) if defined?(::Rails)
    app = rails.application if rails.respond_to?(:application)
    return "graph_weaver" unless app

    # Rails names the application class after the app: Storefront::Application
    namespace = app.class.name.to_s.split("::")[0..-2].join("::")
    namespace.empty? ? "graph_weaver" : namespace
  end
  private_class_method :client_name

  # Timeouts, in seconds, shared by the bundled transports — a missing
  # timeout is an outage, and net/http's own 60s/60s is far too patient
  # for an API call.
  DEFAULT_OPEN_TIMEOUT = 10
  DEFAULT_READ_TIMEOUT = 30

  # the endpoint this transport talks to — recorded into cached schema
  # dumps as provenance (see SchemaLoader.introspect)
  attr_reader :url

  # The same endpoint as this gem is willing to SAY it: a url can carry a
  # credential in its userinfo or a query parameter, and a log line, an
  # exception and an APM payload all outlive the request. Memoized, because
  # every request says it at least twice.
  def safe_url
    @safe_url ||= GraphWeaver::Internal::Endpoint.safe(url)
  end

  # operation_name: names the operation to run — sent on the wire as
  # `operationName`, which is what an APM keys its traces, rate limits and
  # slow-query reports on. Generated modules pass their OPERATION_NAME;
  # a raw query string falls back to the name in the document itself.
  def execute(query, variables: {}, operation_name: nil)
    operation_name ||= GraphWeaver::Internal::Wire.operation_name(query)
    payload = { url: safe_url, operation: operation_name, client: self.class,
                kind: GraphWeaver::Internal::Wire.kind(query) }

    GraphWeaver::Internal::Log.instrument(GraphWeaver::EXECUTE_EVENT, payload) do
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
    GraphWeaver::Internal::Log.log(:debug) do
      filtered = GraphWeaver::Internal::Log.variables_for_log(variables)
      "POST #{safe_url} #{tag} variables=#{filtered}\n#{GraphWeaver::Internal::Wire.truncate_for_log(query)}"
    end

    # camelCase because it's the graphql-over-http request field, not a
    # Ruby name; omitted rather than null when the operation is anonymous
    request = { query:, variables: }
    request[:operationName] = operation_name if operation_name

    GraphWeaver::Internal::Wire.check_variables!(variables)
    encoded = GraphWeaver::Internal::Wire.json(request)

    # headers is optional: a third-party subclass returning the
    # documented [status, body] pair simply has none
    status, body, headers = begin
      GraphWeaver::Internal::Log.log_timed(:debug, "POST #{safe_url} #{tag} completed") do
        post(encoded)
      end
    rescue *GraphWeaver.transport_errors.to_a => e
      # never got a response — DNS, connection refused/reset, TLS, timeout.
      # The adapter's sentence is its own words, capped like any text we
      # didn't author.
      raise GraphWeaver::TransportError.new(
        "#{e.class}: #{GraphWeaver::Internal::Redact.cap(e.message)}", url: safe_url,
      )
    end

    payload[:http_status] = status
    # folded once: a third-party subclass's headers may come back in any
    # casing, and a subclass that returns none says nothing
    fields = GraphWeaver::Internal::Headers.wrap(headers || {})
    # the content type, not the body: it is what tells a proxy's HTML page
    # from a router's JSON without quoting bytes a server chose
    GraphWeaver::Internal::Log.log(:debug) do
      type = GraphWeaver::Internal::Redact.tag(fields["content-type"])
      "HTTP #{status} #{tag} from #{safe_url} (#{body.to_s.bytesize} bytes#{", #{type}" if type})"
    end

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
      if parsed.is_a?(Hash) && parsed["errors"].is_a?(Array) && parsed["errors"].any?
        return Envelope.new(parsed, status, fields.retry_after)
      end

      refuse!(status, body, headers)
    end

    unless parsed.is_a?(Hash)
      # a 200 that isn't a GraphQL object — an HTML error page from a proxy, a
      # captive portal, or a bare JSON array/string: the server misbehaved.
      # A well-formed @defer stream is named rather than lumped in: it isn't
      # non-GraphQL, it's more than one GraphQL document.
      detail =
        if incremental?(fields)
          "this response is incremental delivery (@defer/@stream), which this client doesn't read"
        elsif body.to_s.empty?
          "empty response body"
        else
          "non-GraphQL response"
        end
      refuse!(status, body, headers, detail:)
    end

    Envelope.new(parsed, status, fields.retry_after)
  end

  # The response wasn't one we can read. A body is never quoted — not into the
  # message, not into a log line: it is text a server chose, and an error page
  # that echoes the request fills it with the variables and the Authorization
  # header we just sent. `detail` is what WE say went wrong; the bytes are on
  # ServerError#body for whoever rescues it.
  private def refuse!(status, body, headers, detail: nil)
    raise GraphWeaver::ServerError.new(status:, body: body.to_s, headers: headers || {}, url: safe_url, detail:)
  end

  # The parsed envelope, plus what the HTTP response said around it — a Hash
  # to everything that reads a GraphQL response, and more to the one caller
  # that needs it. Retry asks both: a router answers rate limiting with a 503
  # or 429 AND an errors body, so the body alone can't say whether to come
  # back, and Retry-After says when. The seconds, not the headers — that is
  # the whole of what Retry asks, and every other header stays where a
  # ServerError already carries it.
  class Envelope < Hash
    attr_reader :http_status, :retry_after

    def initialize(parsed, http_status, retry_after = nil)
      super()
      @http_status = http_status
      @retry_after = retry_after
      update(parsed)
    end
  end
  private_constant :Envelope

  # A leading UTF-8 BOM, which RFC 8259 §8.1 lets a parser ignore and Ruby's
  # doesn't. .NET/IIS-fronted endpoints emit one, and the three bytes that
  # break the parse are invisible in the body an error would quote back.
  # Compared as bytes: a net/http body arrives ASCII-8BIT, a middleware's
  # UTF-8, and those two are never == to each other.
  BOM = "\xEF\xBB\xBF".b
  private_constant :BOM

  # A multipart/mixed body is one @defer/@stream response arriving in
  # installments.
  private def incremental?(fields)
    fields["content-type"].to_s.start_with?("multipart/mixed")
  end

  # the parsed body, or nil when it isn't JSON (a caller's connection may
  # already parse via middleware — pass that through)
  private def parse_body(body)
    return body unless body.is_a?(String)

    body = T.must(body.byteslice(3..)) if body.byteslice(0, 3)&.b == BOM
    JSON.parse(body)
  rescue JSON::ParserError
    nil
  end

  # never leak credentials through logs/exceptions — a transport inspects as
  # its class and the endpoint it is safe to say, nothing more
  def inspect
    "#<#{self.class.name} url=#{safe_url.inspect}>"
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
