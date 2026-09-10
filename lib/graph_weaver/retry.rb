# typed: true
# frozen_string_literal: true

require_relative "errors"
require_relative "transport"

# Wraps any client/transport with configurable retries — it satisfies
# the same execute contract, so it layers over HTTP, Faraday, or
# anything else:
#
#      client = GraphWeaver::Retry.new(
#        GraphWeaver::Transport::HTTP.new(url),
#        retries: 5,                      # attempts after the first
#        retry_on: [GraphWeaver::TransportError, GraphWeaver::ServerError],
#        backoff: :exponential,           # or :linear, or ->(attempt) { seconds }
#        base_delay: 0.5, max_delay: 30,  # seconds; delays clamp at max_delay:
#        jitter: true,                    # randomize each delay by 50-100%
#        retry_codes: ["THROTTLED"],      # also retry GraphQL errors by code
#        retry_mutations: true,           # off by default — see below
#      )
#
# `retries:` is how many attempts follow the first; the other retry options
# sit beside it — the same spelling on the client, which passes them
# straight through (`GraphWeaver.new(url, retries: 5, backoff: :linear)`).
# So `retries: 0` is one attempt and no retry.
#
# **A mutation gets one attempt.** A failure with no answer — a read
# timeout, a 502, a reset socket — does not say whether the server applied
# it, and a second `charge` is worse than a failed one. retry_mutations:
# true opts an idempotent API back in.
#
# What retries, by default:
#   - TransportError: always
#   - ServerError: 5xx, plus 408 and 429 — the rest of 4xx is a bug in
#     the request, retrying won't fix it. Override with
#     retry_if: ->(error) { ... }
#   - responses whose GraphQL error codes intersect retry_codes: (off by
#     default — pass the codes your API uses for transient failures)
#
# A server that answers with Retry-After sets the delay itself (clamped
# to max_delay:); otherwise the configured backoff decides.
#
# Exhausting the retries re-raises the last error (or returns the last
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
  # in retry_on: retries
  DEFAULT_RETRY_IF = lambda do |error|
    !error.is_a?(GraphWeaver::ServerError) ||
      error.status >= 500 || RETRIABLE_CLIENT_STATUSES.include?(error.status)
  end

  # said once, where the decision is made and where it is explained
  MUTATION_HINT = "not retrying a mutation — a request that failed without an answer " \
    "may still have been applied; pass retry_mutations: true if yours are idempotent"
  private_constant :DEFAULT_RETRY_IF, :MUTATION_HINT

  def initialize(client, retries: 2, retry_on: [GraphWeaver::TransportError, GraphWeaver::ServerError],
    backoff: :exponential, base_delay: 0.5, max_delay: 30, jitter: true, retry_if: DEFAULT_RETRY_IF,
    retry_codes: [], retry_mutations: false, sleeper: nil)
    raise ArgumentError, "retries: must be >= 0" unless retries.is_a?(Integer) && retries >= 0

    @client = client
    @retries = retries
    @retry_mutations = retry_mutations
    @retry_on = retry_on
    @backoff = if backoff.is_a?(Proc)
      ->(_base, attempt) { backoff.call(attempt) } # custom: ->(attempt) { seconds }
    else
      BACKOFFS.fetch(backoff) {
        raise ArgumentError, "backoff: must be :exponential, :linear, or a Proc, got #{backoff.inspect}"
      }
    end
    @base_delay = base_delay
    @max_delay = max_delay
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
    attempts = mutation?(query) ? 1 : @retries + 1
    attempt = 0
    failure = T.let(nil, T.nilable(Exception))

    loop do
      attempt += 1
      begin
        response = @client.execute(query, variables:, operation_name:)
        return response unless attempt < attempts && retryable_response?(response)
      rescue *@retry_on => e
        if attempt >= attempts || !@retry_if.call(e)
          GraphWeaver::Internal::Log.log(:warn) { MUTATION_HINT } if attempts == 1 && @retries.positive?
          raise
        end

        failure = e
      end

      seconds = delay(attempt, failure)
      # a retry is invisible otherwise: the caller sees one slow call, and the
      # log shows an error that apparently didn't stop anything
      GraphWeaver::Internal::Log.log(:info) do
        "retrying #{operation_name || "query"} in #{seconds.round(2)}s (attempt #{attempt + 1} of #{attempts})"
      end
      @sleeper.call(seconds)
      failure = nil
    end
  end

  private

  def mutation?(query)
    !@retry_mutations && @retries.positive? && GraphWeaver::Internal::Wire.mutation?(query)
  end

  def retryable_response?(response)
    return false if @retry_codes.empty?

    codes = (response.to_h["errors"] || []).filter_map { |error| error.dig("extensions", "code") }
    codes.intersect?(@retry_codes)
  end

  def delay(attempt, failure)
    # A Retry-After wins over our backoff: the server is the only party
    # that knows when its window reopens, and it isn't guessing. Still
    # clamped to max_delay:, so "come back in an hour" can't park a thread for
    # an hour — and not jittered, since it's an instruction, not a guess.
    after = failure.retry_after if failure.is_a?(GraphWeaver::ServerError)
    return [after, @max_delay].min.to_f if after

    seconds = [@backoff.call(@base_delay, attempt), @max_delay].min.to_f
    @jitter ? seconds * (0.5 + rand * 0.5) : seconds
  end
end
