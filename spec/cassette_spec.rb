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

      def execute(query, variables:)
        @calls += 1
        Demo::Schema.execute(query, variables:)
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

    it "matches on query AND variables, raising helpfully on a miss" do
      GraphWeaver::Testing::Recorder.new(live, path)
        .execute(PersonQuery::QUERY, variables: { "id" => "1" })

      replay = GraphWeaver::Testing::Replayer.new(path)
      expect {
        replay.execute(PersonQuery::QUERY, variables: { "id" => "2" })
      }.to raise_error(GraphWeaver::Testing::MissingRecording, /no recording|re-record/)
    end

    it "Cassette.use records when the file is missing, replays when present" do
      first = GraphWeaver::Testing::Cassette.use(path, client: live)
      expect(first).to be_a GraphWeaver::Testing::Recorder
      PersonQuery.execute!(first, id: "1")

      second = GraphWeaver::Testing::Cassette.use(path, client: live)
      expect(second).to be_a GraphWeaver::Testing::Replayer
      expect(PersonQuery.execute!(second, id: "1").person&.name).to eq "Daniel"
      expect(live.calls).to eq 1
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
      described_class.use(path, client: live).execute(PersonQuery::QUERY, variables: { "id" => "1" })
      expect(live.calls).to eq 1

      GraphWeaver::Testing.configure { |config| config.record = true }
      executor = described_class.use(path, client: live)
      expect(executor).to be_a GraphWeaver::Testing::Recorder
      executor.execute(PersonQuery::QUERY, variables: { "id" => "1" })
      expect(live.calls).to eq 2 # hit the live executor again
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
        .execute(PersonQuery::QUERY, variables: { "id" => "1" })
      described_class.new(path).anonymize!(schema: Demo::Schema, seed: 5)

      person = PersonQuery.execute!(GraphWeaver::Testing::Replayer.new(path), id: "1").person

      expect(person&.name).to be_a String
      expect(person&.name).not_to eq "Daniel"
      expect(person&.birthday).to be_a(Date).or be_nil
    end
  end
end
