# typed: ignore

require "graph_weaver/testing"

# The client slot is one contract, so the fake has to answer an invalid query
# the way the others do — it backs the default testing mode, and this is the
# mistake a developer makes most.
describe GraphWeaver::Testing::FakeClient do
  let(:schema) do
    GraphQL::Schema.from_definition("type Query { me: User } type User { name: String }")
  end

  it "reports an unknown field the way a real server does" do
    result = described_class.new(schema:).execute("query { me { nmae } }", variables: {})

    expect(result["data"]).to be_nil
    expect(result.dig("errors", 0, "message"))
      .to eq "Field 'nmae' doesn't exist on type 'User' (Did you mean `name`?)"
  end

  it "agrees with InProcess on the same query" do
    query = "query { me { nmae } }"

    expect(described_class.new(schema:).execute(query, variables: {}).dig("errors", 0, "message"))
      .to eq GraphWeaver::InProcess.new(schema).execute(query, variables: {}).dig("errors", 0, "message")
  end

  it "still fabricates a valid query" do
    result = described_class.new(schema:).execute("query { me { name } }", variables: {})

    expect(result["errors"]).to be_nil
    expect(result.dig("data", "me", "name")).to be_a String
  end
end
