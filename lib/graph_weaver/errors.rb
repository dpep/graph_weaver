# typed: true
# frozen_string_literal: true

require "set"
require "sorbet-runtime"
require_relative "inflect"

module GraphWeaver
  # Base for every error GraphWeaver raises — rescue this to catch them
  # all. #message is the human-friendly side; #to_h is the machine side —
  # a JSON-ready Hash (string keys) for logging, agents, or surfacing
  # structured failures to users. One subclass per failure site —
  # {TransportError} (never reached the server), {ServerError} (non-2xx),
  # {QueryError} (GraphQL-level errors), {TypeError} (response wouldn't
  # cast) — each merging its specifics into #to_h. ({ValidationError} is
  # the build-time outlier: an ArgumentError, so query-validation raises
  # stay rescuable as ArgumentError.)
  class Error < StandardError
    def to_h
      { "error" => self.class.name, "message" => message }
    end
  end

  # The request never reached the server: connection refused, DNS failure,
  # TLS handshake, timeout. The original exception is preserved as #cause.
  # Generally retriable.
  class TransportError < Error
    def to_h
      super.merge("cause" => cause&.class&.name)
    end
  end

  class << self
    # The exception classes the bundled executors reclassify as
    # TransportError — network-level failures where the request never
    # reached the server. A mutable Set: each transport contributes its own
    # on load (net/http adds Timeout/SSL, Faraday adds its ConnectionFailed,
    # …), and you can add more so they get the same handling:
    #
    #      GraphWeaver.transport_errors << MyPool::TimeoutError
    #      GraphWeaver.register_transport_error(Adapter::ResetError)
    #
    # SystemCallError covers every Errno::* (connection refused/reset, host
    # unreachable); SocketError covers DNS.
    def transport_errors
      @transport_errors ||= Set[SocketError, SystemCallError, IOError]
    end

    # Add one or more exception classes to the transport-error set.
    def register_transport_error(*classes)
      transport_errors.merge(classes)
      classes
    end
  end

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

    def to_h
      super.merge("status" => status)
    end
  end

  # One entry from a GraphQL response's top-level `errors` array. A value
  # object (not raised) — the response envelope and QueryError carry these.
  # Match on #code (extensions["code"]) rather than the message string.
  class GraphQLError
    attr_reader :message, :locations, :path, :extensions

    def initialize(message:, locations: [], path: nil, extensions: {}, type: nil)
      @message = message
      @locations = locations
      @path = path
      @extensions = extensions
      @error_type = type
    end

    def self.from_h(hash)
      new(
        message: hash["message"] || "(no message)",
        locations: hash["locations"] || [],
        path: hash["path"],
        extensions: hash["extensions"] || {},
        type: hash["type"],
      )
    end

    # The machine-readable error code, e.g. "THROTTLED" — the thing to
    # branch on. Read from extensions.code (the Apollo/spec-adjacent
    # convention) or a top-level "type" (GitHub's dialect: NOT_FOUND,
    # FORBIDDEN). nil when the server sent neither.
    def code
      extensions["code"] || @error_type
    end

    # Message shapes servers use when they reject the *shape* of a query
    # (unknown field/type/argument). Heuristic by necessity: only Apollo
    # sets a standard code (GRAPHQL_VALIDATION_FAILED); graphql-ruby and
    # GitHub speak in messages.
    VALIDATION_MESSAGE = /doesn't exist|Cannot query field|Unknown (field|type|argument)|isn't defined|undefined (field|type)/i

    # True when this error looks like the server rejected the query's
    # shape — for a generated module that usually means the schema
    # changed after generation.
    def validation?
      code == "GRAPHQL_VALIDATION_FAILED" || VALIDATION_MESSAGE.match?(message)
    end

    # The field the error points at, as a stable dotted path with list
    # indices stripped — ["people", 3, "email"] => "people.email". The
    # parseable key for grouping/reporting (the raw #path keeps indices).
    # nil for global errors with no path.
    def field
      return unless path

      named = path.reject { |seg| seg.is_a?(Integer) || seg.to_s.match?(/\A\d+\z/) }
      named.join(".") unless named.empty?
    end

    def to_s
      loc = locations&.first
      at = loc ? " at #{loc["line"]}:#{loc["column"]}" : ""
      where = path ? " (path: #{path.join(".")})" : ""
      tag = code ? " [#{code}]" : ""
      "#{message}#{at}#{where}#{tag}"
    end

    # JSON-ready: the problematic field (both forms — #field for grouping,
    # #path with indices for exact location), the machine code, and the
    # server's full extensions.
    def to_h
      {
        "message" => message,
        "code" => code,
        "field" => field,
        "path" => path,
        "locations" => locations,
        "extensions" => extensions,
        "validation" => validation?,
      }
    end
  end

  # Shared filtering over a collection of GraphQLErrors, for surfacing
  # field-level failures programmatically. Host must define #errors.
  module ErrorFiltering
    include Kernel # for sorbet: hosts are Objects

    # the host's interface, overridden by its attr_readers
    def errors
      raise NotImplementedError, "#{self.class} must define #errors"
    end

    def data
      raise NotImplementedError, "#{self.class} must define #data"
    end

    # Errors touching a field path — "user.email" or ["user", "email"];
    # prefix match, so deeper errors count too. List indices appear as
    # path segments ("people.0.email").
    def errors_at(path)
      want = (path.is_a?(String) ? path.split(".") : path).map(&:to_s)
      errors.select { |error| error.path && error.path.map(&:to_s).first(want.size) == want }
    end

    # True when any error looks like the server rejected the query's
    # shape — the schema has likely changed since the module was
    # generated. Refresh the schema dump and regenerate (rake
    # graph_weaver:schema:refresh && rake graph_weaver:generate).
    def schema_stale?
      errors.any?(&:validation?)
    end

    # Errors grouped by the field they point at (index-stripped dotted
    # path; nil key for global errors) — iterate with each_error:
    #
    #      response.each_error do |field, errors|
    #        form.add_error(field, errors.map(&:message))
    #      end
    def errors_by_field
      errors.group_by(&:field)
    end

    def each_error(&block)
      errors_by_field.each(&block)
    end

    # The id of the record an error points into, resolved by walking the
    # error's path through the (partial) typed data: an error at
    # ["people", 3, "email"] resolves to people[3].id. nil when the data
    # is missing, the path doesn't walk, or the record has no id field.
    def entity_id(error)
      # untyped by nature: the walk traverses whatever structs this query
      # generated, reassigning across types at each step
      node = T.let(data, T.untyped)
      return unless node && error.path

      error.path[0..-2].each do |segment|
        node = if segment.is_a?(Integer) || segment.to_s.match?(/\A\d+\z/)
          node.is_a?(Array) ? node[segment.to_i] : nil
        else
          prop = GraphWeaver::Inflect.underscore(segment.to_s).to_sym
          node.respond_to?(prop) ? node.public_send(prop) : nil
        end
        return if node.nil?
      end

      node.respond_to?(:id) ? node.id : nil
    end

    # The user-facing rollup: errors keyed by field, with the ids of the
    # actual records that failed inlined — "the 3 in people.3.email is
    # useless to a user; people.email plus which people is the answer".
    #
    #      { "people.email" => { "messages" => [...], "codes" => [...],
    #        "entity_ids" => ["7", "9"], "errors" => [full to_h...] } }
    def report
      errors_by_field.to_h do |field, field_errors|
        [field, {
          "messages" => field_errors.map(&:message),
          "codes" => field_errors.filter_map(&:code).uniq,
          "entity_ids" => field_errors.filter_map { |e| entity_id(e) }.uniq,
          "errors" => field_errors.map(&:to_h),
        }]
      end
    end
  end

  # Raised when a GraphQL response carried top-level errors and the caller
  # demanded data (Response#data!, or the one-shot GraphWeaver.execute).
  # Carries the structured errors, any partial data, and top-level
  # extensions (cost/throttle metadata).
  class QueryError < Error
    include ErrorFiltering

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

    # The machine side: every error with its path/code/extensions, plus
    # the drift verdict — nest this straight into a JSON response.
    def to_h
      super.merge(
        "schema_stale" => schema_stale?,
        "codes" => codes,
        "errors" => errors.map(&:to_h),
        "extensions" => extensions,
      )
    end

    private

    def summary
      first = errors.first
      more = errors.size > 1 ? " (and #{errors.size - 1} more)" : ""
      drift = schema_stale? ? " — the server rejected the query shape: the schema may have changed since generation; refresh the schema dump and regenerate (rake graph_weaver:schema:refresh && rake graph_weaver:generate)" : ""
      "GraphQL query failed: #{first}#{more}#{drift}"
    end
  end

  # Raised when a response can't be cast into the generated structs — the
  # wire data disagreed with the types the schema promised at generation
  # time (a nil where non-null was declared, a malformed scalar, an
  # unknown enum value). #struct names the generated type that failed;
  # #cause carries the original TypeError/KeyError with the offending
  # prop in its message.
  class TypeError < Error
    attr_reader :struct

    def initialize(struct:, error: nil, message: nil)
      @struct = struct
      super("failed to cast response into #{struct}: #{message || error&.message}")
    end

    def to_h
      super.merge("struct" => struct.to_s, "cause" => cause&.message)
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

    def to_h
      {
        "error" => self.class.name,
        "message" => message,
        "errors" => errors.map { |e| e.transform_keys(&:to_s) },
      }
    end
  end
end
