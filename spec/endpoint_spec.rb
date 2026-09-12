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
