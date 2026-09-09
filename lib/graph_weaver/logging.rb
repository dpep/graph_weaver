# typed: true
# frozen_string_literal: true

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

    # Internal: level-gated and lazy — the block only runs when a logger
    # is listening. Messages carry "graph_weaver" as progname.
    def log(level, &block)
      logger&.public_send(level, "graph_weaver", &block)
    end

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

    # Internal: variables with the filtered keys blanked out.
    def filter_variables(variables)
      filters = filter_parameters
      # Array before the duck-type check: Array#filter is Enumerable's, not ours
      return filters.empty? ? variables : scrub(variables, filters) if filters.is_a?(Array)

      filters.nil? ? variables : filters.filter(variables)
    end

    # Internal: run the block, logging "<label> (Nms)" at level — timing
    # skipped entirely when no logger is set. Returns the block's value.
    def log_timed(level, label)
      return yield unless logger

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
      log(level) { "#{label} (#{ms}ms)" }
      result
    end

    # One callable wrapping every request GraphWeaver makes — over the
    # wire or in-process — so an APM can time it and count errors. A
    # no-op until you set one:
    #
    #      GraphWeaver.instrumenter = lambda do |event, payload, &block|
    #        ActiveSupport::Notifications.instrument(event, payload, &block)
    #      end
    #
    # It must call the block and return its value. The only event today
    # is EXECUTE_EVENT; its payload carries :url (nil in-process),
    # :schema (in-process only), :operation (the document's operation
    # name, nil for an anonymous one), and — added after the response
    # lands — :status. Never the query text or the variables: those
    # carry PII and belong at debug on the logger, where they're gated.
    attr_accessor :instrumenter

    # Internal: wrap the block in the instrumenter, if one is set. The
    # payload is a plain Hash the caller may add to inside the block.
    def instrument(event, payload)
      hook = instrumenter
      return yield unless hook

      hook.call(event, payload) { yield }
    end

    private

    def scrub(value, filters)
      case value
      when Hash then value.to_h { |k, v| [k, filtered?(k, filters) ? FILTERED : scrub(v, filters)] }
      when Array then value.map { |v| scrub(v, filters) }
      else value
      end
    end

    def filtered?(key, filters)
      name = key.to_s
      filters.any? do |filter|
        filter.is_a?(Regexp) ? name.match?(filter) : name.downcase.include?(filter.to_s.downcase)
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
  # parsed response, whichever client slot served it.
  EXECUTE_EVENT = "graph_weaver.execute"
end
