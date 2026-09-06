require "logger"
require "stringio"
require "tmpdir"

describe "GraphWeaver.logger" do
  include_context "graphql http server"

  let(:io) { StringIO.new }
  let(:executor) { GraphWeaver::Transport::HTTP.new(url) }

  around do |example|
    GraphWeaver.logger = Logger.new(io, level: Logger::DEBUG)
    example.run
  ensure
    GraphWeaver.logger = nil
  end

  it "narrates the wire at debug: connection, query, response" do
    executor.execute("query { people { name } }", variables: {})

    expect(io.string).to include("connecting to 127.0.0.1")
    expect(io.string).to include("POST #{url}")
    expect(io.string).to include("query { people { name } }")
    expect(io.string).to match(/POST .* completed \(\d+ms\)/)
    expect(io.string).to match(/HTTP 200 .* \(\d+ bytes\)/)
  end

  it "tags each request's lines with an id and the operation name" do
    executor.execute("query LoggedPeople { people { name } }", variables: {})

    tag = io.string[/\[req \d+ LoggedPeople\]/]
    expect(tag).not_to be_nil
    expect(io.string.scan(tag).size).to eq 3 # request, timing, status
  end

  it "truncates long queries at debug (introspection dumps)" do
    executor.execute("query Big { people { #{"name " * 300}} }", variables: {})

    expect(io.string).to match(/truncated, \d+ bytes total/)
    expect(io.string).not_to include("name " * 300)
  end

  it "logs schema introspection and cache decisions at info" do
    Dir.mktmpdir do |dir|
      cache = File.join(dir, "schema.json")

      GraphWeaver::SchemaLoader.introspect(executor, cache:)
      expect(io.string).to include("schema cache miss: #{cache}")
      expect(io.string).to match(/introspected .* \(\d+ms\)/)
      expect(io.string).to include("wrote schema cache: #{cache}")

      GraphWeaver::SchemaLoader.introspect(executor, cache:)
      expect(io.string).to include("schema cache hit: #{cache}")
    end
  end

  it "notes parsed and loaded query modules" do
    client = GraphWeaver.new(Demo::Schema)
    client.parse("query People { people { name } }")
    expect(io.string).to include("parsed People (dynamic module")

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "logged_people.graphql"), "query { people { name } }")
      client.load_queries!(dir)
      expect(io.string).to include("loaded LoggedPeopleQuery from")
    end
  end

  it "warns on every raised error" do
    bad = GraphWeaver::Transport::HTTP.new("http://127.0.0.1:#{@port}/nope")
    expect { bad.execute("query { x }") }.to raise_error(GraphWeaver::ServerError)
    expect(io.string).to include("GraphWeaver::ServerError: HTTP 404")

    expect { GraphWeaver.parse(schema: Demo::Schema, query: "{ nope }") }
      .to raise_error(GraphWeaver::ValidationError)
    expect(io.string).to include("GraphWeaver::ValidationError: invalid query")
  end

  it "stays silent and lazy without a logger" do
    GraphWeaver.logger = nil
    expect { GraphWeaver.log(:debug) { raise "never evaluated" } }.not_to raise_error
    expect(GraphWeaver.log_timed(:debug, "label") { 42 }).to eq 42
  end
end

describe "GraphWeaver.instrumenter" do
  include_context "graphql http server"

  let(:events) { [] }

  around do |example|
    # the shape an ActiveSupport::Notifications adapter has
    GraphWeaver.instrumenter = lambda do |event, payload, &block|
      events << [event, payload]
      block.call
    end
    example.run
  ensure
    GraphWeaver.instrumenter = nil
  end

  it "wraps a request over the wire, naming the operation and the status" do
    result = GraphWeaver::Transport::HTTP.new(url).execute("query Wired { people { name } }")

    expect(result).to have_key "data" # the block's value passes through
    expect(events.size).to eq 1
    event, payload = events.first
    expect(event).to eq GraphWeaver::EXECUTE_EVENT
    expect(payload[:url]).to eq url
    expect(payload[:operation]).to eq "Wired"
    expect(payload[:status]).to eq 200 # set inside the block, APM-style
  end

  it "wraps an in-process request through the same seam" do
    GraphWeaver::InProcess.new(Demo::Schema).execute("query Local { people { name } }")

    _event, payload = events.first
    expect(payload[:schema]).to eq "Demo::Schema"
    expect(payload[:operation]).to eq "Local"
    expect(payload[:url]).to be_nil
  end

  it "carries the query text and variables nowhere near the payload (PII)" do
    GraphWeaver::Transport::HTTP.new(url).execute(
      "query { person(id: $id) { name } }", variables: { "id" => "1" }
    )

    expect(events.first.last.values.join).not_to include("person")
  end

  it "lets a failure propagate, so the hook can record it" do
    bad = GraphWeaver::Transport::HTTP.new("http://127.0.0.1:#{@port}/nope")

    expect { bad.execute("query { x }") }.to raise_error(GraphWeaver::ServerError)
    expect(events.size).to eq 1
  end

  it "is a no-op when unset" do
    GraphWeaver.instrumenter = nil

    expect(GraphWeaver.instrument("x", {}) { 42 }).to eq 42
  end
end
