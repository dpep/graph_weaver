# typed: false
require "graph_weaver"

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
    executor.define_singleton_method(:execute) { |_query, variables:| payload }
    mod.execute(id: "1", executor:)
  end

  let(:person_data) do
    { "person" => { "id" => "1", "name" => "Daniel", "birthday" => nil, "pets" => [] } }
  end

  describe "the Response envelope" do
    it "exposes top-level extensions on success" do
      resp = run("data" => person_data, "extensions" => { "cost" => { "actualQueryCost" => 5 } })

      expect(resp.errors?).to be false
      expect(resp.extensions.dig("cost", "actualQueryCost")).to eq 5
      expect(resp.data!.person&.name).to eq "Daniel"
    end

    it "keeps partial data alongside errors (data typed, data! raises)" do
      resp = run("data" => person_data, "errors" => [{ "message" => "pets unavailable" }])

      expect(resp.errors?).to be true
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

  describe "ServerError" do
    it "carries status and body, distinct from a GraphQL error" do
      e = GraphWeaver::ServerError.new(status: 500, body: "kaboom")

      expect(e).to be_a GraphWeaver::Error
      expect(e.status).to eq 500
      expect(e.body).to eq "kaboom"
      expect(e.message).to include("HTTP 500").and include("kaboom")
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
    it "is raised for invalid queries, is an ArgumentError, and carries structured errors" do
      expect {
        GraphWeaver::Codegen.generate(schema: Demo::Schema, query: "{ nope }", module_name: "Bad")
      }.to raise_error(GraphWeaver::ValidationError) do |e|
        expect(e).to be_a ArgumentError # source-compatible
        expect(e.message).to match(/invalid query/)
        expect(e.errors.first[:message]).to be_a String
      end
    end
  end
end
