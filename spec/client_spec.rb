require "graph_weaver/transport/faraday"
require "graph_weaver/testing"
require "tmpdir"


describe GraphWeaver::Client do
  include_context "graphql http server"

  describe "from a url" do
    it "builds the transport, introspects the schema lazily, and executes" do
      client = GraphWeaver.new(url)

      expect(client.executor).to be_a GraphWeaver::Transport::Faraday # no retry wrapper by default
      expect(client.execute!("query { person(id: 1) { name } }").person&.name).to eq "Daniel"
      expect(client.schema.types).to have_key "Person"
    end

    it "sends bearer auth, or a verbatim scheme, or custom headers" do
      GraphWeaver.new(url, auth: "t0ken").execute!("query { person(id: 1) { id } }")
      expect(@requests.last[:headers]["authorization"]).to eq ["Bearer t0ken"]

      GraphWeaver.new(url, auth: "Basic dXNlcg==").execute!("query { person(id: 1) { id } }")
      expect(@requests.last[:headers]["authorization"]).to eq ["Basic dXNlcg=="]

      GraphWeaver.new(url, headers: { "X-Api-Key" => "k" }).execute!("query { person(id: 1) { id } }")
      expect(@requests.last[:headers]["x-api-key"]).to eq ["k"]
    end

    it "prefers Faraday when loaded, with middleware pass-through" do
      client = GraphWeaver.new(url) { |conn| conn.options.timeout = 3 }

      expect(client.executor).to be_a GraphWeaver::Transport::Faraday
    end

    it "falls back to the built-in transport without faraday, rejecting middleware" do
      hide_const("Faraday")

      expect(GraphWeaver.new(url).executor).to be_a GraphWeaver::Transport::HTTP
      expect {
        GraphWeaver.new(url) { |conn| conn }
      }.to raise_error(ArgumentError, /faraday/)
    end

    it "tunes retries with a Hash, or disables them" do
      slept = []
      # nothing listens on port 1: every attempt is a connection refusal
      client = GraphWeaver.new("http://127.0.0.1:1/graphql", retries: { tries: 3, sleeper: ->(s) { slept << s } })

      expect { client.execute!("query { person(id: 1) { id } }") }.to raise_error(GraphWeaver::TransportError)
      expect(slept.size).to eq 2 # the Hash reached the RetryExecutor

      expect(GraphWeaver.new(url, retries: true).executor).to be_a GraphWeaver::RetryExecutor
      expect(GraphWeaver.new(url, retries: false).executor).to be_a GraphWeaver::Transport::Faraday
    end

    it "parses typed modules bound to its transport" do
      mod = GraphWeaver.new(url).parse("query Who { person(id: 1) { name } }")

      expect(mod.execute!.person&.name).to eq "Daniel"
    end

    it "load_queries! defines a module per query file, reloadably" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "person.graphql"), "query($id: ID!) { person(id: $id) { name } }")
        File.write(File.join(dir, "people.graphql"), "query { people { name } }")
        namespace = Module.new

        mods = GraphWeaver.new(url).load_queries!(dir, namespace:)

        expect(mods.size).to eq 2
        expect(namespace::PersonQuery.execute!(id: "1").person&.name).to eq "Daniel"
        expect(namespace::PeopleQuery.execute!.people.map(&:name)).to include "Daniel"

        # reloadable: a second pass replaces the constants without warning
        expect { GraphWeaver.new(url).load_queries!(dir, namespace:) }.not_to output.to_stderr
      end
    end

    it "rejects a url plus executor:" do
      expect { GraphWeaver.new(url, executor: Demo::Schema) }.to raise_error(ArgumentError, /not both/)
    end
  end

  describe "from a schema source" do
    it "a live schema class executes in-process" do
      client = GraphWeaver.new(Demo::Schema)

      expect(client.execute!("query { person(id: 1) { name } }").person&.name).to eq "Daniel"
      expect(client.schema).to equal Demo::Schema
    end

    it "a configured global executor still wins over the schema class" do
      recorded = []
      recorder = Class.new do
        define_method(:execute) do |query, variables:|
          recorded << query
          Demo::Schema.execute(query, variables:)
        end
      end

      GraphWeaver.executor = recorder.new
      GraphWeaver.new(Demo::Schema).execute!("query { person(id: 1) { id } }")

      expect(recorded.size).to eq 1
    ensure
      GraphWeaver.executor = nil
    end

    it "a dump is type information only — no executor to run against" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "schema.graphql")
        File.write(path, Demo::Schema.to_definition)

        client = GraphWeaver.new(path)
        expect(client.schema.types).to have_key "Person"
        expect { client.execute("query { person(id: 1) { id } }") }
          .to raise_error(GraphWeaver::Error, /no executor/)

        # bring your own transport
        with_executor = GraphWeaver.new(path, executor: Demo::Schema)
        expect(with_executor.execute!("query { person(id: 1) { name } }").person&.name).to eq "Daniel"
      end
    end

    it "rejects url-only options" do
      expect { GraphWeaver.new(Demo::Schema, auth: "t0ken") }.to raise_error(ArgumentError, /url/)
    end
  end

  describe "schema caching" do
    it "memoizes, and honors cache: on disk" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "schema.json")
        client = GraphWeaver.new(url, cache: path)

        expect(client.schema).to equal client.schema # memoized
        expect(File).to exist(path)

        # a fresh client reads the dump instead of re-introspecting
        @requests.clear
        expect(GraphWeaver.new(url, cache: path).schema.types).to have_key "Person"
        expect(@requests).to be_empty
      end
    end
  end

  describe "client-scoped scalars" do
    let(:query) { "query { person(id: 1) { birthday } }" }

    it "overlays the global registry per client, without leaking" do
      client = GraphWeaver.new(Demo::Schema)
      client.register_scalar("Date", type: String, cast: :itself, serialize: :itself)

      # this client: Date stays a raw String off the wire
      expect(client.execute!(query).person&.birthday).to be_a String

      # other clients and the global registry are untouched
      expect(GraphWeaver.new(Demo::Schema).execute!(query).person&.birthday).to be_a Date
      expect(GraphWeaver::Codegen.scalar("Date").type).to eq "Date"
    end
  end
end
