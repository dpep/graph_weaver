# typed: ignore — UserQuery is eval'd at runtime, invisible to srb
require_relative "../lib/struct_codegen"

# Apollo Federation: a router exposes a supergraph whose SDL is annotated
# with join__/link directives. From a client's perspective those are
# transparent — the API surface is a normal schema. This proves codegen
# runs against a supergraph SDL directly.
describe "federation / supergraph" do
  SUPERGRAPH_SDL = <<~GRAPHQL
    schema
      @link(url: "https://specs.apollo.dev/link/v1.0")
      @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
    {
      query: Query
    }

    directive @link(url: String!, as: String, for: link__Purpose, import: [link__Import]) repeatable on SCHEMA
    directive @join__graph(name: String!, url: String!) on ENUM_VALUE
    # note: graphql-ruby's SDL builder does not apply directive-argument
    # defaults, so the non-null defaulted args from the real join v0.3
    # spec (extension: Boolean! = false, ...) are omitted here
    directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT | INTERFACE | UNION | ENUM | INPUT_OBJECT | SCALAR
    directive @join__field(graph: join__Graph, requires: join__FieldSet, provides: join__FieldSet, type: String, external: Boolean, override: String, usedOverridden: Boolean) repeatable on FIELD_DEFINITION | INPUT_FIELD_DEFINITION

    scalar join__FieldSet
    scalar link__Import

    enum link__Purpose {
      SECURITY
      EXECUTION
    }

    enum join__Graph {
      USERS @join__graph(name: "users", url: "http://users/graphql")
      PETS @join__graph(name: "pets", url: "http://pets/graphql")
    }

    type Query @join__type(graph: USERS) @join__type(graph: PETS) {
      user(id: ID!): User @join__field(graph: USERS)
    }

    type User @join__type(graph: USERS, key: "id") @join__type(graph: PETS, key: "id") {
      id: ID!
      name: String! @join__field(graph: USERS)
      petNames: [String!]! @join__field(graph: PETS)
    }
  GRAPHQL

  let(:schema) { GraphQL::Schema.from_definition(SUPERGRAPH_SDL) }

  let(:source) do
    StructCodegen.new(
      schema:,
      schema_const: "FederatedSchema",
      query: "query($id: ID!) { user(id: $id) { id name petNames } }",
      module_name: "UserQuery",
    ).generate
  end

  it "generates structs from a supergraph SDL; join directives are transparent" do
    expect(source).to include("const :pet_names, T::Array[String]")
    expect(source).to include('pet_names: data.fetch("petNames")')
  end

  it "the generated module casts responses (no live subgraphs needed)" do
    eval(source) # rubocop:disable Security/Eval -- exercising generated code

    result = UserQuery::Result.from_h(
      "user" => { "id" => "1", "name" => "Daniel", "petNames" => ["Shelby"] },
    )

    expect(result.user&.name).to eq "Daniel"
    expect(result.user&.pet_names).to eq ["Shelby"]
  end
end
