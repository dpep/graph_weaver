# typed: ignore

require "graph_weaver/testing"

# What an app meets when the server's schema moved and nobody regenerated.
describe "schema drift at runtime" do
  def rejection(sdl, query)
    schema = GraphQL::Schema.from_definition(sdl)
    raw = GraphWeaver::InProcess.new(schema).execute(query, variables: {})
    GraphWeaver::GraphQLError.from_h(raw["errors"].first)
  end

  BASE = "type Query { me: User } type User { name: String }"

  # graphql-ruby names the rule that fired; only Apollo uses one flat code,
  # and this library ships graphql-ruby as its in-process client
  {
    "a field the query selects is gone" => [BASE, "{ me { nope } }"],
    "a type the query names is gone" => [BASE, "{ me { ... on Gone { name } } }"],
    "an argument is no longer accepted" => [BASE, "{ me(x: 1) { name } }"],
    "an argument became required" => [
      "type Query { me(id: ID!): User } type User { name: String }", "{ me { name } }",
    ],
  }.each do |drift, (sdl, query)|
    it "says the schema may be stale when #{drift}" do
      error = rejection(sdl, query)

      expect(error.validation?).to be true

      # and the envelope the app actually rescues says so, with the fix
      query_error = GraphWeaver::QueryError.new([error])
      expect(query_error.schema_stale?).to be true
      expect(query_error.message).to include "regenerate"
    end
  end

  it "doesn't cry drift over an ordinary resolver failure" do
    error = GraphWeaver::GraphQLError.from_h(
      "message" => "Something went wrong", "extensions" => { "code" => "INTERNAL_SERVER_ERROR" },
    )

    expect(error.validation?).to be false
  end

  # a field widening to nullable, with the server saying why — the reason
  # used to be evaluated after the cast that raised, so nobody saw it
  it "keeps the server's explanation when the cast fails" do
    require_relative "generated/person_query"
    wire = {
      "data" => { "person" => { "id" => "1", "name" => nil, "birthday" => nil, "pets" => [] } },
      "errors" => [{ "message" => "name is hidden", "extensions" => { "code" => "PRIVATE" } }],
    }

    expect { PersonQuery.from_response(wire) }
      .to raise_error(GraphWeaver::TypeError, /the server also reported: name is hidden/)
  end
end
