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

  # one rule: the operation is prefixed by its graph when the payload names
  # one, so a multi-graph app's log sorts itself without a second line shape
  it "prefixes the operation with its graph" do
    expect(line(operation: "InvoicesQuery", graph: :billing, status: :ok, duration_ms: 12.34))
      .to include "GraphWeaver billing/InvoicesQuery (12.3ms) ok"
  end

  it "leaves the operation bare when no graph was named" do
    expect(line(operation: "PersonQuery", graph: nil, status: :ok, duration_ms: 1.0))
      .to include "GraphWeaver PersonQuery (1.0ms) ok"
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
  # the code is the server's word. Stripped where the payload is built, so
  # the line info writes stays one line and the APM tag stays one tag.
  it "can't be made to forge a second line by a code carrying a newline" do
    forged = "OK\nI, [2026-01-01T00:00:00]  INFO -- graph_weaver: GraphWeaver AdminQuery (1.0ms) ok"
    payload = { operation: "PersonQuery" }
    GraphWeaver.instrumenter = ->(_event, p, &block) { block.call.tap { payload = p } }
    GraphWeaver::Internal::Log.instrument(GraphWeaver::EXECUTE_EVENT, payload) do
      { "data" => nil, "errors" => [{ "message" => "no", "extensions" => { "code" => forged } }] }
    end

    expect(line(**payload).lines.size).to eq 1
  ensure
    GraphWeaver.instrumenter = nil
  end

  it "stands alone: requiring this file is all a hand-rolled subscriber needs" do
    script = 'require "graph_weaver/log_subscriber"; print GraphWeaver::LogSubscriber.name'
    lib = File.expand_path("../lib", __dir__)

    expect(`#{RbConfig.ruby} -I#{lib} -e #{script.inspect} 2>&1`).to eq "GraphWeaver::LogSubscriber"
  end

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
