# typed: true
# frozen_string_literal: true

require_relative "errors"

# Wraps any executor with configurable retries — composes like every
# other executor, so it layers over HTTP, Faraday, or anything else:
#
#      executor = GraphWeaver::RetryExecutor.new(
#        GraphWeaver::Transport::HTTP.new(url),
#        tries: 5,                        # total attempts, first included
#        on: [GraphWeaver::TransportError, GraphWeaver::ServerError],
#        backoff: :exponential,           # or :linear, or ->(attempt) { seconds }
#        base: 0.5, max: 30,              # seconds; delays clamp at max:
#        jitter: true,                    # randomize each delay by 50-100%
#        retry_codes: ["THROTTLED"],      # also retry GraphQL errors by code
#      )
#
# What retries, by default:
#   - TransportError: always (the request never arrived)
#   - ServerError: only 5xx — a 4xx is a bug in the request, retrying
#     won't fix it. Override with retry_if: ->(error) { ... }
#   - responses whose GraphQL error codes intersect retry_codes: (off by
#     default — pass the codes your API uses for transient failures)
#
# Exhausting tries re-raises the last error (or returns the last
# code-matched response).
class GraphWeaver::RetryExecutor
  BACKOFFS = {
    exponential: ->(base, attempt) { base * (2**(attempt - 1)) },
    linear: ->(base, attempt) { base * attempt },
  }.freeze

  # retry 5xx, not 4xx; everything else listed in on: retries
  DEFAULT_RETRY_IF = lambda do |error|
    !error.is_a?(GraphWeaver::ServerError) || error.status >= 500
  end

  def initialize(executor, tries: 3, on: [GraphWeaver::TransportError, GraphWeaver::ServerError],
    backoff: :exponential, base: 0.5, max: 30, jitter: true, retry_if: DEFAULT_RETRY_IF,
    retry_codes: [], sleeper: nil)
    raise ArgumentError, "tries: must be >= 1" unless tries >= 1

    @executor = executor
    @tries = tries
    @on = on
    @backoff = if backoff.is_a?(Proc)
      ->(_base, attempt) { backoff.call(attempt) } # custom: ->(attempt) { seconds }
    else
      BACKOFFS.fetch(backoff) {
        raise ArgumentError, "backoff: must be :exponential, :linear, or a Proc, got #{backoff.inspect}"
      }
    end
    @base = base
    @max = max
    @jitter = jitter
    @retry_if = retry_if
    @retry_codes = retry_codes
    @sleeper = sleeper || ->(seconds) { sleep(seconds) }
  end

  # surface the wrapped transport's endpoint (schema-dump provenance)
  def url
    @executor.url if @executor.respond_to?(:url)
  end

  def execute(query, variables: {})
    attempt = 0

    loop do
      attempt += 1
      begin
        response = @executor.execute(query, variables:)
        return response unless attempt < @tries && retryable_response?(response)
      rescue *@on => e
        raise if attempt >= @tries || !@retry_if.call(e)
      end

      @sleeper.call(delay(attempt))
    end
  end

  private

  def retryable_response?(response)
    return false if @retry_codes.empty?

    codes = (response.to_h["errors"] || []).filter_map { |error| error.dig("extensions", "code") }
    codes.intersect?(@retry_codes)
  end

  def delay(attempt)
    seconds = [@backoff.call(@base, attempt), @max].min.to_f
    @jitter ? seconds * (0.5 + rand * 0.5) : seconds
  end
end
