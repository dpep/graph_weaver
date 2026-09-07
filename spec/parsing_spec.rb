# typed: ignore — eval'd query modules are invisible to srb
# frozen_string_literal: true

require "graph_weaver/testing"
require "tmpdir"

# One rule: anything holding a schema parses against it, and the module it
# returns runs on the thing that parsed it.
describe GraphWeaver::Parsing do
  let(:query) { "query Who { person(id: 1) { name } }" }

  after { GraphWeaver.client = nil }

  it "an in-process wrapper parses against its schema class" do
    client = GraphWeaver::InProcess.new(Demo::Schema)

    expect(client.parse(query).execute!.person&.name).to eq "Daniel"
  end

  it "a fake client parses against the schema it fabricates from" do
    fake = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, overrides: { "Person.name" => "faked" })

    expect(fake.parse(query).execute!.person&.name).to eq "faked"
  end

  it "a router parses against the supergraph, and the module crosses subgraphs" do
    router = GraphWeaver::Testing::Router.new(
      supergraph: RouterGraph::SUPERGRAPH, subgraphs: RouterGraph::SUBGRAPHS,
    )

    me = router.parse("query Dashboard { me { username reviews { product { name } } } }").execute!.me

    expect(me.reviews.first&.product&.name).to be_a String
    expect(router).to have_fetched("accounts", "reviews", "products")
  end

  it "load_queries! comes with it — the directory form of the same rule" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "person.graphql"), "query($id: ID!) { person(id: $id) { name } }")
      namespace = Module.new
      fake = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, overrides: { "Person.name" => "faked" })

      fake.load_queries!(dir, namespace:)

      expect(namespace::PersonQuery.execute!(id: "1").person&.name).to eq "faked"
    end
  end

  describe "a Client" do
    it "bakes itself, like every other parser" do
      mod = GraphWeaver.new(Demo::Schema).parse(query)

      expect(mod.execute!.person&.name).to eq "Daniel" # ran on the client, no global wiring
    end

    it "says so when the client it baked is a schema dump, rather than falling through to the app default" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "schema.graphql")
        File.write(path, Demo::Schema.to_definition)
        mod = GraphWeaver.new(path).parse(query)
        GraphWeaver.client = Demo::Schema

        expect { mod.execute! }
          .to raise_error(GraphWeaver::Error, "this client has no transport (built from a schema dump) — pass a url or transport:")
      end
    end
  end

  it "Retry holds no schema, so it has no #parse" do
    # it wraps a client to retry its execute; the schema — and parsing
    # against it — stays with whatever it wraps
    expect(GraphWeaver::Retry.new(Demo::Schema)).not_to respond_to(:parse)
  end

  it "a bare schema class fills the client slot without any of this" do
    mod = GraphWeaver.parse(schema: Demo::Schema, query:, client: Demo::Schema)

    expect(mod.execute!.person&.name).to eq "Daniel"
  end
end
