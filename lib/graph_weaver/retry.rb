# typed: true
# frozen_string_literal: true

require_relative "errors"

# Wraps any client/transport with configurable retries — it satisfies
# the same execute contract, so it layers over HTTP, Faraday, or
# anything else:
#
#      client = GraphWeaver::Retry.new(
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
#   - ServerError: 5xx, plus 408 and 429 — the rest of 4xx is a bug in
#     the request, retrying won't fix it. Override with
#     retry_if: ->(error) { ... }
#   - responses whose GraphQL error codes intersect retry_codes: (off by
#     default — pass the codes your API uses for transient failures)
#
# A server that answers with Retry-After sets the delay itself (clamped
# to max:); otherwise the configured backoff decides.
#
# Exhausting tries re-raises the last error (or returns the last
# code-matched response).
class GraphWeaver::Retry
  BACKOFFS = {
    exponential: ->(base, attempt) { base * (2**(attempt - 1)) },
    linear: ->(base, attempt) { base * attempt },
  }.freeze

  # a 4xx is a bug in the request — except these two, which are the
  # server asking you to come back later rather than to fix anything
  RETRIABLE_CLIENT_STATUSES = [408, 429].freeze

  # retry 5xx (and 408/429), not the rest of 4xx; everything else listed
  # in on: retries
  DEFAULT_RETRY_IF = lambda do |error|
    !error.is_a?(GraphWeaver::ServerError) ||
      error.status >= 500 || RETRIABLE_CLIENT_STATUSES.include?(error.status)
  end

  def initialize(client, tries: 3, on: [GraphWeaver::TransportError, GraphWeaver::ServerError],
    backoff: :exponential, base: 0.5, max: 30, jitter: true, retry_if: DEFAULT_RETRY_IF,
    retry_codes: [], sleeper: nil)
    raise ArgumentError, "tries: must be >= 1" unless tries >= 1

    @client = client
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
    @client.url if @client.respond_to?(:url)
  end

  def execute(query, variables: {}, operation_name: nil)
    attempt = 0
    failure = T.let(nil, T.nilable(Exception))

    loop do
      attempt += 1
      begin
        response = @client.execute(query, variables:, operation_name:)
        return response unless attempt < @tries && retryable_response?(response)
      rescue *@on => e
        raise if attempt >= @tries || !@retry_if.call(e)

        failure = e
      end

      @sleeper.call(delay(attempt, failure))
      failure = nil
    end
  end

  private

  def retryable_response?(response)
    return false if @retry_codes.empty?

    codes = (response.to_h["errors"] || []).filter_map { |error| error.dig("extensions", "code") }
    codes.intersect?(@retry_codes)
  end

  def delay(attempt, failure = nil)
    # A Retry-After wins over our backoff: the server is the only party
    # that knows when its window reopens, and it isn't guessing. Still
    # clamped to max:, so "come back in an hour" can't park a thread for
    # an hour — and not jittered, since it's an instruction, not a guess.
    after = failure.retry_after if failure.is_a?(GraphWeaver::ServerError)
    return [after, @max].min.to_f if after

    seconds = [@backoff.call(@base, attempt), @max].min.to_f
    @jitter ? seconds * (0.5 + rand * 0.5) : seconds
  end
end
