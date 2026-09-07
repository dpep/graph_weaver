require "tmpdir"
require "graph_weaver/testing"
require_relative "generated/person_query"

describe GraphWeaver::Testing::Cassette do
  after { GraphWeaver::Testing.reset! }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  let(:path) { File.join(@dir, "demo.yml") }

  # a live executor that counts how often it's actually hit
  let(:live) do
    Class.new do
      attr_reader :calls

      def initialize
        @calls = 0
      end

      def execute(query, variables:, operation_name: nil)
        @calls += 1
        Demo::Schema.execute(query, variables:, operation_name:)
      end
    end.new
  end

  describe "record and replay" do
    it "records through a live executor, then replays without it" do
      recorder = GraphWeaver::Testing::Recorder.new(live, path)
      recorded = PersonQuery.execute!(recorder, id: "1")
      expect(recorded.person&.name).to eq "Daniel"
      expect(live.calls).to eq 1

      replayed = PersonQuery.execute!(GraphWeaver::Testing::Replayer.new(path), id: "1")
      expect(replayed.person&.name).to eq "Daniel"
      expect(replayed.person&.pets&.map(&:name)).to eq %w[Shelby Brownie]
      expect(live.calls).to eq 1 # replay never touched the live executor
    end

    it "matches on query AND variables, naming both on a miss" do
      GraphWeaver::Testing::Recorder.new(live, path)
        .execute(PersonQuery::QUERY, variables: { "id" => "1" })

      replay = GraphWeaver::Testing::Replayer.new(path)
      expect {
        replay.execute(PersonQuery::QUERY, variables: { "id" => "2" })
      }.to raise_error(GraphWeaver::Testing::MissingRecording) { |error|
        expect(error.message).to include('variables: {"id" => "2"}')
        expect(error.message).to include('1 entry recorded for this query, with variables {"id" => "1"}')
        expect(error.message).to include("re-record")
      }
    end

    it "says so when nothing was recorded for the query itself" do
      GraphWeaver::Testing::Recorder.new(live, path)
        .execute(PersonQuery::QUERY, variables: { "id" => "1" })

      expect {
        GraphWeaver::Testing::Replayer.new(path).execute("query { people { id } }")
      }.to raise_error(GraphWeaver::Testing::MissingRecording, /no entry recorded for this query \(1 in the cassette\)/)
    end

    it "keys on the operation name, so one document's two operations don't collide" do
      document = <<~GQL
        query One { named(name: "Daniel") { name } }
        query Two { named(name: "Shelby") { name } }
      GQL
      recorder = GraphWeaver::Testing::Recorder.new(live, path)
      recorder.execute(document, operation_name: "One")
      recorder.execute(document, operation_name: "Two")

      replay = GraphWeaver::Testing::Replayer.new(path)
      expect(replay.execute(document, operation_name: "One").dig("data", "named", "name")).to eq "Daniel"
      expect(replay.execute(document, operation_name: "Two").dig("data", "named", "name")).to eq "Shelby"
      expect { replay.execute(document, operation_name: "Three") }
        .to raise_error(GraphWeaver::Testing::MissingRecording)
    end

    it "Testing.cassette records when the file is missing, replays when present" do
      first = GraphWeaver::Testing.cassette(path, client: live)
      expect(first).to be_a GraphWeaver::Testing::Recorder
      PersonQuery.execute!(first, id: "1")

      second = GraphWeaver::Testing.cassette(path, client: live)
      expect(second).to be_a GraphWeaver::Testing::Replayer
      expect(PersonQuery.execute!(second, id: "1").person&.name).to eq "Daniel"
      expect(live.calls).to eq 1
    end

    it "names the first-run situation instead of borrowing MissingRecording" do
      expect { GraphWeaver::Testing.cassette(path) }
        .to raise_error(GraphWeaver::Error, /demo\.yml doesn't exist and no `client:` was given to record with/)
    end

    it "matches on the entry's own query and variables — nothing else is stored" do
      query = "query { people { id } }"
      File.write(path, YAML.dump([{ "query" => query, "variables" => {}, "response" => { "data" => {} } }]))

      expect(described_class.new(path).lookup(query, {})).not_to be_nil

      described_class.new(path).record(query, { "id" => "1" }, { "data" => {} })
      expect(File.read(path)).not_to include("key:") # one representation of the request, not two
    end

    it "resolves bare names against config.cassette_dir" do
      GraphWeaver::Testing.configure { |config| config.cassette_dir = @dir }

      GraphWeaver::Testing::Recorder.new(live, "github")
        .execute(PersonQuery::QUERY, variables: { "id" => "1" })

      expect(File).to exist(File.join(@dir, "github.yml"))
    end
  end

  describe "record mode and anonymize-on-record" do
    it "config.record forces re-recording even when the cassette exists" do
      GraphWeaver::Testing.cassette(path, client: live).execute(PersonQuery::QUERY, variables: { "id" => "1" })
      expect(live.calls).to eq 1

      GraphWeaver::Testing.configure { |config| config.record = true }
      executor = GraphWeaver::Testing.cassette(path, client: live)
      expect(executor).to be_a GraphWeaver::Testing::Recorder
      executor.execute(PersonQuery::QUERY, variables: { "id" => "1" })
      expect(live.calls).to eq 2 # hit the live executor again
    end

    it "refuses to replay in record mode, rather than serving a stale recording" do
      GraphWeaver::Testing.cassette(path, client: live).execute(PersonQuery::QUERY, variables: { "id" => "1" })
      GraphWeaver::Testing.configure { |config| config.record = true }

      expect { GraphWeaver::Testing.cassette(path) }
        .to raise_error(GraphWeaver::Error, /record mode is on but no `client:` was given for .*demo\.yml/)
    end

    it "config.anonymize scrubs responses as they are recorded" do
      GraphWeaver::Testing.configure do |config|
        config.schema = Demo::Schema
        config.anonymize = true
        config.seed = 5
      end

      recorder = GraphWeaver::Testing::Recorder.new(live, path)
      returned = recorder.execute(PersonQuery::QUERY, variables: { "id" => "1" })

      recorded = described_class.new(path).lookup(PersonQuery::QUERY, { "id" => "1" })
      name = recorded.dig("response", "data", "person", "name")
      expect(name).not_to eq "Daniel" # scrubbed on disk
      expect(returned.dig("data", "person", "name")).to eq name # caller sees the same
    end

    it "anonymize-on-record requires a schema" do
      GraphWeaver::Testing.configure { |config| config.anonymize = true }

      expect {
        GraphWeaver::Testing::Recorder.new(live, path)
      }.to raise_error(ArgumentError, /schema/)
    end
  end

  describe "#anonymize!" do
    let(:query) do
      <<~GRAPHQL
        query($id: ID!) {
          person(id: $id) {
            id
            name
            email
            birthday
            pets { name species }
          }
        }
      GRAPHQL
    end

    let(:response) do
      { "data" => { "person" => {
        "id" => "42",
        "name" => "Real Customer",
        "email" => "real@customer.com",
        "birthday" => nil,
        "pets" => [
          { "name" => "Fluffy", "species" => "CAT" },
          { "name" => "Rex", "species" => "DOG" },
        ],
      } } }
    end

    it "replaces values but preserves shape, nulls, and enums" do
      cassette = described_class.new(path)
      cassette.record(query, { "id" => "42" }, response)
      cassette.anonymize!(schema: Demo::Schema, seed: 5)

      person = described_class.new(path).lookup(query, { "id" => "42" }).dig("response", "data", "person")

      expect(person["name"]).not_to eq "Real Customer"
      expect(person["email"]).not_to eq "real@customer.com"
      expect(person["email"]).to match(/@/) # semantically faked
      expect(person["birthday"]).to be_nil # null position preserved
      expect(person["pets"].size).to eq 2 # list length preserved
      expect(person["pets"].map { |p| p["species"] }).to eq %w[CAT DOG] # enums preserved
      expect(person["pets"].map { |p| p["name"] }).not_to include("Fluffy", "Rex")
    end

    it "maps ids consistently so relationships survive" do
      list_query = "query { people { id name } }"
      data = { "data" => { "people" => [
        { "id" => "7", "name" => "A" },
        { "id" => "9", "name" => "B" },
        { "id" => "7", "name" => "A again" },
      ] } }

      cassette = described_class.new(path)
      cassette.record(list_query, {}, data)
      cassette.anonymize!(schema: Demo::Schema, seed: 5)

      ids = described_class.new(path).lookup(list_query, {})
        .dig("response", "data", "people").map { |p| p["id"] }

      expect(ids[0]).to eq ids[2]      # same original id => same fake id
      expect(ids[0]).not_to eq ids[1]  # different ids stay distinct
      expect(ids[0]).not_to eq "7"     # and the original is gone
    end

    it "anonymized cassettes still cast through generated modules" do
      GraphWeaver::Testing::Recorder.new(live, path)
        .execute(PersonQuery::QUERY, variables: { "id" => "1" },
          operation_name: PersonQuery::OPERATION_NAME)
      described_class.new(path).anonymize!(schema: Demo::Schema, seed: 5)

      person = PersonQuery.execute!(GraphWeaver::Testing::Replayer.new(path), id: "1").person

      expect(person&.name).to be_a String
      expect(person&.name).not_to eq "Daniel"
      expect(person&.birthday).to be_a(Date).or be_nil
    end
  end

  describe "review fixes" do
    it "records symbol-keyed variables and reloads without crashing" do
      query = "query($id: ID!) { person(id: $id) { name } }"
      described_class.new(path).record(query, { id: "1" }, { "data" => {} })

      # reload (safe_load) — symbols would raise Psych::DisallowedClass before normalizing
      reloaded = nil
      expect { reloaded = described_class.new(path) }.not_to raise_error
      expect(reloaded.lookup(query, { "id" => "1" })).not_to be_nil
    end

    it "records against a Client, the call the docs show" do
      recorder = GraphWeaver::Testing.cassette(path, client: GraphWeaver.new(Demo::Schema))

      expect(PersonQuery.execute!(recorder, id: "1").person&.name).to eq "Daniel"
      expect(described_class.new(path).size).to eq 1
    end

    it "rejects a client that can't execute, instead of failing at the call site" do
      expect { GraphWeaver.resolve_transport({}) }
        .to raise_error(GraphWeaver::Error, /must respond to #execute.*Hash/)
    end

    it "keeps concrete-fragment fields when the recorded data has no __typename" do
      query = "query { named { name ... on Pet { species } } }"
      response = { "data" => { "named" => { "name" => "Shelby", "species" => "DOG" } } }
      cassette = described_class.new(path)
      cassette.record(query, {}, response)
      cassette.anonymize!(schema: Demo::Schema, seed: 5)

      named = described_class.new(path).lookup(query, {}).dig("response", "data", "named")
      expect(named).to have_key("species") # was dropped before the anonymizer relaxation
    end
  end
end

RSpec.describe "#{GraphWeaver::Testing}.cassette_path" do
  it "resolves the configured directory against Rails.root" do
    # a rake task runs from wherever it runs from; the cassettes don't move
    stub_const("Rails", Module.new do
      def self.root = Pathname.new("/srv/myapp")
    end)

    expect(GraphWeaver::Testing.cassette_path("github")).to eq "/srv/myapp/spec/cassettes/github.yml"
  end

  it "leaves an explicit path alone" do
    expect(GraphWeaver::Testing.cassette_path("other/dir/x.yml")).to eq "other/dir/x.yml"
  end
end
