require "graph_weaver/testing"
require_relative "generated/person_query"

describe "failure simulation" do
  after { GraphWeaver::Testing.reset! }

  let(:failure) { GraphWeaver::Testing::Failure }
  let(:fake) { GraphWeaver::Testing::FakeExecutor.new(schema: Demo::Schema, seed: 1) }

  describe GraphWeaver::Testing::Failure do
    it "simulates network failures with the cause preserved" do
      expect {
        PersonQuery.execute(id: "1", executor: failure.transport)
      }.to raise_error(GraphWeaver::TransportError) do |e|
        expect(e.cause).to be_a SocketError
      end
    end

    it "simulates non-2xx responses" do
      expect {
        PersonQuery.execute(id: "1", executor: failure.server(status: 502, body: "bad gateway"))
      }.to raise_error(GraphWeaver::ServerError) do |e|
        expect(e.status).to eq 502
      end
    end

    it "simulates GraphQL errors, with optional partial data" do
      executor = failure.graphql(
        { message: "boom", path: ["person"], extensions: { code: "BOOM" } },
        data: { "person" => nil },
      )

      response = PersonQuery.execute(id: "1", executor:)
      expect(response.errors?).to be true
      expect(response.errors_at("person").first&.code).to eq "BOOM"
      expect { response.data! }.to raise_error(GraphWeaver::QueryError) do |e|
        expect(e.codes).to eq ["BOOM"]
      end
    end

    it "simulates throttling and schema staleness" do
      throttled = PersonQuery.execute(id: "1", executor: failure.throttled)
      expect(throttled.errors.first&.code).to eq "THROTTLED"
      expect(throttled.schema_stale?).to be false

      stale = PersonQuery.execute(id: "1", executor: failure.stale_schema)
      expect(stale.schema_stale?).to be true
      expect { stale.data! }.to raise_error(GraphWeaver::QueryError, /regenerate/)
    end
  end

  describe GraphWeaver::Testing::SequenceExecutor do
    it "fails N times then succeeds — retry testing" do
      executor = GraphWeaver::Testing::SequenceExecutor.new(
        failure.transport,
        failure.transport,
        fake,
      )

      2.times do
        expect { PersonQuery.execute(id: "1", executor:) }.to raise_error(GraphWeaver::TransportError)
      end
      expect(PersonQuery.execute!(id: "1", executor:).person).not_to be_nil
      expect(PersonQuery.execute!(id: "1", executor:).person).not_to be_nil # last repeats
    end
  end

  describe "FakeExecutor failure injection" do
    it "simulates type mismatches via overrides" do
      corrupt = GraphWeaver::Testing::FakeExecutor.new(
        schema: Demo::Schema,
        seed: 1,
        overrides: { "Person.birthday" => 123 },
      )

      expect {
        PersonQuery.execute(id: "1", executor: corrupt)
      }.to raise_error(GraphWeaver::TypeError) do |e|
        expect(e.struct.name).to eq "PersonQuery::Result::Person"
      end
    end

    it "appends verbatim errors alongside fake data" do
      executor = GraphWeaver::Testing::FakeExecutor.new(
        schema: Demo::Schema,
        seed: 1,
        errors: [{ message: "cost warning", extensions: { code: "EXPENSIVE" } }],
      )

      response = PersonQuery.execute(id: "1", executor:)
      expect(response.data&.person).not_to be_nil # data AND errors
      expect(response.errors.first&.code).to eq "EXPENSIVE"
    end

    it "fail_at nulls a nullable field and records its error" do
      executor = GraphWeaver::Testing::FakeExecutor.new(
        schema: Demo::Schema,
        seed: 1,
        fail_at: { path: "person.birthday", message: "hidden", code: "PRIVATE" },
      )

      response = PersonQuery.execute(id: "1", executor:)
      person = response.data&.person

      expect(person&.birthday).to be_nil
      expect(person&.name).not_to be_nil # the rest of the response survives
      expect(response.errors_at("person.birthday").first&.code).to eq "PRIVATE"
    end

    it "fail_at bubbles past non-null positions to the nearest nullable ancestor" do
      # pets is [Pet!]! — name fails, the non-null element bubbles the
      # list, the non-null list bubbles to person (the nearest nullable
      # spot), exactly like a real server's error propagation
      executor = GraphWeaver::Testing::FakeExecutor.new(
        schema: Demo::Schema,
        seed: 1,
        list_size: 2..2,
        fail_at: "person.pets.name",
      )

      response = PersonQuery.execute(id: "1", executor:)

      expect(response.data&.person).to be_nil
      error = response.errors.first
      expect(error&.path).to eq ["person", "pets", 0, "name"] # concrete, with index
      expect(error&.field).to eq "person.pets.name"
      expect(response.errors_at("person.pets").size).to eq 1
    end
  end
end
