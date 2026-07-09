# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

module GraphWeaver
  # Base for every error GraphWeaver raises — rescue this to catch them all.
  class Error < StandardError; end

  # The request never reached the server: connection refused, DNS failure,
  # TLS handshake, timeout. The original exception is preserved as #cause.
  # Generally retriable.
  class TransportError < Error; end

  # The request reached the server but it returned a non-2xx status — a 500
  # that exploded, a 502 from a proxy, a 401, etc. Distinct from a GraphQL
  # error: we got an HTTP response, it just wasn't success.
  class ServerError < Error
    attr_reader :status, :body

    def initialize(status:, body: nil)
      @status = status
      @body = body
      snippet = body.to_s.empty? ? "" : ": #{body.to_s[0, 500]}"
      super("HTTP #{status}#{snippet}")
    end
  end

  # One entry from a GraphQL response's top-level `errors` array. A value
  # object (not raised) — the response envelope and QueryError carry these.
  # Match on #code (extensions["code"]) rather than the message string.
  class GraphQLError
    attr_reader :message, :locations, :path, :extensions

    def initialize(message:, locations: [], path: nil, extensions: {})
      @message = message
      @locations = locations
      @path = path
      @extensions = extensions
    end

    def self.from_h(hash)
      new(
        message: hash["message"] || "(no message)",
        locations: hash["locations"] || [],
        path: hash["path"],
        extensions: hash["extensions"] || {},
      )
    end

    # The machine-readable error code, e.g. "THROTTLED" — the thing to
    # branch on. nil when the server didn't set extensions.code.
    def code
      extensions["code"]
    end

    def to_s
      loc = locations&.first
      at = loc ? " at #{loc["line"]}:#{loc["column"]}" : ""
      where = path ? " (path: #{path.join(".")})" : ""
      tag = code ? " [#{code}]" : ""
      "#{message}#{at}#{where}#{tag}"
    end
  end

  # Raised when a GraphQL response carried top-level errors and the caller
  # demanded data (Response#data!, or the one-shot GraphWeaver.execute).
  # Carries the structured errors, any partial data, and top-level
  # extensions (cost/throttle metadata).
  class QueryError < Error
    attr_reader :errors, :data, :extensions

    def initialize(errors, data: nil, extensions: {})
      @errors = errors
      @data = data
      @extensions = extensions
      super(summary)
    end

    # All non-nil error codes — handy for `codes.include?("THROTTLED")`.
    def codes
      errors.map(&:code).compact
    end

    private

    def summary
      first = errors.first
      more = errors.size > 1 ? " (and #{errors.size - 1} more)" : ""
      "GraphQL query failed: #{first}#{more}"
    end
  end

  # Build-time: the query didn't validate against the schema. Kept an
  # ArgumentError for source compatibility, but carries the structured
  # validation errors (message + line/column) rather than a joined string.
  class ValidationError < ArgumentError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super("invalid query: #{errors.map { |e| e[:message] }.join("; ")}")
    end
  end
end
