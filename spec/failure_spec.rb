require "graph_weaver/testing"
require_relative "generated/person_query"

describe "failure simulation" do
  after { GraphWeaver::Testing.reset! }

  let(:failure) { GraphWeaver::Testing::Failure }
  let(:fake) { GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1) }

  describe GraphWeaver::Testing::Failure do
    it "simulates network failures with the cause preserved" do
      expect {
        PersonQuery.execute(failure.transport, id: "1")
      }.to raise_error(GraphWeaver::TransportError) do |e|
        expect(e.cause).to be_a SocketError
      end
    end

    it "simulates non-2xx responses" do
      expect {
        PersonQuery.execute(failure.server(status: 502, body: "bad gateway"), id: "1")
      }.to raise_error(GraphWeaver::ServerError) do |e|
        expect(e.status).to eq 502
      end
    end

    it "simulates GraphQL errors, with optional partial data" do
      executor = failure.graphql(
        { message: "boom", path: ["person"], extensions: { code: "BOOM" } },
        data: { "person" => nil },
      )

      response = PersonQuery.execute(executor, id: "1")
      expect(response.errors?).to be true
      expect(response.errors_at("person").first&.code).to eq "BOOM"
      expect { response.data! }.to raise_error(GraphWeaver::QueryError) do |e|
        expect(e.codes).to eq ["BOOM"]
      end
    end

    it "simulates throttling and schema staleness" do
      throttled = PersonQuery.execute(failure.throttled, id: "1")
      expect(throttled.errors.first&.code).to eq "THROTTLED"
      expect(throttled.schema_stale?).to be false

      stale = PersonQuery.execute(failure.stale_schema, id: "1")
      expect(stale.schema_stale?).to be true
      expect { stale.data! }.to raise_error(GraphWeaver::QueryError, /regenerate/)
    end

    it "stale_schema names a specific field, or samples a real one from the schema" do
      named = PersonQuery.execute(failure.stale_schema(type: "Person", field: "name"), id: "1")
      expect(named.errors.first&.message).to eq "Field 'name' doesn't exist on type 'Person'"

      sampled = PersonQuery.execute(failure.stale_schema(schema: Demo::Schema, seed: 3), id: "1")
      message = sampled.errors.first&.message
      expect(message).to match(/Field '\w+' doesn't exist on type '(Person|Pet|Query|Mutation)'/)
      expect(sampled.schema_stale?).to be true
    end
  end

  describe GraphWeaver::Testing::Sequence do
    it "fails N times then succeeds — retry testing" do
      executor = GraphWeaver::Testing::Sequence.new(
        failure.transport,
        failure.transport,
        fake,
      )

      2.times do
        expect { PersonQuery.execute(executor, id: "1") }.to raise_error(GraphWeaver::TransportError)
      end
      expect(PersonQuery.execute!(executor, id: "1").person).not_to be_nil
      expect(PersonQuery.execute!(executor, id: "1").person).not_to be_nil # last repeats
    end
  end

  describe "FakeClient failure injection" do
    it "simulates type mismatches via corrupt: — the wrong-typed value is derived" do
      corrupt = GraphWeaver::Testing::FakeClient.new(
        schema: Demo::Schema,
        seed: 1,
        corrupt: "Person.birthday",
      )

      expect {
        PersonQuery.execute(corrupt, id: "1")
      }.to raise_error(GraphWeaver::TypeError) do |e|
        expect(e.struct.name).to eq "PersonQuery::Result::Person"
      end
    end

    it "corrupts strings and object lists by kind" do
      # String field gets an Integer
      name_corrupt = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1, corrupt: "Person.name")
      expect {
        PersonQuery.execute(name_corrupt, id: "1")
      }.to raise_error(GraphWeaver::TypeError) do |e|
        expect(e.struct.name).to eq "PersonQuery::Result::Person"
      end

      # list elements get non-Hash values; the sig on Pet.from_h rejects
      # them at the call site, so Person owns the failure and the cause
      # names Pet
      pets_corrupt = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1, corrupt: "Person.pets")
      expect {
        PersonQuery.execute(pets_corrupt, id: "1")
      }.to raise_error(GraphWeaver::TypeError) do |e|
        expect(e.struct.name).to eq "PersonQuery::Result::Person"
        expect(e.cause&.message).to include("Pet.from_h")
      end
    end

    it "overrides remain the manual escape hatch for exact corrupt values" do
      executor = GraphWeaver::Testing::FakeClient.new(
        schema: Demo::Schema,
        seed: 1,
        overrides: { "Person.birthday" => "not-iso8601" },
      )

      expect { PersonQuery.execute(executor, id: "1") }.to raise_error(GraphWeaver::TypeError)
    end

    it "appends verbatim errors alongside fake data" do
      executor = GraphWeaver::Testing::FakeClient.new(
        schema: Demo::Schema,
        seed: 1,
        errors: [{ message: "cost warning", extensions: { code: "EXPENSIVE" } }],
      )

      response = PersonQuery.execute(executor, id: "1")
      expect(response.data&.person).not_to be_nil # data AND errors
      expect(response.errors.first&.code).to eq "EXPENSIVE"
    end

    it "fail_at nulls a nullable field and records its error" do
      executor = GraphWeaver::Testing::FakeClient.new(
        schema: Demo::Schema,
        seed: 1,
        fail_at: { path: "person.birthday", message: "hidden", code: "PRIVATE" },
      )

      response = PersonQuery.execute(executor, id: "1")
      person = response.data&.person

      expect(person&.birthday).to be_nil
      expect(person&.name).not_to be_nil # the rest of the response survives
      expect(response.errors_at("person.birthday").first&.code).to eq "PRIVATE"
    end

    it "fail_at bubbles past non-null positions to the nearest nullable ancestor" do
      # pets is [Pet!]! — name fails, the non-null element bubbles the
      # list, the non-null list bubbles to person (the nearest nullable
      # spot), exactly like a real server's error propagation
      executor = GraphWeaver::Testing::FakeClient.new(
        schema: Demo::Schema,
        seed: 1,
        list_size: 2..2,
        fail_at: "person.pets.name",
      )

      response = PersonQuery.execute(executor, id: "1")

      expect(response.data&.person).to be_nil
      error = response.errors.first
      expect(error&.path).to eq ["person", "pets", 0, "name"] # concrete, with index
      expect(error&.field).to eq "person.pets.name"
      expect(response.errors_at("person.pets").size).to eq 1
    end
  end
end
