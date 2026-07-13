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
