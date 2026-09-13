require "graph_weaver/testing"
require_relative "generated/adopt_mutation"
require_relative "generated/person_query"
require_relative "generated/search_query"

describe GraphWeaver::Retry do
  let(:failure) { GraphWeaver::Testing::Failure }
  let(:fake) { GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1) }
  let(:slept) { [] }
  let(:sleeper) { ->(seconds) { slept << seconds } }

  def sequence(*executors)
    GraphWeaver::Testing::Sequence.new(*executors)
  end

  it "retries transport failures and succeeds" do
    executor = described_class.new(
      sequence(failure.transport, failure.transport, fake),
      retries: 2,
      sleeper:,
    )

    person = PersonQuery.execute!(client: executor, id: "1").person
    expect(person).not_to be_nil
    expect(slept.size).to eq 2
  end

  it "carries the operation name and the variables down to the client on every attempt" do
    seen = []
    counting = Class.new do
      define_method(:execute) do |_query, variables: {}, operation_name: nil|
        seen << [operation_name, variables]
        raise GraphWeaver::TransportError, "nope" if seen.size < 2

        { "data" => { "search" => [] } }
      end
    end.new

    SearchQuery.execute(client: described_class.new(counting, retries: 1, sleeper:), term: "x")
    expect(seen).to eq [["Search", { "term" => "x" }]] * 2
  end

  # A retry is invisible otherwise: the caller sees one slow call, and the log
  # shows an error that apparently didn't stop anything.
  it "logs which attempt it is retrying, and how long it is waiting" do
    io = StringIO.new
    GraphWeaver.logger = Logger.new(io, level: Logger::INFO)
    executor = described_class.new(
      sequence(failure.transport, fake), retries: 1, base_delay: 0.125, jitter: false, sleeper:,
    )

    PersonQuery.execute!(client: executor, id: "1")

    # rounded where the number is built, so the log says 0.13 and not 0.125
    expect(io.string).to include "retrying PersonQuery in 0.13s (attempt 2 of 2)"
  ensure
    GraphWeaver.logger = nil
  end

  # the count is attempts-after-the-first everywhere, so 0 means "never retry"
  it "counts retries after the first attempt" do
    expect { PersonQuery.execute(client: described_class.new(failure.transport, retries: 0, sleeper:), id: "1") }
      .to raise_error(GraphWeaver::TransportError)
    expect(slept).to be_empty

    expect { described_class.new(fake, retries: -1) }.to raise_error(ArgumentError, /retries: must be >= 0/)
    expect { described_class.new(fake, retries: 1.5) }.to raise_error(ArgumentError, /retries: must be >= 0/)
  end

  it "re-raises after the retries are exhausted" do
    executor = described_class.new(failure.transport, retries: 2, sleeper:)

    expect {
      PersonQuery.execute(client: executor, id: "1")
    }.to raise_error(GraphWeaver::TransportError)
    expect(slept.size).to eq 2 # slept between attempts, not after the last
  end

  it "backs off exponentially by default, clamped at max_delay" do
    executor = described_class.new(
      failure.transport,
      retries: 4, base_delay: 1, max_delay: 5, jitter: false, sleeper:,
    )

    expect { PersonQuery.execute(client: executor, id: "1") }.to raise_error(GraphWeaver::TransportError)
    expect(slept).to eq [1.0, 2.0, 4.0, 5.0] # 8 clamps to 5
  end

  it "supports linear and custom backoff" do
    linear = described_class.new(failure.transport, retries: 2, base_delay: 2, backoff: :linear, jitter: false, sleeper:)
    expect { linear.execute("q", variables: {}) }.to raise_error(GraphWeaver::TransportError)
    expect(slept).to eq [2.0, 4.0]

    slept.clear
    custom = described_class.new(failure.transport, retries: 2, backoff: ->(attempt) { attempt * 0.1 }, jitter: false, sleeper:)
    expect { custom.execute("q", variables: {}) }.to raise_error(GraphWeaver::TransportError)
    expect(slept.map { |s| s.round(1) }).to eq [0.1, 0.2]
  end

  it "jitter randomizes within 50-100% of the delay" do
    executor = described_class.new(failure.transport, retries: 1, base_delay: 10, sleeper:)

    expect { executor.execute("q", variables: {}) }.to raise_error(GraphWeaver::TransportError)
    expect(slept.first).to be_between(5.0, 10.0)
  end

  it "retries 5xx but not 4xx by default" do
    five_hundred = described_class.new(
      sequence(failure.server(status: 503), fake),
      retries: 1, sleeper:,
    )
    expect(PersonQuery.execute!(client: five_hundred, id: "1").person).not_to be_nil

    four_oh_one = described_class.new(
      sequence(failure.server(status: 401), fake),
      retries: 1, sleeper:,
    )
    expect {
      PersonQuery.execute(client: four_oh_one, id: "1")
    }.to raise_error(GraphWeaver::ServerError) # no retry: it's our bug
  end

  # Failure.server sends no headers, so build the throttling server here
  def throttling(retry_after, status: 429)
    headers = retry_after ? { "retry-after" => retry_after } : {}
    Class.new do
      define_method(:execute) do |_query, variables: {}, operation_name: nil|
        raise GraphWeaver::ServerError.new(status:, body: "slow down", headers:)
      end
    end.new
  end

  it "retries 429 and 408 — the server asking for later, not a bad request" do
    [429, 408].each do |status|
      executor = described_class.new(
        sequence(failure.server(status:), fake), retries: 1, sleeper:,
      )
      expect(PersonQuery.execute!(client: executor, id: "1").person).not_to be_nil
    end
  end

  it "waits as long as Retry-After says, in preference to its own backoff" do
    executor = described_class.new(
      sequence(throttling("2"), fake), retries: 1, base_delay: 30, jitter: false, sleeper:,
    )

    expect(PersonQuery.execute!(client: executor, id: "1").person).not_to be_nil
    expect(slept).to eq [2.0] # the server's number, not the 30s backoff
  end

  it "reads an HTTP-date Retry-After, and clamps a long one to max_delay:" do
    at = described_class.new(throttling((Time.now + 5).httpdate), retries: 1, sleeper:)
    expect { PersonQuery.execute(client: at, id: "1") }.to raise_error(GraphWeaver::ServerError)
    expect(slept.first).to be_within(1).of(5)

    slept.clear
    hour = described_class.new(throttling("3600"), retries: 1, max_delay: 30, sleeper:)
    expect { PersonQuery.execute(client: hour, id: "1") }.to raise_error(GraphWeaver::ServerError)
    expect(slept).to eq [30.0]
  end

  it "falls back to its backoff when the server sends no Retry-After" do
    executor = described_class.new(
      sequence(throttling(nil), fake), retries: 1, base_delay: 3, jitter: false, sleeper:,
    )

    expect(PersonQuery.execute!(client: executor, id: "1").person).not_to be_nil
    expect(slept).to eq [3.0]
  end

  # A read timeout, a 502 from a proxy, a reset socket: the request may
  # already have been applied, and a second `charge` is worse than a failure.
  describe "mutations" do
    let(:attempts) { [] }

    def counting
      Class.new do
        define_method(:initialize) { |attempts| @attempts = attempts }
        define_method(:execute) do |query, variables: {}, operation_name: nil|
          @attempts << query
          raise GraphWeaver::TransportError, "Net::ReadTimeout: execution expired"
        end
      end.new(attempts)
    end

    it "does not retry a mutation" do
      executor = described_class.new(counting, retries: 2, sleeper:)

      expect { AdoptMutation.execute(client: executor, input: { name: "Rex", species: "DOG" }) }
        .to raise_error(GraphWeaver::TransportError)
      expect(attempts.size).to eq 1
      expect(slept).to be_empty
    end

    it "retries one when the caller says it is idempotent" do
      executor = described_class.new(counting, retries: 2, retry_mutations: true, sleeper:)

      expect { AdoptMutation.execute(client: executor, input: { name: "Rex", species: "DOG" }) }
        .to raise_error(GraphWeaver::TransportError)
      expect(attempts.size).to eq 3
    end

    it "says why it stopped at one attempt" do
      io = StringIO.new
      GraphWeaver.logger = Logger.new(io, level: Logger::WARN)

      expect { described_class.new(counting, retries: 2, sleeper:).execute("mutation { adopt { id } }") }
        .to raise_error(GraphWeaver::TransportError)

      expect(io.string).to include("retry_mutations: true")
    ensure
      GraphWeaver.logger = nil
    end
  end

  # A delay that isn't a delay would reach Kernel#sleep, which raises
  # ArgumentError — so a typo in one option reports as a bug somewhere else,
  # and the failure being retried is lost entirely.
  describe "a delay that can't be waited" do
    it "refuses a negative base_delay: or max_delay: where the typo is" do
      expect { described_class.new(fake, base_delay: -5) }
        .to raise_error(ArgumentError, "base_delay: must be >= 0, got -5")
      expect { described_class.new(fake, max_delay: -1) }
        .to raise_error(ArgumentError, "max_delay: must be >= 0, got -1")
    end

    # a custom backoff: is the caller's arithmetic, so it can't be refused up
    # front — but it must not be able to kill the loop it is steering
    it "clamps a custom backoff's negative to no wait at all" do
      executor = described_class.new(
        sequence(failure.transport, fake), retries: 1, backoff: ->(_attempt) { -30 }, sleeper:,
      )

      expect(PersonQuery.execute!(client: executor, id: "1").person).not_to be_nil
      expect(slept).to eq [0.0]
    end
  end

  it "honors a custom retry_if and error list" do
    only_transport = described_class.new(
      sequence(failure.server(status: 503), fake),
      retries: 2, retry_on: [GraphWeaver::TransportError], sleeper:,
    )

    expect {
      PersonQuery.execute(client: only_transport, id: "1")
    }.to raise_error(GraphWeaver::ServerError) # ServerError not listed
  end

  it "retries responses carrying retry_codes, returning the last on exhaustion" do
    executor = described_class.new(
      sequence(failure.throttled, fake),
      retries: 1, retry_codes: ["THROTTLED"], sleeper:,
    )
    expect(PersonQuery.execute!(client: executor, id: "1").person).not_to be_nil
    expect(slept.size).to eq 1

    slept.clear
    exhausted = described_class.new(failure.throttled, retries: 1, retry_codes: ["THROTTLED"], sleeper:)
    response = PersonQuery.execute(client: exhausted, id: "1")
    expect(response).to have_graphql_error(code: "THROTTLED") # last response returned
  end

  # retry_codes: reads every response, including the ones it has nothing to
  # say about — a server that answers cleanly, and an error carrying no
  # extensions at all, both go through the same reader.
  it "leaves a response alone when its codes aren't the ones listed" do
    answers = [
      { "data" => { "person" => nil } },
      { "data" => nil, "errors" => [{ "message" => "no extensions here" }] },
      { "data" => nil, "errors" => [{ "message" => "nope", "extensions" => { "code" => "FORBIDDEN" } }] },
    ]
    served = Class.new do
      define_method(:initialize) { |answers| @answers = answers }
      define_method(:execute) { |_query, variables: {}, operation_name: nil| @answers.shift }
    end

    answers.each do |answer|
      executor = described_class.new(served.new([answer]), retries: 2, retry_codes: ["THROTTLED"], sleeper:)

      expect { PersonQuery.execute(client: executor, id: "1") }.not_to raise_error
      expect(slept).to be_empty # answered once, and taken at its word
    end
  end

  # Behind an Apollo Router every answer is a GraphQL errors body, retryable
  # or not: rate limiting is 503 + REQUEST_RATE_LIMITED, a router fault is
  # 500 + its own code, a rejected credential is 401 + UNAUTHENTICATED. A
  # rule that let the body win over the status retried none of them, so a
  # configured retry policy made exactly one attempt. Shapes measured
  # against a real router (v2.17.0), replayed here on a real socket.
  context "a status that arrived with a GraphQL errors body" do
    include_context "raw http server"

    # The raw server closes after one request, and a retry that reuses the
    # pooled socket races that close (Ruby 3.3's net/http raises EOFError
    # where 3.4 reconnects) — say so in the response, as a real server would,
    # so every attempt opens its own connection. This context is about
    # statuses; the keep-alive race has its own spec in transport_wire_spec.
    def answer(status, body)
      http_response(status, body, "Connection" => "close")
    end

    def rate_limited(status)
      answer(status, '{"errors":[{"message":"Your request has been rate limited",' \
        '"extensions":{"code":"REQUEST_RATE_LIMITED"}}]}')
    end

    def attempts_against(body, **options)
      url = serving { |socket| socket.write(body) }
      executor = described_class.new(GraphWeaver::Transport::HTTP.new(url), sleeper:, **options)
      before = raw_requests.size
      [PersonQuery.execute(client: executor, id: "1"), raw_requests.size - before]
    end

    it "retries the router's 503, and hands back the last answer it got" do
      response, attempts = attempts_against(rate_limited(503), retries: 2)

      expect(attempts).to eq 3
      expect(response).to have_graphql_error(code: "REQUEST_RATE_LIMITED")
    end

    it "retries a router's own 500" do
      body = answer(500, '{"errors":[{"message":"service unavailable",' \
        '"extensions":{"code":"SERVICE_UNAVAILABLE"}}]}')
      _response, attempts = attempts_against(body, retries: 1)

      expect(attempts).to eq 2
    end

    # the other half of the rule: a 4xx that isn't 408/429 is a bug in the
    # request, and a body full of errors doesn't make it worth repeating
    it "leaves a 401 alone" do
      body = answer(401, '{"errors":[{"message":"Unauthenticated",' \
        '"extensions":{"code":"UNAUTHENTICATED"}}]}')
      response, attempts = attempts_against(body, retries: 3)

      expect(attempts).to eq 1
      expect(response).to have_graphql_error(code: "UNAUTHENTICATED")
    end

    # A router that gives up on a slow subgraph answers 200 with partial
    # data and GATEWAY_TIMEOUT. The caller already has an answer — repeating
    # the query is a judgment only the caller can make, so it takes
    # retry_codes: to opt in.
    it "leaves a 200 that carried a timeout alone" do
      body = answer(200, '{"data":{"person":null},"errors":[{"message":"timed out",' \
        '"extensions":{"code":"GATEWAY_TIMEOUT"}}]}')
      _response, attempts = attempts_against(body, retries: 3)

      expect(attempts).to eq 1

      _response, opted_in = attempts_against(body, retries: 1, retry_codes: ["GATEWAY_TIMEOUT"])
      expect(opted_in).to eq 2
    end

    # retry_mutations: governs the attempt budget before any of this is asked
    it "still gives a mutation one attempt" do
      url = serving { |socket| socket.write(rate_limited(503)) }
      executor = described_class.new(GraphWeaver::Transport::HTTP.new(url), retries: 3, sleeper:)

      AdoptMutation.execute(client: executor, input: { name: "Rex", species: "DOG" })
      expect(raw_requests.size).to eq 1
    end

    # THROTTLE_CODES is what a caller passes to retry_codes: and what
    # #throttled? reads, and the router's own code was in neither
    it "answers throttled? for the code the router sends" do
      response, = attempts_against(rate_limited(503), retries: 0)

      expect(response.errors.first.throttled?).to be true
      expect(GraphWeaver::GraphQLError::THROTTLE_CODES).to include "REQUEST_RATE_LIMITED"
    end
  end

  # A retry policy nobody can read is a retry policy nobody trusts, so
  # docs/transports.md spells the default out — which puts the same two
  # statuses and the same backoff names in a second file.
  it "documents the policy it defaults to" do
    docs = File.read(File.expand_path("../docs/transports.md", __dir__))

    expect(described_class::RETRIABLE_CLIENT_STATUSES.reject { |s| docs.include?(s.to_s) }).to be_empty
    expect(described_class::BACKOFFS.keys.reject { |name| docs.include?(":#{name}") }).to be_empty
  end

  # The client lists these one by one rather than sweeping up a Hash, so
  # an option added here is silently unreachable until it is added there.
  it "has every option spelled the same on the client" do
    keywords = ->(klass) {
      klass.instance_method(:initialize).parameters.filter_map { |kind, name| name if kind == :key }
    }

    expect(keywords[described_class] - keywords[GraphWeaver::Client]).to be_empty
  end
end
