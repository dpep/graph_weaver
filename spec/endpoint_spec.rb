# typed: ignore — subgraph classes are invisible to srb
# frozen_string_literal: true

require "graph_weaver/testing"
require "stringio"

# The Rack face of a test client: a real request in, real JSON bytes out.
# `graphql: :wire` mounts this behind your own transport's url, but it is an
# ordinary Rack app — mount it under anything.
describe GraphWeaver::Testing::Endpoint do
  # a client that records what it was asked, so the spec can assert the app
  # unpacked the request rather than that the router agrees with itself
  let(:client) do
    Class.new do
      attr_reader :calls
      attr_accessor :context

      def initialize
        @calls = []
        @context = {}
      end

      def execute(query, variables: {}, operation_name: nil)
        @calls << { query:, variables:, operation_name:, context: @context }
        { "data" => { "echo" => query } }
      end
    end.new
  end

  subject(:app) { described_class.new(client) }

  def post(body, headers = {})
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(body),
    }.merge(headers)
    app.call(env)
  end

  def request(query, variables: nil, operation_name: nil, **headers)
    payload = { "query" => query }
    payload["variables"] = variables if variables
    payload["operationName"] = operation_name if operation_name
    post(JSON.generate(payload), headers)
  end

  it "answers a POST with the client's result as JSON" do
    status, headers, body = request("{ me { name } }")

    expect(status).to eq 200
    expect(headers).to eq({ "content-type" => "application/json" })
    expect(JSON.parse(body.join)).to eq({ "data" => { "echo" => "{ me { name } }" } })
  end

  it "hands query, variables and operationName to the client" do
    request("query Me { me { name } }", variables: { "id" => "1" }, operation_name: "Me")

    expect(client.calls).to eq [{
      query: "query Me { me { name } }", variables: { "id" => "1" }, operation_name: "Me", context: {},
    }]
  end

  it "defaults absent variables to an empty hash" do
    request("{ me }")

    expect(client.calls.first[:variables]).to eq({})
  end

  describe "a request it can't serve" do
    it "refuses a body that isn't JSON, naming what it got" do
      status, headers, body = post("<html>nope</html>")

      expect(status).to eq 400
      expect(headers["content-type"]).to eq "text/plain"
      expect(body.join).to include("expected a JSON GraphQL request", "<html>nope</html>")
      expect(client.calls).to be_empty
    end

    it "refuses JSON that carries no query, naming what it got" do
      status, _headers, body = post(JSON.generate({ "mutation" => "{ me }" }))

      expect(status).to eq 400
      expect(body.join).to include('with a "query" string', '\"mutation\":')
    end

    it "refuses a method that isn't POST, naming it" do
      status, _headers, body = app.call({ "REQUEST_METHOD" => "GET", "rack.input" => StringIO.new("") })

      expect(status).to eq 400
      expect(body.join).to include("POST", "GET")
    end
  end

  # what a real router and graphql-ruby both do: a query the server can't
  # parse or validate is a 200 carrying GraphQL errors, not an HTTP failure
  describe "a query the server refuses" do
    let(:client) { GraphWeaver::Testing::Router.new(supergraph: RouterGraph::SUPERGRAPH) }

    it "serves a parse error as a 200 with errors" do
      status, _headers, body = request("{ me {")

      expect(status).to eq 200
      result = JSON.parse(body.join)
      expect(result["data"]).to be_nil
      expect(result["errors"].first["extensions"]["code"]).to eq "GRAPHQL_PARSE_FAILED"
    end

    it "serves a validation error as a 200 with errors" do
      status, _headers, body = request("{ nope }")

      expect(status).to eq 200
      expect(JSON.parse(body.join).dig("errors", 0, "message")).to include "nope"
    end
  end

  describe "context from the request's headers" do
    it "asks a context proc what this request's headers mean" do
      seen = nil
      client.context = lambda do |headers|
        seen = headers
        { current_user: headers["Authorization"] }
      end

      request("{ me }", "HTTP_AUTHORIZATION" => "Bearer abc", "HTTP_X_CALLER" => "checkout")

      expect(client.calls.first[:context]).to eq({ current_user: "Bearer abc" })
      expect(seen).to include("Authorization" => "Bearer abc", "X-Caller" => "checkout",
        "Content-Type" => "application/json")
    end

    it "puts the proc back, so one request's identity can't leak into the next" do
      reader = ->(headers) { { caller: headers["X-Caller"] } }
      client.context = reader

      request("{ me }", "HTTP_X_CALLER" => "one")
      request("{ me }", "HTTP_X_CALLER" => "two")

      expect(client.context).to be reader
      expect(client.calls.map { |call| call[:context] }).to eq [{ caller: "one" }, { caller: "two" }]
    end

    # ...or into a request running beside it. Both documented deployments are
    # concurrent — a Puma in a thread, `graphql: :wire` under a parallel run —
    # and a spec asserting user A can't read user B's data is exactly the spec
    # that would pass here for the wrong reason.
    it "can't cross two identities served at once" do
      slow = Class.new do
        attr_accessor :context

        def execute(_query, variables: {}, operation_name: nil)
          who = context[:caller]
          sleep 0.02 # a resolver slow enough for another request to arrive
          { "data" => { "whoami" => who } }
        end
      end.new
      slow.context = ->(headers) { { caller: headers["X-Caller"] } }
      app = described_class.new(slow)

      served = 8.times.map do |i|
        Thread.new do
          env = {
            "REQUEST_METHOD" => "POST",
            "rack.input" => StringIO.new(JSON.generate("query" => "{ whoami }")),
            "HTTP_X_CALLER" => "user-#{i}",
          }
          _status, _headers, body = app.call(env)
          ["user-#{i}", JSON.parse(body.join).dig("data", "whoami")]
        end
      end.map(&:value)

      expect(served).to all(satisfy { |sent, got| sent == got })
    end

    it "leaves a hash context alone" do
      client.context = { current_user: "alice" }

      request("{ me }", "HTTP_AUTHORIZATION" => "Bearer abc")

      expect(client.calls.first[:context]).to eq({ current_user: "alice" })
    end

    # the three clients the :wire tag can put behind the endpoint, so the
    # header seam is the same one whichever the app's graph turns out to be
    it "reaches a router's subgraph resolvers" do
      router = GraphWeaver::Testing::Router.new(
        supergraph: RouterGraph::SUPERGRAPH,
        context: ->(headers) { { current_user_id: headers["X-User"] } },
      )
      _status, _headers, body = described_class.new(router).call({
        "REQUEST_METHOD" => "POST", "HTTP_X_USER" => "2",
        "rack.input" => StringIO.new(JSON.generate({ "query" => "{ me { username } }" })),
      })

      expect(JSON.parse(body.join).dig("data", "me", "username")).to eq "ada"
    end

    it "reaches an in-process schema's resolvers" do
      in_process = GraphWeaver::InProcess.new(
        RouterGraph::Accounts::Schema,
        context: ->(headers) { { current_user_id: headers["X-User"] } },
      )
      _status, _headers, body = described_class.new(in_process).call({
        "REQUEST_METHOD" => "POST", "HTTP_X_USER" => "2",
        "rack.input" => StringIO.new(JSON.generate({ "query" => "{ me { username } }" })),
      })

      expect(JSON.parse(body.join).dig("data", "me", "username")).to eq "ada"
    end

    # what :wire serves for an app that is a pure client of someone else's
    # API: the fabricated values have to survive JSON.generate, which a fake
    # answering above the wire never had to
    it "serves a fake's fabricated data as JSON" do
      fake = GraphWeaver::Testing::FakeClient.new({ "Person.name" => "Ada" }, schema: Demo::Schema)
      _status, _headers, body = described_class.new(fake).call({
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new(JSON.generate({
          "query" => '{ person(id: "1") { name birthday } }',
        })),
      })

      person = JSON.parse(body.join).dig("data", "person")
      expect(person["name"]).to eq "Ada"
      expect(person["birthday"]).to match(/\A\d{4}-\d\d-\d\d\z/) # a Date, on the wire
    end

    it "serves a client that has no context at all" do
      bare = Class.new do
        def execute(query, variables: {}, operation_name: nil) = { "data" => { "q" => query } }
      end.new
      status, = described_class.new(bare).call({
        "REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(JSON.generate({ "query" => "{ me }" })),
      })

      expect(status).to eq 200
    end
  end

  # a context proc is answered from a request's headers, so off the wire
  # there is no honest answer — and a Proc handed to graphql-ruby as a
  # context fails somewhere far from the line that set it
  describe "a context proc with no request behind it" do
    it "is refused by the router, naming the tag that supplies one" do
      router = GraphWeaver::Testing::Router.new(
        supergraph: RouterGraph::SUPERGRAPH, context: ->(headers) { headers },
      )

      expect { router.execute("{ me { username } }") }
        .to raise_error(GraphWeaver::Error, /context: is a proc.*graphql: :wire/m)
    end

    it "is refused in-process, naming the tag that supplies one" do
      in_process = GraphWeaver::InProcess.new(
        RouterGraph::Accounts::Schema, context: ->(headers) { headers },
      )

      expect { in_process.execute("{ me { username } }") }
        .to raise_error(GraphWeaver::Error, /context: is a proc.*graphql: :wire/m)
    end
  end
end
