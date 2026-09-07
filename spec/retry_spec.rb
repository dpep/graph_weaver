require "graph_weaver/testing"
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
      tries: 3,
      sleeper:,
    )

    person = PersonQuery.execute!(client: executor, id: "1").person
    expect(person).not_to be_nil
    expect(slept.size).to eq 2
  end

  it "carries the operation name down to the client on every attempt" do
    seen = []
    counting = Class.new do
      define_method(:execute) do |_query, variables: {}, operation_name: nil|
        seen << operation_name
        raise GraphWeaver::TransportError, "nope" if seen.size < 2

        { "data" => { "search" => [] } }
      end
    end.new

    SearchQuery.execute(client: described_class.new(counting, tries: 2, sleeper:), term: "x")
    expect(seen).to eq %w[Search Search]
  end

  it "re-raises after tries are exhausted" do
    executor = described_class.new(failure.transport, tries: 3, sleeper:)

    expect {
      PersonQuery.execute(client: executor, id: "1")
    }.to raise_error(GraphWeaver::TransportError)
    expect(slept.size).to eq 2 # slept between attempts, not after the last
  end

  it "backs off exponentially by default, clamped at max" do
    executor = described_class.new(
      failure.transport,
      tries: 5, base: 1, max: 5, jitter: false, sleeper:,
    )

    expect { PersonQuery.execute(client: executor, id: "1") }.to raise_error(GraphWeaver::TransportError)
    expect(slept).to eq [1.0, 2.0, 4.0, 5.0] # 8 clamps to 5
  end

  it "supports linear and custom backoff" do
    linear = described_class.new(failure.transport, tries: 3, base: 2, backoff: :linear, jitter: false, sleeper:)
    expect { linear.execute("q", variables: {}) }.to raise_error(GraphWeaver::TransportError)
    expect(slept).to eq [2.0, 4.0]

    slept.clear
    custom = described_class.new(failure.transport, tries: 3, backoff: ->(attempt) { attempt * 0.1 }, jitter: false, sleeper:)
    expect { custom.execute("q", variables: {}) }.to raise_error(GraphWeaver::TransportError)
    expect(slept.map { |s| s.round(1) }).to eq [0.1, 0.2]
  end

  it "jitter randomizes within 50-100% of the delay" do
    executor = described_class.new(failure.transport, tries: 2, base: 10, sleeper:)

    expect { executor.execute("q", variables: {}) }.to raise_error(GraphWeaver::TransportError)
    expect(slept.first).to be_between(5.0, 10.0)
  end

  it "retries 5xx but not 4xx by default" do
    five_hundred = described_class.new(
      sequence(failure.server(status: 503), fake),
      tries: 2, sleeper:,
    )
    expect(PersonQuery.execute!(client: five_hundred, id: "1").person).not_to be_nil

    four_oh_one = described_class.new(
      sequence(failure.server(status: 401), fake),
      tries: 2, sleeper:,
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
        sequence(failure.server(status:), fake), tries: 2, sleeper:,
      )
      expect(PersonQuery.execute!(client: executor, id: "1").person).not_to be_nil
    end
  end

  it "waits as long as Retry-After says, in preference to its own backoff" do
    executor = described_class.new(
      sequence(throttling("2"), fake), tries: 2, base: 30, jitter: false, sleeper:,
    )

    expect(PersonQuery.execute!(client: executor, id: "1").person).not_to be_nil
    expect(slept).to eq [2.0] # the server's number, not the 30s backoff
  end

  it "reads an HTTP-date Retry-After, and clamps a long one to max:" do
    at = described_class.new(throttling((Time.now + 5).httpdate), tries: 2, sleeper:)
    expect { PersonQuery.execute(client: at, id: "1") }.to raise_error(GraphWeaver::ServerError)
    expect(slept.first).to be_within(1).of(5)

    slept.clear
    hour = described_class.new(throttling("3600"), tries: 2, max: 30, sleeper:)
    expect { PersonQuery.execute(client: hour, id: "1") }.to raise_error(GraphWeaver::ServerError)
    expect(slept).to eq [30.0]
  end

  it "falls back to its backoff when the server sends no Retry-After" do
    executor = described_class.new(
      sequence(throttling(nil), fake), tries: 2, base: 3, jitter: false, sleeper:,
    )

    expect(PersonQuery.execute!(client: executor, id: "1").person).not_to be_nil
    expect(slept).to eq [3.0]
  end

  it "honors a custom retry_if and error list" do
    only_transport = described_class.new(
      sequence(failure.server(status: 503), fake),
      tries: 3, on: [GraphWeaver::TransportError], sleeper:,
    )

    expect {
      PersonQuery.execute(client: only_transport, id: "1")
    }.to raise_error(GraphWeaver::ServerError) # ServerError not listed
  end

  it "retries responses carrying retry_codes, returning the last on exhaustion" do
    executor = described_class.new(
      sequence(failure.throttled, fake),
      tries: 2, retry_codes: ["THROTTLED"], sleeper:,
    )
    expect(PersonQuery.execute!(client: executor, id: "1").person).not_to be_nil
    expect(slept.size).to eq 1

    slept.clear
    exhausted = described_class.new(failure.throttled, tries: 2, retry_codes: ["THROTTLED"], sleeper:)
    response = PersonQuery.execute(client: exhausted, id: "1")
    expect(response).to have_graphql_error(code: "THROTTLED") # last response returned
  end
end
