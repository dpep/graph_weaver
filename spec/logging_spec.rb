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

  describe "filtered variables" do
    # debug gets turned on during an incident, and that is exactly when a
    # login mutation's variables must not land in the log
    it "scrubs sensitive values by default, at any depth" do
      executor.execute(
        "query { people { name } }",
        variables: { "password" => "hunter2", "input" => { "apiToken" => "t0k", "name" => "Daniel" } },
      )

      expect(io.string).not_to include("hunter2")
      expect(io.string).not_to include("t0k")
      expect(io.string).to include("[FILTERED]")
      expect(io.string).to include("Daniel") # everything else still logs
    end

    it "takes a configured list, matching keys case-insensitively" do
      GraphWeaver.filter_parameters = [:ssn, /\Acustom/]
      executor.execute(
        "query { people { name } }",
        variables: { "SSN" => "123-45-6789", "customField" => "x", "password" => "hunter2" },
      )

      expect(io.string).not_to include("123-45-6789")
      expect(io.string).not_to include("customField\":\"x")
      expect(io.string).to include("hunter2") # the list replaces the default
    ensure
      GraphWeaver.filter_parameters = GraphWeaver::DEFAULT_FILTER_PARAMETERS
    end

    # a Rails app already declared what is sensitive; ParameterFilter answers
    # #filter, so the railtie hands one straight in
    it "delegates to any object that answers #filter" do
      GraphWeaver.filter_parameters = Class.new do
        def filter(_variables) = { "everything" => "[GONE]" }
      end.new
      executor.execute("query { people { name } }", variables: { "password" => "hunter2" })

      expect(io.string).to include("[GONE]")
      expect(io.string).not_to include("hunter2")
    ensure
      GraphWeaver.filter_parameters = GraphWeaver::DEFAULT_FILTER_PARAMETERS
    end
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

  it "names the scalars generation left as T.untyped" do
    GraphWeaver.parse(schema: Demo::Schema, query: "query Meta { people { pets { metadata } } }")

    expect(io.string)
      .to include("1 unregistered custom scalar → T.untyped: Metadata (register with GraphWeaver.register_scalar)")
  end

  it "warns on every raised error" do
    bad = GraphWeaver::Transport::HTTP.new("http://127.0.0.1:#{@port}/nope")
    expect { bad.execute("query { x }") }.to raise_error(GraphWeaver::ServerError)
    expect(io.string).to include("GraphWeaver::ServerError: HTTP 404")

    expect { GraphWeaver.parse(schema: Demo::Schema, query: "{ nope }") }
      .to raise_error(GraphWeaver::QueryValidationError)
    expect(io.string).to include("GraphWeaver::QueryValidationError: invalid query")
  end

  # debug is the loudest level and the one an incident turns on — the token
  # has to survive both a success and a failure there
  it "never logs the auth header, at any level" do
    headers = { "Authorization" => "Bearer s3cret" }
    GraphWeaver::Transport::HTTP.new(url, headers:).execute("query { people { name } }")

    bad = GraphWeaver::Transport::HTTP.new("http://127.0.0.1:#{@port}/nope", headers:)
    expect { bad.execute("query { x }") }.to raise_error(GraphWeaver::ServerError)

    expect(io.string).not_to include("s3cret")
  end

  it "stays silent and lazy without a logger" do
    GraphWeaver.logger = nil
    expect { GraphWeaver::Internal::Log.log(:debug) { raise "never evaluated" } }.not_to raise_error
    expect(GraphWeaver::Internal::Log.log_timed(:debug, "label") { 42 }).to eq 42
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

  def payload = events.first.last

  it "wraps a request over the wire, naming the operation and how it ended" do
    result = GraphWeaver::Transport::HTTP.new(url).execute("query Wired { people { name } }")

    expect(result).to have_key "data" # the block's value passes through
    expect(events.size).to eq 1
    expect(events.first.first).to eq GraphWeaver::EXECUTE_EVENT
    expect(payload[:url]).to eq url
    expect(payload[:operation]).to eq "Wired"
    expect(payload[:client]).to eq GraphWeaver::Transport::HTTP
    expect(payload[:status]).to eq :ok
    expect(payload[:http_status]).to eq 200
    expect(payload[:duration_ms]).to be_a(Float).and be >= 0
  end

  # the whole point of one seam: a subscriber reads one shape, and the keys
  # that vary are the ones that can't mean anything on the other side
  it "wraps an in-process request through the same seam" do
    GraphWeaver::InProcess.new(Demo::Schema).execute("query Local { people { name } }")

    expect(payload[:schema]).to eq "Demo::Schema"
    expect(payload[:client]).to eq GraphWeaver::InProcess
    expect(payload[:operation]).to eq "Local"
    expect(payload[:status]).to eq :ok
    expect(payload[:url]).to be_nil
    expect(payload[:http_status]).to be_nil
  end

  # a 200 carrying GraphQL errors is not a success, and the code is what an
  # alert groups by — a THROTTLED spike and a broken deploy look identical
  # from the status alone
  it "separates a response that carried GraphQL errors from a clean one" do
    GraphWeaver::InProcess.new(Demo::Schema).execute("query Broken { nope }")

    expect(payload[:status]).to eq :errors
    expect(payload[:code]).to eq "undefinedField"
  end

  # the code is the server's word, and it lands where the log's own framing
  # lives — as a tag on an APM metric and inside the one line info writes
  it "strips control characters out of a server-chosen code" do
    forged = "OK\nI, [2026-01-01T00:00:00]  INFO -- graph_weaver: GraphWeaver AdminQuery (1.0ms) ok"
    GraphWeaver::Internal::Log.instrument(GraphWeaver::EXECUTE_EVENT, { operation: "Forged" }) do
      { "data" => nil, "errors" => [{ "message" => "no", "extensions" => { "code" => forged } }] }
    end

    expect(payload[:code]).to eq "OK I, [2026-01-01T00:00:00]  INFO -- graph_weaver: GraphWeaver AdminQuery (1.0ms) ok"
    expect(payload[:code]).not_to include "\n"
  end

  it "names the error class on a failure, and a ServerError's status as the code" do
    bad = GraphWeaver::Transport::HTTP.new(throttled_url)

    expect { bad.execute("query { x }") }.to raise_error(GraphWeaver::ServerError)
    expect(payload[:status]).to eq :failed
    expect(payload[:error]).to eq "GraphWeaver::ServerError"
    expect(payload[:code]).to eq 429
    expect(payload[:duration_ms]).to be_a Float
  end

  # a retried call is three events, and without this they read as three
  # unrelated slow requests rather than one that took three goes
  it "counts the retries an attempt follows" do
    client = GraphWeaver::Retry.new(
      GraphWeaver::Transport::HTTP.new(throttled_url), retries: 2, sleeper: ->(_) {}
    )

    expect { client.execute("query { x }") }.to raise_error(GraphWeaver::ServerError)
    expect(events.map { |_, p| p[:retries] }).to eq [0, 1, 2]
  end

  # a request nobody dispatched has no graph, and the client can't be asked
  # for one — see query_module_spec for the label a dispatch puts on
  it "carries a nil graph for a request no generated module made" do
    GraphWeaver::Transport::HTTP.new(url).execute("query { people { name } }")

    expect(payload).to include(graph: nil)
  end

  # the count describes the call on the stack, so a client that never
  # reaches the instrumenter can't leave a stale one for the next request
  it "carries no retry count when nothing retried" do
    GraphWeaver::Transport::HTTP.new(url).execute("query { people { name } }")

    expect(payload).not_to have_key :retries
  end

  # The payload fans out to subscribers that know nothing of
  # filter_parameters, so the rule can't be "scrub it" — it's "never put it
  # there". An added key is a decision, not an accident.
  it "carries the documented keys and nothing else" do
    GraphWeaver::Transport::HTTP.new(url).execute(
      "query Pinned($id: ID!) { person(id: $id) { name } }", variables: { "id" => "1" }
    )

    expect(payload.keys).to match_array %i[url operation client status http_status duration_ms graph]
    expect(payload.values.join).not_to include("person", "id")
  end

  it "lets a failure propagate, so the hook can record it" do
    bad = GraphWeaver::Transport::HTTP.new("http://127.0.0.1:#{@port}/nope")

    expect { bad.execute("query { x }") }.to raise_error(GraphWeaver::ServerError)
    expect(events.size).to eq 1
  end

  it "is a no-op when unset" do
    GraphWeaver.instrumenter = nil

    expect(GraphWeaver::Internal::Log.instrument("x", {}) { 42 }).to eq 42
  end
end
