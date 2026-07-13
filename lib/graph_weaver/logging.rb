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
  end
end
