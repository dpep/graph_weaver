# typed: true
# frozen_string_literal: true

require "json"

module GraphWeaver
  class << self
    # Where GraphWeaver narrates what it's doing — anything
    # stdlib-Logger-compatible (Logger, Rails.logger, semantic_logger...).
    # Silent by default; Rails apps get Rails.logger wired by the railtie.
    #
    #      GraphWeaver.logger = Logger.new($stdout, level: Logger::INFO)
    #
    # What logs where:
    #   debug — full queries + variables on the wire, responses
    #           (status/bytes/ms), connection lifecycle, parsed modules
    #   info  — schema introspection and cache decisions, generated files
    #           written, query modules loaded
    #   warn  — every GraphWeaver error raised
    #
    # Queries, variables, and responses appear at debug ONLY — they can
    # carry PII. Auth headers never log.
    attr_accessor :logger

    # What never reaches the log when variables are written at debug. A
    # list of keys — Strings/Symbols match as case-insensitive substrings
    # (`:token` covers `apiToken`), Regexps match themselves — applied at
    # every depth, matched values replaced with "[FILTERED]":
    #
    #      GraphWeaver.filter_parameters = [:password, /token/]
    #
    # Rails apps need none of this: the railtie hands over the app's own
    # config.filter_parameters. Anything answering #filter(hash) is taken
    # as-is, which is how an ActiveSupport::ParameterFilter gets in.
    attr_reader :filter_parameters

    def filter_parameters=(filters)
      unless filters.nil? || filters.is_a?(Array) || filters.respond_to?(:filter)
        raise ArgumentError,
          "filter_parameters: takes a list of keys, or an object answering #filter — got #{filters.inspect}"
      end

      @filter_parameters = filters
    end

    # One callable wrapping every request GraphWeaver makes — over the
    # wire or in-process — so an APM can time it and count errors. A
    # no-op until you set one (Rails sets this one for you):
    #
    #      GraphWeaver.instrumenter = lambda do |event, payload, &block|
    #        ActiveSupport::Notifications.instrument(event, payload, &block)
    #      end
    #
    # It must call the block and return its value. The only event today is
    # EXECUTE_EVENT; its payload is the contract in docs/logging.md —
    # :operation, :client, :kind, :status, :duration_ms, :graph always;
    # :url/:http_status over the wire, :schema in-process, :error/:code on a
    # failure, :retries when a Retry wrapped it. Never the query text or the
    # variables: the payload fans out to subscribers that know none of the
    # filtering rules, so PII belongs at debug on the logger, where the
    # level gates it and filter_parameters scrubs it.
    attr_accessor :instrumenter
  end

  module Internal
    # The message side of filter_parameters. One rule: a message the library
    # composes about a value the caller supplied names that value only when
    # the key it arrived under isn't filtered — so a password's rejection
    # reads "[FILTERED]" in the exception, and in the warn line Error#initialize
    # writes, exactly as it does in the debug log.
    module Redact
      class << self
        # True when a value under this key must not appear in a message.
        # Asked of filter_variables rather than of the list, so the
        # ActiveSupport::ParameterFilter a Rails app hands over answers too.
        def filtered?(key)
          !key.nil? && Log.filter_variables({ key.to_s => nil })[key.to_s] == FILTERED
        end

        # True when this key names a credential — asked of a url's query
        # parameters, which are scrubbed whatever the app's logging appetite.
        # filter_parameters is a knob about log verbosity; emptying it must
        # not un-scrub a token in an endpoint, any more than it un-scrubs the
        # url's userinfo. The app's list widens this; it can't narrow it.
        def credential?(key)
          filtered?(key) || Log.filtered?(key, GraphWeaver::DEFAULT_FILTER_PARAMETERS)
        end

        # `detail` unless the key is filtered — free text a coercer or sorbet
        # wrote can spell a value any way, so for a filtered key none of it
        # survives, not the parts that would have been safe.
        def detail(key, detail) = filtered?(key) ? FILTERED : detail

        # A value the library reports as DATA rather than inside a sentence —
        # InputError#value. Scrubbed at every depth, so a filtered key nested
        # inside an input object is covered too, and the same list decides it
        # as decides the debug log's variables line.
        def value(key, value) = Log.filter_variables({ key.to_s => value })[key.to_s]

        # A value the library spells INTO a sentence. `detail` can only ask
        # about the key the value arrived under, so it reads a filtered key one
        # level in as safe; this scrubs at every depth, like #value. The key is
        # optional because a coercer refusing a value hasn't been told one.
        def shown(raw, key = nil) = filtered?(key) ? FILTERED : cap(spell(value(key, raw)))

        # How a value reads inside a sentence. inspect, except that
        # BigDecimal#inspect is scientific ("0.25e1" for the 2.5 a caller wrote).
        def spell(value) = defined?(BigDecimal) && value.is_a?(BigDecimal) ? value.to_s("F") : value.inspect

        # A short server-chosen string the library republishes inside its own
        # text — the APM's :code, the [CODE] in the one line info writes, a
        # redirect's destination. Control characters are stripped because it
        # lands where the log's own framing lives: a newline in
        # extensions.code forges a second, complete-looking line.
        def tag(value) = value.is_a?(String) ? cap(value.gsub(/[[:cntrl:]]+/, " ")) : value

        # Text the library didn't author — a value a caller sent, a sentence a
        # server wrote — cut to what an error may carry. The number lives on
        # InputError, which is the class that documents it and the one every
        # capped string reaches.
        def cap(text, limit = GraphWeaver::InputError::VALUE_LIMIT)
          return text if text.bytesize <= limit

          # byteslice can land mid-character; scrub drops the partial tail
          "#{text.byteslice(0, limit).scrub("")}…(#{text.bytesize - limit} more bytes)"
        end
      end
    end
  end

  # Rails' spelling, so a scrubbed log reads the same either side of the seam
  FILTERED = "[FILTERED]"

  # Safe before anyone configures anything; substring matching means these
  # already cover apiToken, client_secret, password_confirmation…
  DEFAULT_FILTER_PARAMETERS = %i[password token secret authorization].freeze

  self.filter_parameters = DEFAULT_FILTER_PARAMETERS

  # The one instrumentation event: a single GraphQL request, start to
  # parsed response, whichever client slot served it. `<event>.<namespace>`
  # is how every notification in this ecosystem is spelled
  # (sql.active_record, execute_multiplex.graphql) — it's what
  # ActiveSupport::LogSubscriber.attach_to and an APM's namespace routing
  # key on, so a backwards name made both of them a puzzle.
  EXECUTE_EVENT = "execute.graph_weaver"

  module Internal
    # The emitting half of the narration the three accessors above
    # configure. Setting a logger is API; writing to it is not, and the
    # two read as a pair when they sit on the same object.
    module Log
      # fiber-local, set only for the duration of one attempt (with_retries)
      RETRIES = :graph_weaver_retries
      # fiber-local, set only for the duration of one dispatch (with_graph)
      GRAPH = :graph_weaver_graph

      class << self
        # Level-gated and lazy — the block only runs when a logger is
        # listening. Messages carry "graph_weaver" as progname.
        def log(level, &block)
          GraphWeaver.logger&.public_send(level, "graph_weaver", &block)
        end

        # Run the block, logging "<label> (Nms)" at level — timing skipped
        # entirely when no logger is set. Returns the block's value.
        def log_timed(level, label)
          return yield unless GraphWeaver.logger

          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = yield
          ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
          log(level) { "#{label} (#{ms}ms)" }
          result
        end

        # Wrap the block in the instrumenter, if one is set. The caller
        # supplies what only it knows (:url, :schema, :client); this fills
        # in the half every path shares — how it ended, how long it took,
        # what a Retry had already spent — so one subscriber reads one
        # shape whichever client slot served the request.
        def instrument(event, payload)
          hook = GraphWeaver.instrumenter
          return yield unless hook

          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          retries = Thread.current[RETRIES]
          payload[:retries] = retries if retries
          payload[:graph] = Thread.current[GRAPH]
          # pessimistic, so :status is set even for what a rescue can't
          # see — an Interrupt, a killed thread — and never silently absent
          payload[:status] = :failed

          # One dispatch labels one request. Whatever THIS request reaches —
          # a resolver serving it that calls out — is a request of its own,
          # and the caller's graph would be a wrong label on it.
          with_graph(nil) do
            hook.call(event, payload) do
              result = yield
              errors = response_errors(result)
              if errors.empty?
                payload[:status] = :ok
              else
                payload[:status] = :errors
                code = errors.grep(Hash).filter_map { |e| GraphWeaver::GraphQLError.from_h(e).code }.first
                payload[:code] = Redact.tag(code)
              end
              result
            rescue => e
              payload[:error] = e.class.name
              # :code stays the GraphQL error code and nothing else — it used
              # to hold a ServerError's status here, so one tag carried two
              # dimensions ("THROTTLED" and 429). The number is :http_status.
              raise
            ensure
              payload[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)
            end
          end
        end

        # What a Retry has already spent, read by the attempt it is about
        # to make. A dynamic extent rather than a global: the count is only
        # visible while the call it describes is on the stack, so a client
        # that never reaches instrument can't leave a stale one behind.
        def with_retries(count)
          return yield unless GraphWeaver.instrumenter

          previous = Thread.current[RETRIES]
          Thread.current[RETRIES] = count
          begin
            yield
          ensure
            Thread.current[RETRIES] = previous
          end
        end

        # The graph a generated module is dispatching, read by the request it
        # is about to make. Same dynamic extent as with_retries, for the same
        # reason — and instrument clears it for the duration of the request it
        # labels, so exactly one request wears the label.
        def with_graph(name)
          return yield unless GraphWeaver.instrumenter

          previous = Thread.current[GRAPH]
          Thread.current[GRAPH] = name
          begin
            yield
          ensure
            Thread.current[GRAPH] = previous
          end
        end

        # The variables as one JSON line for a log: filtered, and unable to
        # raise. A value with no JSON form (NaN, binary) is the caller's bug
        # and the transport refuses it a few lines later — but a logger that
        # decides WHICH exception a caller sees, or whether one is raised at
        # all, is worse than a log line that says it couldn't render.
        def variables_for_log(variables)
          JSON.generate(filter_variables(variables))
        rescue StandardError => e
          "<unloggable: #{e.class}>"
        end

        # variables with the filtered keys blanked out
        def filter_variables(variables)
          filters = GraphWeaver.filter_parameters
          # Array before the duck-type check: Array#filter is Enumerable's, not ours
          return filters.empty? ? variables : scrub(variables, filters) if filters.is_a?(Array)

          filters.nil? ? variables : filters.filter(variables)
        end

        # Whether a key matches one of `filters` — the same matching the
        # variables line uses, asked about a list other than the app's so
        # Redact.credential? can hold url parameters to the default names.
        def filtered?(key, filters)
          name = key.to_s
          filters.any? do |filter|
            filter.is_a?(Regexp) ? name.match?(filter) : name.downcase.include?(filter.to_s.downcase)
          end
        end

        private

        # The GraphQL errors a response carries, whatever answered it — a
        # Hash from a transport, a graphql-ruby Result in-process, a fake.
        # Never raises: an instrumenter that decides which exception a
        # caller sees is worse than a missing tag.
        def response_errors(result)
          errors = result.to_h["errors"] if result.respond_to?(:to_h)
          errors.is_a?(Array) ? errors : []
        rescue StandardError
          []
        end

        def scrub(value, filters)
          case value
          when Hash then value.to_h { |k, v| [k, filtered?(k, filters) ? FILTERED : scrub(v, filters)] }
          when Array then value.map { |v| scrub(v, filters) }
          else value
          end
        end
      end
    end
  end
end
