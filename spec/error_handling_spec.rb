# typed: false
require "graph_weaver"
require_relative "generated/person_query"

# Exercises the error surface end to end against a fake executor returning
# canned GraphQL payloads (data / errors / extensions), plus the standalone
# error classes.
describe "error handling" do
  let(:mod) do
    GraphWeaver.parse(
      schema: Demo::Schema,
      query: "query($id: ID!) { person(id: $id) { id name birthday pets { name } } }",
      name: "PersonErr",
    )
  end

  # an executor that reached a server and got this GraphQL response body back
  def run(payload)
    executor = Object.new
    executor.define_singleton_method(:execute) { |_query, variables:, operation_name: nil| payload }
    mod.execute(client: executor, id: "1")
  end

  let(:person_data) do
    { "person" => { "id" => "1", "name" => "Daniel", "birthday" => nil, "pets" => [] } }
  end

  describe "the Response envelope" do
    it "exposes top-level extensions on success" do
      resp = run("data" => person_data, "extensions" => { "cost" => { "actualQueryCost" => 5 } })

      expect(resp.errors?).to be false
      expect(resp.success?).to be true
      expect(resp.extensions.dig("cost", "actualQueryCost")).to eq 5
      expect(resp.data!.person&.name).to eq "Daniel"
    end

    it "keeps partial data alongside errors (data typed, data! raises)" do
      resp = run("data" => person_data, "errors" => [{ "message" => "pets unavailable" }])

      expect(resp.errors?).to be true
      expect(resp.success?).to be false # partial data is still not a success
      expect(resp.data&.person&.name).to eq "Daniel" # partial data still typed
      expect { resp.data! }.to raise_error(GraphWeaver::QueryError)
    end
  end

  describe "GraphQLError" do
    let(:resp) do
      run("errors" => [{
        "message" => "Throttled",
        "locations" => [{ "line" => 1, "column" => 9 }],
        "path" => ["person", "pets", 0, "name"],
        "extensions" => { "code" => "THROTTLED" },
      }])
    end

    it "parses message, code, path, and locations" do
      err = resp.errors.first
      expect(err.message).to eq "Throttled"
      expect(err.code).to eq "THROTTLED"
      expect(err.path).to eq ["person", "pets", 0, "name"]
      expect(err.locations.first).to eq({ "line" => 1, "column" => 9 })
    end

    it "formats a readable to_s with location, path, and code" do
      expect(resp.errors.first.to_s).to eq "Throttled at 1:9 (path: person.pets.0.name) [THROTTLED]"
    end
  end

  describe "QueryError" do
    it "carries structured errors, partial data, extensions, and codes" do
      resp = run(
        "data" => { "person" => nil },
        "errors" => [
          { "message" => "boom", "extensions" => { "code" => "A" } },
          { "message" => "bang", "extensions" => { "code" => "B" } },
        ],
        "extensions" => { "cost" => { "actualQueryCost" => 3 } },
      )

      expect { resp.data! }.to raise_error(GraphWeaver::QueryError) do |e|
        expect(e).to be_a GraphWeaver::Error
        expect(e.codes).to eq %w[A B]
        expect(e.extensions.dig("cost", "actualQueryCost")).to eq 3
        expect(e.errors.map(&:message)).to eq %w[boom bang]
        expect(e.message).to match(/boom.*and 1 more/)
      end
    end
  end

  describe "GraphQLError#code dialects" do
    it "reads extensions.code, falling back to a top-level type (GitHub)" do
      apollo = GraphWeaver::GraphQLError.from_h("message" => "x", "extensions" => { "code" => "THROTTLED" })
      github = GraphWeaver::GraphQLError.from_h("message" => "x", "type" => "NOT_FOUND")

      expect(apollo.code).to eq "THROTTLED"
      expect(github.code).to eq "NOT_FOUND"
      expect(GraphWeaver::GraphQLError.from_h("message" => "x").code).to be_nil
    end
  end

  describe "ServerError" do
    it "carries status and body, distinct from a GraphQL error" do
      e = GraphWeaver::ServerError.new(status: 500, body: "kaboom")

      expect(e).to be_a GraphWeaver::Error
      expect(e.status).to eq 500
      expect(e.body).to eq "kaboom"
      expect(e.message).to include("HTTP 500").and include("kaboom")
      expect(e.headers).to be_empty
      expect(e.retry_after).to be_nil
      expect(e).not_to be_throttled
    end

    it "reads Retry-After as seconds or an HTTP-date, ignoring nonsense" do
      seconds = GraphWeaver::ServerError.new(status: 429, headers: { "retry-after" => "30" })
      date = GraphWeaver::ServerError.new(status: 503, headers: { "retry-after" => (Time.now + 60).httpdate })
      past = GraphWeaver::ServerError.new(status: 503, headers: { "retry-after" => (Time.now - 60).httpdate })
      junk = GraphWeaver::ServerError.new(status: 429, headers: { "retry-after" => "soon" })

      expect(seconds.retry_after).to eq 30.0
      expect(date.retry_after).to be_within(2).of(60)
      expect(past.retry_after).to eq 0.0
      expect(junk.retry_after).to be_nil

      # 503 counts as throttling only when it says when to come back
      expect([seconds, date, junk].map(&:throttled?)).to eq [true, true, true]
      expect(GraphWeaver::ServerError.new(status: 503)).not_to be_throttled
    end

    # "HTTP 301" with an empty body is the first thing a url pointed at
    # http:// (or at the wrong path) produces, and it names nothing
    it "says what to do about a redirect and a rejected token" do
      moved = GraphWeaver::ServerError.new(status: 301, headers: { "location" => "https://api.example.com/graphql" })
      expect(moved.message).to include("not followed").and include("https://api.example.com/graphql")

      expect(GraphWeaver::ServerError.new(status: 403).message).to include("auth:")
      expect(GraphWeaver::ServerError.new(status: 500, body: "kaboom").message).not_to include("—")
    end
  end

  describe "throttling" do
    def query_error(code)
      GraphWeaver::QueryError.new([GraphWeaver::GraphQLError.from_h(
        "message" => "slow down", "extensions" => { "code" => code }
      )])
    end

    it "recognizes the codes the big graphs send, whatever the dialect" do
      expect(query_error("THROTTLED")).to be_throttled     # Shopify
      expect(query_error("RATE_LIMITED")).to be_throttled  # GitHub
      expect(query_error("NOT_FOUND")).not_to be_throttled
      expect(query_error("THROTTLED").to_h["throttled"]).to be true
    end
  end

  describe "TransportError" do
    it "is a GraphWeaver::Error" do
      expect(GraphWeaver::TransportError.new).to be_a GraphWeaver::Error
    end

    it "classifies via a mutable, extensible set (seeded with core network errors)" do
      expect(GraphWeaver.transport_errors).to include(SocketError, SystemCallError, IOError)

      pool_error = Class.new(StandardError)
      expect(GraphWeaver.register_transport_error(pool_error)).to eq [pool_error]
      expect(GraphWeaver.transport_errors).to include(pool_error)
    ensure
      GraphWeaver.transport_errors.delete(pool_error)
    end
  end

  describe "ValidationError" do
    it "is raised for invalid queries, under the Error umbrella, with structured errors" do
      expect {
        GraphWeaver::Codegen.generate(schema: Demo::Schema, query: "{ nope }", module_name: "Bad")
      }.to raise_error(GraphWeaver::ValidationError) do |e|
        expect(e).to be_a GraphWeaver::Error # one rescue catches everything
        expect(e.message).to match(/invalid query/)
        expect(e.errors.first[:message]).to be_a String
      end
    end

    it "renders one error per line under the file it came from" do
      expect {
        GraphWeaver::Codegen.generate(schema: Demo::Schema, module_name: "Bad", path: "queries/typo.graphql",
          query: "query { person(id: 1) { nmae birthdy } }")
      }.to raise_error(GraphWeaver::ValidationError) do |e|
        expect(e.message.lines.map(&:chomp)).to match [
          "invalid query in queries/typo.graphql:",
          /\A {2}1:25 {2}Field 'nmae' /,
          /\A {2}1:30 {2}Field 'birthdy' /,
        ]
        # the structured side keeps the prefixed message rake queries:check reads
        expect(e.errors.first[:message]).to start_with "queries/typo.graphql:1:25 Field 'nmae'"
      end
    end

    it "omits the file from a dynamically parsed query, rather than a dangling 'in'" do
      expect { GraphWeaver.parse(schema: Demo::Schema, query: "{ nope }") }
        .to raise_error(GraphWeaver::ValidationError) do |e|
          expect(e.message.lines.map(&:chomp)).to match ["invalid query:", /\A {2}1:3 {2}Field 'nope' /]
        end
    end

    it "omits the position from an error that carries none, rather than a bare colon" do
      error = GraphWeaver::ValidationError.new([{ message: "no location for this one" }])

      expect(error.message).to eq "invalid query:\n  no location for this one"
    end
  end

  describe "schema drift detection" do
    it "flags validation-shaped errors and hints at regeneration" do
      resp = run("errors" => [{ "message" => "Field 'nmae' doesn't exist on type 'Person'" }])

      expect(resp.schema_stale?).to be true
      expect { resp.data! }.to raise_error(GraphWeaver::QueryError) do |e|
        expect(e.schema_stale?).to be true
        expect(e.message).to match(/schema may have changed since generation/)
        expect(e.message).to match(/rake graph_weaver:schema:refresh/)
      end
    end

    it "does not flag business errors" do
      errors = [{ "message" => "rate limited", "extensions" => { "code" => "THROTTLED" } }]
      resp = run("data" => person_data, "errors" => errors)

      expect(resp.schema_stale?).to be false
      expect { resp.data! }.to raise_error(GraphWeaver::QueryError) do |e|
        expect(e.message).not_to match(/schema may have changed/)
      end
    end

    it "recognizes the Apollo validation code" do
      error = GraphWeaver::GraphQLError.from_h(
        "message" => "anything",
        "extensions" => { "code" => "GRAPHQL_VALIDATION_FAILED" },
      )

      expect(error.validation?).to be true
    end
  end

  describe "field-level error filtering" do
    let(:errors) do
      [
        { "message" => "boom", "path" => ["person", "pets", 0, "name"] },
        { "message" => "bad email", "path" => ["person", "email"] },
        { "message" => "global" },
      ]
    end

    it "filters errors by path prefix, on the response and the raised error" do
      resp = run("data" => person_data, "errors" => errors)

      expect(resp.errors_at("person").size).to eq 2
      expect(resp.errors_at("person.email").map(&:message)).to eq ["bad email"]
      expect(resp.errors_at(["person", "pets"]).map(&:message)).to eq ["boom"]
      expect(resp.errors_at("person.pets.0.name").map(&:message)).to eq ["boom"]
      expect(resp.errors_at("nothing")).to be_empty

      expect { resp.data! }.to raise_error(GraphWeaver::QueryError) do |e|
        expect(e.errors_at("person.email").map(&:message)).to eq ["bad email"]
      end
    end
  end

  describe "field-keyed iteration and the error report" do
    # two pets, errors on both names — path indices differ, field is the same
    let(:data) do
      { "person" => { "id" => "1", "name" => "Daniel", "birthday" => nil,
                      "pets" => [{ "name" => "Shelby" }, { "name" => "Brownie" }] } }
    end
    let(:errors) do
      [
        { "message" => "name hidden", "path" => ["person", "pets", 0, "name"],
          "extensions" => { "code" => "PRIVATE" } },
        { "message" => "name hidden", "path" => ["person", "pets", 1, "name"],
          "extensions" => { "code" => "PRIVATE" } },
        { "message" => "outage", "extensions" => { "code" => "DOWN" } },
      ]
    end
    let(:resp) { run("data" => data, "errors" => errors) }

    it "exposes the index-stripped field on each error" do
      expect(resp.errors.map(&:field)).to eq ["person.pets.name", "person.pets.name", nil]
    end

    it "iterates errors grouped by field" do
      seen = {}
      resp.each_error { |field, errs| seen[field] = errs.size }

      expect(seen).to eq("person.pets.name" => 2, nil => 1)
    end

    it "builds a report keyed by field with entity ids resolved from the data" do
      report = resp.report

      expect(report.keys).to contain_exactly("person.pets.name", nil)
      expect(report["person.pets.name"]["messages"]).to eq ["name hidden", "name hidden"]
      expect(report["person.pets.name"]["codes"]).to eq ["PRIVATE"]
      expect(report[nil]["codes"]).to eq ["DOWN"]
      expect { JSON.generate(report) }.not_to raise_error
    end

    it "resolves entity ids by walking the path through typed data" do
      # a person-level error resolves to the person's id (pets carry no id
      # in this selection, so pet-level errors resolve nil)
      resp = run("data" => data, "errors" => [{ "message" => "x", "path" => ["person", "name"] }])

      expect(resp.entity_id(resp.errors.first)).to eq "1"
    end
  end

  describe "machine-readable output (#to_h)" do
    # the envelope is where an API boundary reaches for to_h, and every error
    # class had one while the thing holding them didn't
    it "decomposes the envelope, errors machine-ready" do
      errors = [{ "message" => "bad email", "path" => ["person", "email"] }]
      resp = run("data" => person_data, "errors" => errors, "extensions" => { "cost" => 3 })

      h = resp.to_h
      expect(h.keys).to contain_exactly("data", "errors", "extensions")
      expect(h["errors"].first).to include("message" => "bad email", "field" => "person.email")
      expect(h["extensions"]).to eq("cost" => 3)
      expect { JSON.generate(h["errors"]) }.not_to raise_error
    end

    # sorbet's #serialize is the wrong inverse here — props are snake_case
    # while the wire is camelCase, nulls drop out, and a registered scalar
    # stays the Ruby object its codec built. So data stays typed.
    it "keeps data typed rather than re-serializing it" do
      resp = run("data" => person_data)

      expect(resp.to_h["data"]).to be resp.data
      expect(resp.to_h["data"].person&.name).to eq "Daniel"
      expect(run("errors" => [{ "message" => "down" }]).to_h["data"]).to be_nil
    end

    it "nests the full error detail as JSON-ready hashes" do
      errors = [
        { "message" => "bad email", "path" => ["person", "email"],
          "extensions" => { "code" => "INVALID_EMAIL" } },
      ]

      expect { run("data" => person_data, "errors" => errors).data! }
        .to raise_error(GraphWeaver::QueryError) do |e|
          h = e.to_h

          expect(h["error"]).to eq "GraphWeaver::QueryError"
          expect(h["message"]).to match(/bad email/)
          expect(h["schema_stale"]).to be false
          expect(h["codes"]).to eq ["INVALID_EMAIL"]
          expect(h["errors"]).to eq [{
            "message" => "bad email",
            "code" => "INVALID_EMAIL",
            "field" => "person.email",
            "path" => ["person", "email"],
            "locations" => [],
            "extensions" => { "code" => "INVALID_EMAIL" },
            "validation" => false,
          }]
          expect { JSON.generate(h) }.not_to raise_error
        end
    end

    it "covers the whole hierarchy" do
      server = GraphWeaver::ServerError.new(status: 502, body: "bad gateway")
      expect(server.to_h).to include("error" => "GraphWeaver::ServerError", "status" => 502)

      validation = begin
        GraphWeaver::Codegen.generate(schema: Demo::Schema, query: "{ nope }", module_name: "Bad")
      rescue GraphWeaver::ValidationError => e
        e
      end
      expect(validation.to_h["errors"].first).to include("message")
    end
  end

  describe "TypeError" do
    # the checked-in fixture module, so generated structs have real names
    def run_generated(payload)
      executor = Object.new
      executor.define_singleton_method(:execute) { |_query, variables:, operation_name: nil| payload }
      PersonQuery.execute(client: executor, id: "1")
    end

    it "wraps wire data that disagrees with the generated types, naming the struct" do
      # birthday should be an iso8601 string; a number breaks the Date cast
      bad = { "person" => { "id" => "1", "name" => "Daniel", "birthday" => 123, "pets" => [] } }

      expect { run_generated("data" => bad) }.to raise_error(GraphWeaver::TypeError) do |e|
        expect(e.struct.name).to eq "PersonQuery::Result::Person"
        expect(e.message).to match(/failed to cast response/)
        expect(e.cause).not_to be_nil
      end
    end

    it "keeps the innermost struct context for nested failures" do
      # pet name must be a String; nil violates the non-null prop
      bad = {
        "person" => {
          "id" => "1", "name" => "Daniel", "birthday" => nil,
          "pets" => [{ "name" => nil }],
        },
      }

      expect { run_generated("data" => bad) }.to raise_error(GraphWeaver::TypeError) do |e|
        expect(e.struct.name).to eq "PersonQuery::Result::Person::Pets"
      end
    end
  end

  describe "malformed inputs/responses stay branded (review fixes)" do
    # a transport that reached the server and got back this (status, body)
    def canned(status, body)
      Class.new(GraphWeaver::Transport) do
        define_method(:initialize) { |s, b| @status = s; @body = b; @url = "http://test/graphql" }
        define_method(:post) { |_encoded| [@status, @body] }
      end.new(status, body)
    end

    it "raises ServerError (not a null-data envelope) on a non-2xx body with errors: null" do
      expect { canned(429, '{"errors":null}').execute("query { x }") }
        .to raise_error(GraphWeaver::ServerError) { |e| expect(e.status).to eq 429 }
    end

    it "raises ServerError on a 2xx body that isn't a JSON object" do
      expect { canned(200, "[1,2,3]").execute("query { x }") }.to raise_error(GraphWeaver::ServerError)
    end

    it "raises QueryError (not a bare TypeError) when data! sees null data and no errors" do
      expect { run("data" => nil).data! }.to raise_error(GraphWeaver::QueryError)
    end

    # each used to arrive as a Response reporting success with no data
    it "refuses a response carrying neither data nor errors" do
      expect { run(nil) }.to raise_error(GraphWeaver::TypeError, /neither "data" nor "errors"/)

      expect { run(data: person_data) }.to raise_error(GraphWeaver::TypeError, /got :data/)
      expect { run("dat" => person_data) }.to raise_error(GraphWeaver::TypeError, /got "dat"/)
    end

    it "brands a response that isn't an object at all" do
      expect { GraphWeaver.check_envelope!('{"data":{}}', mod::Result) }
        .to raise_error(GraphWeaver::TypeError, /must be an object, got String/)
    end

    it "raises InputError when an input struct is coerced from a non-Hash" do
      require_relative "generated/types"
      expect { GraphQLTypes::AdoptionInput.coerce("nope") }
        .to raise_error(GraphWeaver::InputError, /expected a Hash/)
    end

    # the frame sorbet appends is a path into the gem, never into the code
    # with the problem — TypeError already drops it
    it "keeps sorbet's own frame out of an InputError" do
      require_relative "generated/types"
      expect { GraphQLTypes::AdoptionInput.coerce("species" => "DOG") }
        .to raise_error(GraphWeaver::InputError) { |e| expect(e.message).not_to include("Caller:") }
    end
  end

  # docs/errors.md's table is where a reader meets the hierarchy, and it says
  # the subclass tells you where it failed — so a class that can reach a
  # `rescue` has to land there. (Two had never been added when this was
  # written.) The requires are explicit: what's loaded decides the answer.
  it "documents every error class" do
    require "graph_weaver/testing"

    docs = File.read(File.expand_path("../docs/errors.md", __dir__)).delete("`")
    classes = []
    queue = GraphWeaver::Error.subclasses
    until queue.empty?
      klass = queue.shift
      classes << klass
      queue.concat(klass.subclasses)
    end

    undocumented = classes.map { |klass| klass.name.delete_prefix("GraphWeaver::") }
      .reject { |name| docs.include?(name) }
    expect(undocumented).to be_empty
  end
end
