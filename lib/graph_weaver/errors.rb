# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "time" # Time.httpdate, for Retry-After

require_relative "inflect"
require_relative "internal/endpoint"
require_relative "internal/headers"
require_relative "logging"

module GraphWeaver
  # Base for every error GraphWeaver raises — rescue this to catch them
  # all. #message is the human-friendly side; #to_h is the machine side —
  # a JSON-ready Hash (string keys) for logging, agents, or surfacing
  # structured failures to users. One subclass per failure site —
  # {TransportError} (no response came back), {ServerError} (non-2xx),
  # {QueryError} (GraphQL-level errors), {CastError} (response wouldn't
  # cast), {InputError} (bad variables), {QueryValidationError} (build time),
  # {ConfigurationError} (setup judged against your schema) — each merging
  # its specifics into #to_h.
  class Error < StandardError
    extend T::Sig

    # every GraphWeaver error surfaces on the logger too (see
    # GraphWeaver.logger) — construction here means a raise
    sig { params(args: T.untyped).void }
    def initialize(*args)
      super
      GraphWeaver::Internal::Log.log(:warn) { "#{self.class.name}: #{message}" } if raised?
    end

    # Every error here is raised where it is built — except an InputError read
    # back off a response, which is a value. A warn line there would claim a
    # raise that never happened.
    sig { overridable.returns(T::Boolean) }
    private def raised? = true

    sig { overridable.returns(T::Hash[String, T.untyped]) }
    def to_h
      { "error" => self.class.name, "message" => message }
    end
  end

  # No response came back: connection refused, DNS failure, TLS handshake,
  # timeout, a socket that died mid-body. The original exception is preserved
  # as #cause. Retriable — though a *read* timeout says nothing about whether
  # the server applied the request, which is why Retry gives a mutation one
  # attempt.
  class TransportError < Error
    extend T::Sig

    # The endpoint the request never reached, as it is safe to say — userinfo
    # and secret query parameters folded out (see Internal::Endpoint). nil
    # when there is no endpoint: a `Testing::Failure` client, a fake.
    sig { returns(T.nilable(String)) }
    attr_reader :url

    sig { params(message: T.untyped, url: T.nilable(String)).void }
    def initialize(message = nil, url: nil)
      @url = url
      super("#{message}#{" — POST #{url}" if url}")
    end

    sig { override.returns(T::Hash[String, T.untyped]) }
    def to_h
      # url only when there is one — a fake client has no endpoint, and a key
      # spelled nil reads as "we lost it"
      super.merge("cause" => cause&.class&.name).merge({ "url" => url }.compact)
    end
  end

  class << self
    extend T::Sig

    # The exception classes the bundled transports reclassify as
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
    sig { returns(T::Set[T.class_of(Exception)]) }
    def transport_errors
      @transport_errors ||= T.let(
        Set[SocketError, SystemCallError, IOError],
        T.nilable(T::Set[T.class_of(Exception)]),
      )
    end

    # Add one or more exception classes to the transport-error set.
    sig { params(classes: T.class_of(Exception)).returns(T::Array[T.class_of(Exception)]) }
    def register_transport_error(*classes)
      transport_errors.merge(classes)
      classes
    end
  end

  # The request reached the server but it returned a non-2xx status — a 500
  # that exploded, a 502 from a proxy, a 401, etc. Distinct from a GraphQL
  # error: we got an HTTP response, it just wasn't success.
  class ServerError < Error
    extend T::Sig

    sig { returns(Integer) }
    attr_reader :status

    sig { returns(T.untyped) }
    attr_reader :body

    # The response headers — the rate-limit budget (x-ratelimit-remaining),
    # the request id your provider wants in a support ticket, Retry-After.
    # Looked up in any casing, iterated downcased. Empty when the transport
    # had none.
    sig { returns(T::Hash[String, String]) }
    attr_reader :headers

    # The endpoint that answered, as it is safe to say — userinfo and secret
    # query parameters folded out (see Internal::Endpoint). nil when there is
    # no endpoint: an in-process schema, a `Testing::Failure` client.
    sig { returns(T.nilable(String)) }
    attr_reader :url

    sig do
      params(
        status: Integer,
        body: T.untyped,
        headers: T::Hash[String, String],
        url: T.nilable(String),
        detail: T.nilable(String),
      ).void
    end
    def initialize(status:, body: nil, headers: {}, url: nil, detail: nil)
      @status = status
      @body = body
      @url = url
      @headers = T.let(GraphWeaver::Internal::Headers.wrap(headers), T::Hash[String, String])
      # A message never carries a body. `detail` is what WE say went wrong; the
      # bytes the server sent stay on #body, the way #to_h already keeps the
      # headers off — an error page that echoes the request (Rails' own dev
      # page, many proxies) carries the caller's variables and our own
      # Authorization header, and every raised error writes its message to the
      # log at warn.
      super("HTTP #{status}#{" — #{detail}" if detail}#{" — #{hint}" if hint}#{" — POST #{url}" if url}")
    end

    # What to do about this status, where the status says it. A redirect is
    # not followed — replaying a POST, with its Authorization header, at a
    # host the server named is not ours to decide — so the destination has to
    # reach whoever configured the url.
    REDIRECTS = [301, 302, 303, 307, 308].freeze

    sig { returns(T.nilable(String)) }
    def hint
      if REDIRECTS.include?(status)
        # the destination is a url the SERVER chose — said the way we say our
        # own, and without the framing a header value could smuggle in
        location = headers["location"]
        location &&= GraphWeaver::Internal::Redact.tag(GraphWeaver::Internal::Endpoint.safe(location))
        "redirects are not followed#{" — point the client at #{location}" if location}"
      elsif [401, 403].include?(status)
        "the server rejected the credentials — check auth: (the token, and its scopes)"
      end
    end

    # Seconds to wait per the server's Retry-After, which is either a
    # delay in seconds or an HTTP-date. nil when absent or unparseable;
    # negative dates (already past) clamp to 0. See RFC 9110 §10.2.3.
    sig { returns(T.nilable(Float)) }
    def retry_after
      value = headers["retry-after"]&.strip
      return if value.nil? || value.empty?
      return value.to_f if value.match?(/\A\d+(\.\d+)?\z/)

      seconds = Time.httpdate(value) - Time.now
      [seconds, 0.0].max
    rescue ArgumentError
      nil
    end

    # True when the server said "you're going too fast" — 429, or the
    # 503 + Retry-After that some gateways send instead. Same question,
    # same name, as QueryError#throttled?: an API may answer either way.
    sig { returns(T::Boolean) }
    def throttled?
      status == 429 || (status == 503 && !retry_after.nil?)
    end

    sig { override.returns(T::Hash[String, T.untyped]) }
    def to_h
      # the raw headers stay off the machine side — Set-Cookie and
      # friends don't belong in a log line; read #headers for those
      super.merge("status" => status, "retry_after" => retry_after, "url" => url).compact
    end
  end

  # One entry from a GraphQL response's top-level `errors` array. A value
  # object (not raised) — the response envelope and QueryError carry these.
  # Match on #code (extensions["code"]) rather than the message string.
  class GraphQLError
    extend T::Sig

    sig { returns(String) }
    attr_reader :message

    sig { returns(T::Array[T.untyped]) }
    attr_reader :locations

    sig { returns(T.nilable(T::Array[T.untyped])) }
    attr_reader :path

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :extensions

    sig do
      params(
        message: String,
        locations: T::Array[T.untyped],
        path: T.nilable(T::Array[T.untyped]),
        extensions: T::Hash[String, T.untyped],
        type: T.nilable(String),
      ).void
    end
    def initialize(message:, locations: [], path: nil, extensions: {}, type: nil)
      @message = message
      @locations = locations
      @path = path
      @extensions = extensions
      @error_type = T.let(type, T.nilable(String))
    end

    sig { params(hash: T::Hash[String, T.untyped]).returns(GraphQLError) }
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
    sig { returns(T.nilable(String)) }
    def code
      extensions["code"] || @error_type
    end

    # Codes a server sets when it rejects the *shape* of a query. Apollo has
    # one flat code; graphql-ruby names the rule that fired, and it is the
    # in-process client this library ships, so its drift-shaped rules are
    # listed rather than guessed at from prose.
    VALIDATION_CODES = T.let(%w[
      GRAPHQL_VALIDATION_FAILED
      undefinedField undefinedType undefinedDirective
      argumentNotAccepted argumentType argumentLiteralsIncompatible
      missingRequiredArguments missingRequiredInputObjectAttribute
      cannotSpreadFragment fragmentOnNonCompositeType
      variableMismatch variableRequiresValidType variableNotDefined
      selectionMismatch invalidOneOfInputObject
    ].to_set.freeze, T::Set[String])

    # For servers that send no code at all. Variable coercion reports through
    # the message in both dialects, and a required input field appearing is
    # unambiguous here: a generated input struct enforces its own required
    # fields, so the app cannot produce that error itself.
    VALIDATION_MESSAGE = T.let(
      Regexp.union(
        /doesn't exist/i, /Cannot query field/i, /Unknown (field|type|argument)/i,
        /is ?n[o']t defined/i, /undefined (field|type)/i, /No such type/i,
        /can't be spread inside/i, /is missing required arguments/i,
        /doesn't accept argument/i, /Field is not defined on/i,
        /was provided invalid value for .+ \(Expected value to not be null\)/i,
      ),
      Regexp,
    )

    # True when this error looks like the server rejected the query's
    # shape — for a generated module that usually means the schema
    # changed after generation.
    sig { returns(T::Boolean) }
    def validation?
      # to_s: a nil code is never a member, and sorbet can't narrow a call
      VALIDATION_CODES.include?(code.to_s) || VALIDATION_MESSAGE.match?(message)
    end

    # The codes servers use to say "you're going too fast". No standard
    # exists, so this is the union of what the big graphs actually send:
    # Shopify THROTTLED, GitHub RATE_LIMITED, Apollo Router
    # REQUEST_RATE_LIMITED (measured against v2.17.0), Hasura the rest.
    # Pass it to Retry (retry_codes:) rather than hand-writing strings.
    THROTTLE_CODES = T.let(
      %w[
        THROTTLED RATE_LIMITED RATE_LIMIT_EXCEEDED TOO_MANY_REQUESTS
        REQUEST_LIMIT_EXCEEDED REQUEST_RATE_LIMITED
      ].freeze,
      T::Array[String],
    )

    # True when this error is the GraphQL-level equivalent of a 429 —
    # the same question ServerError#throttled? asks of an HTTP status,
    # since an API may answer either way.
    sig { returns(T::Boolean) }
    def throttled?
      THROTTLE_CODES.include?(code)
    end

    # Codes that say "this error is about the input you sent", and what each
    # one means. `BAD_USER_INPUT` is the ecosystem's coarse bucket (Apollo's,
    # and what docs/errors.md asks a server to stamp); the rest are
    # graphql-ruby's own rule names, measured against 2.6.10. Nothing else is
    # claimed: a `validates:` failure reaches the wire as a bare sentence
    # with no extensions at all, indistinguishable from "the database is
    # down", and attaching that to a form field is worse than missing it.
    INPUT_CODES = T.let({
      "BAD_USER_INPUT" => :refused,
      "argumentLiteralsIncompatible" => :type_mismatch,
      "variableMismatch" => :type_mismatch,
      "missingRequiredInputObjectAttribute" => :missing,
      "argumentNotAccepted" => :unknown,
    }.freeze, T::Hash[String, Symbol])

    # This error as input problems — [] when it isn't about the input at all.
    # Plural because one variable-coercion error genuinely carries N of them,
    # and dropping all but the first is the quiet loss this library refuses.
    # See docs/errors.md ("What your server can send") for the three shapes
    # read here, and docs/i18n.md for the vocabulary.
    sig { returns(T::Array[InputError]) }
    def input_errors
      @input_errors ||= T.let(GraphWeaver::Internal::ServerInput.read(self), T.nilable(T::Array[InputError]))
    end

    # The field the error points at, as a stable dotted path with list
    # indices stripped — ["people", 3, "email"] => "people.email". The
    # parseable key for grouping/reporting (the raw #path keeps indices).
    # nil for global errors with no path.
    sig { returns(T.nilable(String)) }
    def field
      p = path
      return unless p

      named = p.reject { |seg| seg.is_a?(Integer) || seg.to_s.match?(/\A\d+\z/) }
      named.join(".") unless named.empty?
    end

    sig { returns(String) }
    def to_s
      loc = locations.first
      at = loc ? " at #{loc["line"]}:#{loc["column"]}" : ""
      p = path
      where = p ? " (path: #{p.join(".")})" : ""
      tag = code ? " [#{code}]" : ""
      "#{message}#{at}#{where}#{tag}"
    end

    # JSON-ready: the problematic field (both forms — #field for grouping,
    # #path with indices for exact location), the machine code, and the
    # server's full extensions.
    sig { returns(T::Hash[String, T.untyped]) }
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
  # field-level failures programmatically. Host must define #errors / #data.
  module ErrorFiltering
    extend T::Sig
    include Kernel # for sorbet: hosts are Objects

    # the host's interface, overridden by its attr_readers
    sig { overridable.returns(T::Array[GraphQLError]) }
    def errors
      raise NotImplementedError, "#{self.class} must define #errors"
    end

    sig { overridable.returns(T.untyped) }
    def data
      raise NotImplementedError, "#{self.class} must define #data"
    end

    # Errors touching a field path — "user.email" or ["user", "email"];
    # prefix match, so deeper errors count too. List indices appear as
    # path segments ("people.0.email").
    sig { params(path: T.any(String, T::Array[T.untyped])).returns(T::Array[GraphQLError]) }
    def errors_at(path)
      want = (path.is_a?(String) ? path.split(".") : path).map(&:to_s)
      errors.select do |error|
        p = error.path
        p && p.map(&:to_s).first(want.size) == want
      end
    end

    # True when any error looks like the server rejected the query's
    # shape — the schema has likely changed since the module was
    # generated. Refresh the schema dump and regenerate (rake
    # graph_weaver:schema:refresh && rake graph_weaver:generate).
    sig { returns(T::Boolean) }
    def schema_stale?
      errors.any?(&:validation?)
    end

    # True when the server said "you're going too fast" in the errors
    # array rather than in an HTTP status — back off and retry, don't
    # rewrite the query. Same name as ServerError#throttled?, because an
    # API may answer either way and callers shouldn't have to care which.
    sig { returns(T::Boolean) }
    def throttled?
      errors.any?(&:throttled?)
    end

    # Every error here that is about the input we sent, as InputError values
    # — the same object a client-side refusal raises, so one renderer serves
    # both halves. [] when the server rejected nothing about the input, or
    # said nothing that identifies it as input (see GraphQLError::INPUT_CODES).
    #
    # #field is nil where the server stated no input path, so a form needs
    # the :base branch:
    #
    #      response.input_errors.each { |e| form.errors.add(e.field&.underscore || :base, e.message) }
    sig { returns(T::Array[InputError]) }
    def input_errors
      errors.flat_map(&:input_errors)
    end

    # Errors grouped by the field they point at (index-stripped dotted
    # path; nil key for global errors) — iterate with each_error:
    #
    #      response.each_error do |field, errors|
    #        form.add_error(field, errors.map(&:message))
    #      end
    sig { returns(T::Hash[T.nilable(String), T::Array[GraphQLError]]) }
    def errors_by_field
      errors.group_by(&:field)
    end

    sig do
      params(block: T.proc.params(field: T.nilable(String), errors: T::Array[GraphQLError]).void).void
    end
    def each_error(&block)
      errors_by_field.each { |field, errs| block.call(field, errs) }
    end

    # The id of the record an error points into, resolved by walking the
    # error's path through the (partial) typed data: an error at
    # ["people", 3, "email"] resolves to people[3].id. nil when the data
    # is missing, the path doesn't walk, or the record has no id field.
    sig { params(error: GraphQLError).returns(T.untyped) }
    def entity_id(error)
      # untyped by nature: the walk traverses whatever structs this query
      # generated, reassigning across types at each step
      node = T.let(data, T.untyped)
      path = error.path
      return unless node && path

      (path[0..-2] || []).each do |segment|
        node = if segment.is_a?(Integer) || segment.to_s.match?(/\A\d+\z/)
          node.is_a?(Array) ? node[segment.to_i] : nil
        else
          field_value(node, segment)
        end
        return if node.nil?
      end

      field_value(node, "id")
    end

    # The value of the field a path segment names, or nil when this struct
    # hasn't got one. Read off the struct's own props, never `respond_to?` —
    # the path comes from the SERVER, and every Object method answers that:
    # a segment named `freeze` froze the caller's result and then reported an
    # id for a field that doesn't exist, `display` printed the struct to
    # stdout, and `tap`/`send`/`method` raised out of error handling.
    #
    # Two candidates, because a prop that would shadow a method the struct
    # answers is emitted with a trailing underscore (`class` -> `class_`).
    # Asking the struct rather than re-deriving the emitter's reserved list
    # also survives the skew: a file generated by an older version was
    # renamed by that version's list, not this one's.
    sig { params(node: T.untyped, segment: T.untyped).returns(T.untyped) }
    private def field_value(node, segment)
      props = node.class.props if node.class.respond_to?(:props)
      return unless props.is_a?(Hash)

      name = GraphWeaver::Inflect.underscore(segment.to_s)
      prop = [name.to_sym, :"#{name}_"].find { |candidate| props.key?(candidate) }
      node.public_send(prop) if prop
    end

    # The user-facing rollup: errors keyed by field, with the ids of the
    # actual records that failed inlined — "the 3 in people.3.email is
    # useless to a user; people.email plus which people is the answer".
    #
    #      { "people.email" => { "messages" => [...], "codes" => [...],
    #        "entity_ids" => ["7", "9"], "errors" => [full to_h...] } }
    sig { returns(T::Hash[T.nilable(String), T::Hash[String, T.untyped]]) }
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
  # demanded data (Response#data!, or the one-shot GraphWeaver.run!).
  # Carries the structured errors, any partial data, and top-level
  # extensions (cost/throttle metadata).
  class QueryError < Error
    extend T::Sig
    include ErrorFiltering

    sig { override.returns(T::Array[GraphQLError]) }
    attr_reader :errors

    sig { override.returns(T.untyped) }
    attr_reader :data

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :extensions

    sig do
      params(
        errors: T::Array[GraphQLError],
        data: T.untyped,
        extensions: T::Hash[String, T.untyped],
      ).void
    end
    def initialize(errors, data: nil, extensions: {})
      @errors = errors
      @data = data
      @extensions = extensions
      super(summary)
    end

    # All non-nil error codes — handy for `codes.include?("THROTTLED")`.
    sig { returns(T::Array[String]) }
    def codes
      errors.filter_map(&:code)
    end

    # The machine side: every error with its path/code/extensions, plus
    # the drift verdict — nest this straight into a JSON response.
    sig { override.returns(T::Hash[String, T.untyped]) }
    def to_h
      super.merge(
        "schema_stale" => schema_stale?,
        "throttled" => throttled?,
        "codes" => codes,
        "errors" => errors.map(&:to_h),
        "extensions" => extensions,
      )
    end

    # what a validation-shaped rejection means, and the way out of it
    DRIFT_HINT = T.let(
      "the server rejected the query shape: the schema may have changed since generation; " \
        "refresh the schema dump and regenerate " \
        "(rake graph_weaver:schema:refresh && rake graph_weaver:generate)",
      String,
    )

    private

    sig { returns(String) }
    def summary
      first = errors.first
      more = " (and #{errors.size - 1} more)" if errors.size > 1
      drift = " — #{DRIFT_HINT}" if schema_stale?
      "GraphQL query failed: #{first}#{more}#{drift}"
    end
  end

  # Raised when a response can't be cast into the generated structs — the
  # wire data disagreed with the types the schema promised at generation
  # time (a nil where non-null was declared, a malformed scalar, an
  # unknown enum value). #struct names the generated type that failed;
  # #cause carries the original TypeError/KeyError with the offending
  # prop in its message.
  class CastError < Error
    extend T::Sig

    sig { returns(T.untyped) }
    attr_reader :struct

    # sorbet-runtime appends its own frame to a prop type error ("Caller:
    # .../call_validation.rb:331"), which is a path into the gem and never
    # into the code with the problem — so it is dropped rather than reprinted
    # as if it located anything.
    SORBET_CALLER = /\s*\nCaller: .*\z/m

    sig { params(struct: T.untyped, error: T.nilable(Exception), message: T.nilable(String)).void }
    def initialize(struct:, error: nil, message: nil)
      @struct = struct
      super("failed to cast response into #{struct}: #{message || error&.message&.sub(SORBET_CALLER, "")}")
    end

    sig { override.returns(T::Hash[String, T.untyped]) }
    def to_h
      super.merge("struct" => struct.to_s, "cause" => cause&.message)
    end
  end

  # The caller's input was invalid — an unknown or typo'd input key, a
  # missing required input field, an out-of-range enum, a wrong-typed field.
  # Raised before the request leaves, so rescue it at an API boundary to
  # return a 422; it is ALSO the value a server's rejection becomes
  # (GraphQLError#input_errors, Response#input_errors), because "which input
  # was wrong, and how" is one question whichever side answered it.
  #
  # The machine side is #kind (one of KINDS), #path (rooted at the variable),
  # #coordinate (the schema's name for the slot), #value and #details — see
  # docs/i18n.md for translating them. #message is the developer's English
  # line and is not API. The underlying TypeError/KeyError/ArgumentError is
  # preserved as #cause.
  class InputError < Error
    extend T::Sig

    # The closed vocabulary #kind draws from — one key an app can translate,
    # rather than a sentence it has to parse. Additive only: a new kind
    # arrives in a MINOR release and :refused is the honest home for
    # everything that fits none of them. docs/i18n.md has what each means.
    KINDS = T.let(
      %i[type_mismatch unparseable not_a_member missing unknown out_of_range invalid_format refused].to_set.freeze,
      T::Set[Symbol],
    )

    # The detail keys a kind may carry. Closed, so `I18n.t(..., **details)`
    # never gets a key the app's locale file has no slot for — and so a
    # server can't smuggle arbitrary data in under extensions.input. None of
    # them may be an I18n::RESERVED_KEYS name (`:format` was, which raised
    # I18n::ReservedInterpolationKey on that very splat) — held by a spec.
    DETAILS = T.let(%i[type members min max pattern suggestion].freeze, T::Array[Symbol])

    # The most of any one value this error will hold or spell — per String, at
    # every depth, and per sentence a server wrote. Past it the rest is
    # dropped for "…(N more bytes)". An InputError is built for whatever a
    # caller sent and whatever a server echoed back, either of which can be
    # megabytes, and every raised one writes a warn line as well as landing in
    # #to_h. A kilobyte is far more than a diagnosis needs and far less than a
    # log line can't take.
    VALUE_LIMIT = 1024

    sig { returns(Symbol) }
    attr_reader :kind

    # Rooted at the variable and down through input fields and list indices:
    # ["where", "_and", 0, "_not", "species"]. Every named segment is the
    # SCHEMA's spelling, whichever side refused — a server can produce no
    # other, so one rule covers both halves. Empty when nothing named a slot.
    # #field is its last named segment — the one a form highlights.
    sig { returns(T::Array[T.untyped]) }
    attr_reader :path

    # The GraphQL schema coordinate for the slot — "PetFilter.species". nil
    # where there isn't one: a variable ($count names no schema element), a
    # key the input type doesn't define, or a server that didn't say.
    sig { returns(T.nilable(String)) }
    attr_reader :coordinate

    # The rejected value, through filter_parameters exactly as the message
    # is. nil where it was never known (a missing field has no value, and an
    # unknown key owns no slot to hold one). Always JSON-representable — see
    # json_safe.
    sig { returns(T.untyped) }
    attr_reader :value

    # Kind-specific facts, never pre-formatted: members stays an Array,
    # because joining it is a language decision. Keys are drawn from DETAILS.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    attr_reader :details

    # The generated input struct class where generation produced one, and
    # the GraphQL type name where it didn't — a federation representation
    # builds a plain Hash, so an entity has only its name there. Branch on
    # #to_h's "struct" instead, which is `to_s` either way.
    sig { returns(T.untyped) }
    attr_reader :struct

    sig do
      params(
        message: String,
        kind: Symbol,
        path: T::Array[T.untyped],
        coordinate: T.nilable(String),
        value: T.untyped,
        details: T::Hash[Symbol, T.untyped],
        struct: T.untyped,
        raised: T::Boolean,
      ).void
    end
    def initialize(message, kind: :refused, path: [], coordinate: nil, value: nil,
      details: {}, struct: nil, raised: true)
      unless KINDS.include?(kind)
        raise ArgumentError, "kind: #{kind.inspect} is not an input kind — one of #{KINDS.to_a.join(", ")}"
      end

      @kind = kind
      @path = T.let(path.dup, T::Array[T.untyped])
      @coordinate = coordinate
      @value = T.let(json_safe(value), T.untyped)
      @details = T.let(json_safe(details), T::Hash[Symbol, T.untyped])
      @struct = struct
      @raised = raised
      # the message often IS a sorbet prop error — drop its frame, as CastError does
      super(message.sub(CastError::SORBET_CALLER, ""))
    end

    # `render json: e.to_h` is the documented idiom, and JSON has no spelling
    # for NaN or Infinity — so the crash landed inside the app's error handler,
    # losing the diagnosis and turning a 422 into a 500. The values that get
    # there are precisely the ones Coerce.finite/whole exist to refuse, plus
    # whatever a lenient parser read off a response, so a non-finite Float
    # travels as its to_s and everything else passes through untouched.
    sig { params(value: T.untyped).returns(T.untyped) }
    private def json_safe(value)
      case value
      when Float then value.finite? ? value : value.to_s
      when String then GraphWeaver::Internal::Redact.cap(value)
      when Array then value.map { |element| json_safe(element) }
      when Hash then value.transform_values { |element| json_safe(element) }
      else value
      end
    end

    # The input field the value actually landed on — #path's last *named*
    # segment, which is the coordinate a form can act on. A trailing list
    # index is a position rather than a field, so `["ids", 2]` is still the
    # `ids` field. nil when nothing named a slot.
    sig { returns(T.nilable(String)) }
    def field = T.cast(path.reverse.find { |segment| segment.is_a?(String) }, T.nilable(String))

    # The same refusal one level out: prepend the segment that led here.
    # Every enclosing layer — a list index, an input field, the variable —
    # adds its own on the way out, so the innermost refusal (which wrote the
    # message) ends up holding the whole route. Mutates and returns self:
    # the failure happened once, and a fresh error per layer would write a
    # warn line per layer for it.
    #
    # `prop:` is the same field in Ruby spelling, where it differs: the
    # segment is the schema's name, but filter_parameters is a list the app
    # writes in Ruby, so `api_key` must still match what `apiKey` holds.
    sig { params(segment: T.any(String, Integer), prop: T.any(String, Integer, Symbol)).returns(InputError) }
    def within(segment, prop: segment)
      @path.unshift(segment)
      # a list element has no key of its own — the list's key is the first it
      # meets, and it decides whether the value may be shown
      @value = GraphWeaver::Internal::Redact.value(prop, @value) if segment.is_a?(String)
      self
    end

    sig { override.returns(T::Hash[String, T.untyped]) }
    def to_h
      super.merge(
        "kind" => kind.to_s,
        "path" => path,
        "coordinate" => coordinate,
        "field" => field,
        "value" => value,
        "details" => details.transform_keys(&:to_s),
        "struct" => struct&.to_s,
      ).compact
    end

    sig { override.returns(T::Boolean) }
    private def raised? = @raised
  end

  # The setup doesn't add up — judged against your schema, not against the
  # shape of an argument. Which Ruby schema serves which subgraph is the
  # case that exists: two schemas fit one subgraph, or the one you named
  # doesn't define what the supergraph says that subgraph resolves. A
  # verdict the library reached, so it's under the Error umbrella and a
  # spec helper can rescue it; a plainly wrong argument (`pool_size: must
  # be >= 1`) stays an ArgumentError, as in any Ruby method.
  class ConfigurationError < Error; end

  # Build-time: the query didn't validate against the schema. Carries the
  # structured validation errors (message + line/column) rather than a
  # joined string. Under the Error umbrella like everything else raised
  # here (through 0.1.0 it was an ArgumentError instead).
  class QueryValidationError < Error
    extend T::Sig

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    attr_reader :errors

    sig { params(errors: T::Array[T::Hash[Symbol, T.untyped]]).void }
    def initialize(errors)
      @errors = errors
      super(render(errors))
    end

    sig { override.returns(T::Hash[String, T.untyped]) }
    def to_h
      super.merge("errors" => errors.map { |e| e.transform_keys(&:to_s) })
    end

    # "queries/person.graphql:4:5 Field 'nmae' …" back into its three parts —
    # [path, "line:column", message]. Codegen folds the position (and, when it
    # knows it, the file) into :message, so anything reporting the parts
    # separately splits it back out here rather than growing a second splitter
    # to disagree with. A message with no such prefix passes through whole.
    sig { params(error: T::Hash[Symbol, T.untyped]).returns([T.nilable(String), String, String]) }
    def self.split(error)
      message = error[:message].to_s
      position = [error[:line], error[:column]].compact.join(":")
      return [nil, position, message] if position.empty?

      match = message.match(/\A(?:(?<path>.+):)?#{Regexp.escape(position)} (?<rest>.*)\z/m)
      match ? [match[:path], position, match[:rest]] : [nil, position, message]
    end

    private

    # Compiler-style: the query file once in the header, then one error per
    # line — thirty typos on one joined line is a wall nobody reads.
    sig { params(errors: T::Array[T::Hash[Symbol, T.untyped]]).returns(String) }
    def render(errors)
      entries = errors.map { |error| QueryValidationError.split(error) }
      paths = entries.map(&:first).compact.uniq
      hoisted = paths.one?

      lines = entries.map do |path, position, message|
        prefix = [(path unless hoisted), position].reject { |part| part.nil? || part.empty? }.join(":")
        prefix.empty? ? "  #{message}" : "  #{prefix}  #{message}"
      end
      [hoisted ? "invalid query in #{paths.first}:" : "invalid query:", *lines].join("\n")
    end
  end
end

# reads a server rejection back into InputError values (GraphQLError#input_errors);
# below the classes, since it needs both of them defined
require_relative "internal/server_input"
