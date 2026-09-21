require "logger"
require "stringio"
require "tmpdir"

require_relative "generated/find_pets_query"
require_relative "generated/person_query"

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
    expect(io.string).to match(%r{HTTP 200 .* \(\d+ bytes, application/json\)})
  end

  it "tags each request's lines with an id and the operation name" do
    executor.execute("query LoggedPeople { people { name } }", variables: {})

    tag = io.string[/\[req \d+-\d+ LoggedPeople\]/]
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
    GraphWeaver::Internal::Log.instrument_request({ operation: "Forged" }) do
      { "data" => nil, "errors" => [{ "message" => "no", "extensions" => { "code" => forged } }] }
    end

    expect(payload[:code]).to eq "OK I, [2026-01-01T00:00:00]  INFO -- graph_weaver: GraphWeaver AdminQuery (1.0ms) ok"
    expect(payload[:code]).not_to include "\n"
  end

  # :code is one dimension — the GraphQL error code — or nothing. It used to
  # hold a ServerError's status too, so one APM tag carried "THROTTLED" and
  # 429 and grouped neither; the number was already on :http_status.
  it "names the error class on a failure, and leaves the status on :http_status" do
    bad = GraphWeaver::Transport::HTTP.new(throttled_url)

    expect { bad.execute("query { x }") }.to raise_error(GraphWeaver::ServerError)
    expect(payload[:status]).to eq :failed
    expect(payload[:error]).to eq "GraphWeaver::ServerError"
    expect(payload[:http_status]).to eq 429
    expect(payload).not_to have_key :code
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

  # A "checkout write failure rate" needs to know which requests were writes,
  # and the operation NAME can't be asked — it is whatever the query is called.
  # Read off the document by the same check that decides not to retry.
  it "says whether the request was a query, a mutation or a subscription" do
    over_the_wire = GraphWeaver::Transport::HTTP.new(url)
    in_process = GraphWeaver::InProcess.new(Demo::Schema)

    over_the_wire.execute("query Read { people { name } }")
    in_process.execute("query Read { people { name } }")
    over_the_wire.execute("mutation Write { addPet(name: \"x\", species: DOG) { id } }")
    in_process.execute("mutation Write { addPet(name: \"x\", species: DOG) { id } }")
    in_process.execute("{ people { name } }") # the shorthand document is a query

    expect(events.map { |_, p| p[:kind] }).to eq %i[query query mutation mutation query]
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

    expect(payload.keys).to match_array %i[url operation client kind status http_status duration_ms graph]
    expect(payload.values.join).not_to include("person", "id")
  end

  it "lets a failure propagate, so the hook can record it" do
    bad = GraphWeaver::Transport::HTTP.new("http://127.0.0.1:#{@port}/nope")

    expect { bad.execute("query { x }") }.to raise_error(GraphWeaver::ServerError)
    expect(events.size).to eq 1
  end

  it "is a no-op when unset" do
    GraphWeaver.instrumenter = nil

    expect(GraphWeaver::Internal::Log.instrument_request({}) { 42 }).to eq 42
  end
end

# The second event: one CALL of a generated module, which is what the caller
# got. The request event can't say it — a CastError is raised after the
# response is back, so the request had already closed :ok.
describe "GraphWeaver::OPERATION_EVENT" do
  include_context "graphql http server"

  let(:events) { [] }

  around do |example|
    GraphWeaver.instrumenter = lambda do |event, payload, &block|
      events << [event, payload]
      block.call
    end
    example.run
  ensure
    GraphWeaver.instrumenter = nil
  end

  def operations = events.select { |name, _| name == GraphWeaver::OPERATION_EVENT }.map(&:last)

  def requests = events.select { |name, _| name == GraphWeaver::EXECUTE_EVENT }.map(&:last)

  # what a transport does — one instrumented request — answering whatever
  # this example wants the cast to meet
  def client_answering(response)
    Class.new do
      define_method(:execute) do |_query, variables: {}, operation_name: nil|
        GraphWeaver::Internal::Log.instrument_request({ operation: operation_name, client: self.class }) { response }
      end
    end.new
  end

  it "closes over the whole call, with the request nested inside it" do
    PersonQuery.execute(id: "1", client: GraphWeaver::Transport::HTTP.new(url))

    expect(events.map(&:first)).to eq [GraphWeaver::OPERATION_EVENT, GraphWeaver::EXECUTE_EVENT]
    expect(operations.first).to include(
      operation: "PersonQuery", module: "PersonQuery", graph: nil, kind: :query,
      client: GraphWeaver::Transport::HTTP, status: :ok,
    )
    expect(operations.first[:duration_ms]).to be_a(Float).and be >= 0
  end

  # the module seam is the one every client slot passes through, which is
  # why the event lives there rather than beside the request
  it "fires for a schema class in the client slot too" do
    PersonQuery.execute(id: "1", client: Demo::Schema)

    expect(operations.first).to include(client: GraphWeaver::InProcess, status: :ok)
    expect(requests.first).to include(schema: "Demo::Schema")
  end

  # THE gap this event closes: the response arrived, so the request event was
  # already :ok when the cast raised and the caller saw a failure
  it "says :failed for a cast that raised after the request said :ok" do
    nameless = { "data" => { "person" => { "id" => "1", "name" => nil, "birthday" => nil, "pets" => [] } } }

    expect { PersonQuery.execute(id: "1", client: client_answering(nameless)) }
      .to raise_error(GraphWeaver::CastError)

    expect(requests.first).to include(status: :ok)
    expect(operations.first).to include(status: :failed, error: "GraphWeaver::CastError")
  end

  # a response that arrived carrying errors is not a raise, whatever execute!
  # then does with it — :errors is the status an alert groups by
  it "says :errors for a response that carried them, even where execute! raises" do
    throttled = { "data" => nil,
                  "errors" => [{ "message" => "slow down", "extensions" => { "code" => "THROTTLED" } }] }

    expect { PersonQuery.execute!(id: "1", client: client_answering(throttled)) }
      .to raise_error(GraphWeaver::QueryError)

    expect(operations.map { |p| p.values_at(:status, :code) }).to eq [[:errors, "THROTTLED"]]
  end

  # the code comes off the typed errors the cast built, not off a hash round
  # trip — GraphQLError#to_h spells a GitHub-dialect code as "code", and
  # reading that back as a wire error would lose it
  it "reads a code the server put in a dialect of its own" do
    missing = { "data" => { "person" => nil }, "errors" => [{ "message" => "no", "type" => "NOT_FOUND" }] }
    PersonQuery.execute(id: "1", client: client_answering(missing))

    expect(operations.first).to include(status: :errors, code: "NOT_FOUND")
  end

  # execute! with an omittable variable repeats the call rather than
  # delegating, so it is the other emitted shape — still one event
  it "covers execute! where it dispatches itself rather than delegating" do
    FindPetsQuery.execute!(client: client_answering({ "data" => { "findPets" => [] } }))

    expect(operations.map { |p| p[:operation] }).to eq ["FindPetsQuery"]
  end

  it "is one event over every attempt a Retry made, and the backoff between them" do
    client = GraphWeaver::Retry.new(
      GraphWeaver::Transport::HTTP.new(throttled_url), retries: 2, sleeper: ->(_) { sleep 0.02 }
    )

    expect { PersonQuery.execute(id: "1", client:) }.to raise_error(GraphWeaver::ServerError)

    expect(operations.size).to eq 1
    expect(requests.map { |p| p[:retries] }).to eq [0, 1, 2]
    expect(operations.first).to include(status: :failed, error: "GraphWeaver::ServerError")
    # the caller's wall clock: no request event covers the sleeps between them
    expect(operations.first[:duration_ms]).to be > requests.sum { |p| p[:duration_ms] }
  end

  # the attempt facts stay on the attempt: a call that took three goes has no
  # one url, no one http_status and no one retry count
  it "carries the documented keys and nothing else" do
    PersonQuery.execute(id: "1", client: GraphWeaver::Transport::HTTP.new(url))

    expect(operations.first.keys).to match_array %i[operation module graph kind client status duration_ms]
  end

  it "reports nothing for from_response on its own — no call was made" do
    PersonQuery.from_response({ "data" => { "person" => nil } })

    expect(events).to be_empty
  end

  # a module generated before this event existed hands over no cast, so this
  # seam sees half the call — and half a call reported :ok is the very lie
  # the event exists to stop
  it "reports nothing for a module generated before it existed" do
    PersonQuery.send(:dispatch, { "id" => "1" }, client: client_answering({ "data" => {} }))

    expect(events.map(&:first)).to eq [GraphWeaver::EXECUTE_EVENT]
  end
end
