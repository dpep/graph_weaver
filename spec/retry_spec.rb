require "graph_weaver/testing"
require_relative "generated/person_query"

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

    person = PersonQuery.execute!(executor, id: "1").person
    expect(person).not_to be_nil
    expect(slept.size).to eq 2
  end

  it "re-raises after tries are exhausted" do
    executor = described_class.new(failure.transport, tries: 3, sleeper:)

    expect {
      PersonQuery.execute(executor, id: "1")
    }.to raise_error(GraphWeaver::TransportError)
    expect(slept.size).to eq 2 # slept between attempts, not after the last
  end

  it "backs off exponentially by default, clamped at max" do
    executor = described_class.new(
      failure.transport,
      tries: 5, base: 1, max: 5, jitter: false, sleeper:,
    )

    expect { PersonQuery.execute(executor, id: "1") }.to raise_error(GraphWeaver::TransportError)
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
    expect(PersonQuery.execute!(five_hundred, id: "1").person).not_to be_nil

    four_oh_one = described_class.new(
      sequence(failure.server(status: 401), fake),
      tries: 2, sleeper:,
    )
    expect {
      PersonQuery.execute(four_oh_one, id: "1")
    }.to raise_error(GraphWeaver::ServerError) # no retry: it's our bug
  end

  it "honors a custom retry_if and error list" do
    only_transport = described_class.new(
      sequence(failure.server(status: 503), fake),
      tries: 3, on: [GraphWeaver::TransportError], sleeper:,
    )

    expect {
      PersonQuery.execute(only_transport, id: "1")
    }.to raise_error(GraphWeaver::ServerError) # ServerError not listed
  end

  it "retries responses carrying retry_codes, returning the last on exhaustion" do
    executor = described_class.new(
      sequence(failure.throttled, fake),
      tries: 2, retry_codes: ["THROTTLED"], sleeper:,
    )
    expect(PersonQuery.execute!(executor, id: "1").person).not_to be_nil
    expect(slept.size).to eq 1

    slept.clear
    exhausted = described_class.new(failure.throttled, tries: 2, retry_codes: ["THROTTLED"], sleeper:)
    response = PersonQuery.execute(exhausted, id: "1")
    expect(response.errors.first&.code).to eq "THROTTLED" # last response returned
  end
end
