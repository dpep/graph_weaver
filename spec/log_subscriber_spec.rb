# typed: ignore — GraphWeaver::LogSubscriber is defined against ActiveSupport, which sorbet can't resolve here
require "logger"
require "stringio"

require "graph_weaver/log_subscriber"

describe GraphWeaver::LogSubscriber do
  # what ActiveSupport hands a subscriber — the payload the instrumenter
  # filled in, plus its own timing for one that carries none
  module LogSubscriberDemo
    Event = Struct.new(:payload, :duration)
  end

  let(:io) { StringIO.new }

  around do |example|
    GraphWeaver.logger = Logger.new(io, level: Logger::INFO)
    example.run
  ensure
    GraphWeaver.logger = nil
  end

  # `elapsed:` is ActiveSupport's own timing, which only matters when the
  # payload carries no duration_ms of its own
  def line(elapsed: 12.34, **payload)
    io.truncate(io.rewind) # one example asks twice; the second answer is its own
    described_class.new.execute(LogSubscriberDemo::Event.new(payload, elapsed))
    io.string
  end

  it "writes one line per operation: what ran, how long, how it ended" do
    expect(line(operation: "PersonQuery", status: :ok, duration_ms: 12.34))
      .to include "GraphWeaver PersonQuery (12.3ms) ok"
  end

  # an anonymous document still has to name something, or the line is a
  # duration with no subject
  it "says query for an operation with no name" do
    expect(line(operation: nil, status: :ok, duration_ms: 3.0)).to include "GraphWeaver query (3.0ms) ok"
  end

  # the code is the difference between "the API is throttling us" and "we
  # shipped a broken query", which is the whole triage
  it "names the code when the response carried GraphQL errors" do
    expect(line(operation: "PersonQuery", status: :errors, code: "THROTTLED", duration_ms: 8.1))
      .to include "GraphWeaver PersonQuery (8.1ms) errors [THROTTLED]"
  end

  it "names the error class, and a ServerError's status, on a failure" do
    expect(line(operation: "PersonQuery", status: :failed, error: "GraphWeaver::ServerError",
      code: 502, duration_ms: 31.2))
      .to include "GraphWeaver PersonQuery (31.2ms) failed GraphWeaver::ServerError [502]"

    expect(line(operation: "PersonQuery", status: :failed, error: "GraphWeaver::TransportError",
      duration_ms: 31.2)).to include "failed GraphWeaver::TransportError"
  end

  # a retried call is one line per attempt; without the count they read as
  # three unrelated slow requests instead of one that took three goes
  it "says which attempt it was when a Retry is in the stack" do
    expect(line(operation: "PersonQuery", status: :ok, retries: 2, duration_ms: 5.0))
      .to include "GraphWeaver PersonQuery (5.0ms) ok (retry 2)"
    expect(line(operation: "PersonQuery", status: :ok, retries: 0, duration_ms: 5.0))
      .not_to include "retry"
  end

  # a subscriber attached to someone else's instrumenter still gets a line
  it "falls back to the framework's timing when the payload carries none" do
    expect(line(elapsed: 7.77, operation: "PersonQuery", status: :ok)).to include "(7.8ms)"
  end

  # GraphWeaver.logger = nil is the documented way to silence the gem, and
  # ActiveSupport::LogSubscriber#call skips a subscriber whose logger is nil
  it "answers GraphWeaver's logger, so silencing the gem silences this too" do
    expect(described_class.new.logger).to be GraphWeaver.logger

    GraphWeaver.logger = nil
    expect(described_class.new.logger).to be_nil
  end

  # info is the whole rule: this line is the only one at info, so a
  # production log gets one per operation and the wire stays at debug
  it "is quiet below info" do
    GraphWeaver.logger = Logger.new(io, level: Logger::WARN)

    expect(line(operation: "PersonQuery", status: :ok, duration_ms: 1.0)).to eq ""
  end
end
