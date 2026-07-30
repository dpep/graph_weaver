# typed: ignore — UserQuery is eval'd at runtime, invisible to srb

# Apollo Federation: a router exposes a supergraph whose SDL is annotated
# with join__/link directives. SchemaLoader strips that composition
# machinery, so codegen runs against a supergraph SDL directly — no
# graphql-ruby monkeypatch, and the synthetic join__* types never leak in.
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
    # the real join v0.3 directive shape, defaulted non-null args and all
    directive @join__type(graph: join__Graph!, key: join__FieldSet, extension: Boolean! = false, resolvable: Boolean! = true, isInterfaceObject: Boolean! = false) repeatable on OBJECT | INTERFACE | UNION | ENUM | INPUT_OBJECT | SCALAR
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

  let(:schema) { GraphWeaver::SchemaLoader.load(SUPERGRAPH_SDL) }

  it "strips the composition machinery — no join__*/link__* leaks into the schema" do
    expect(schema.types.keys.grep(/join__|link__/)).to be_empty
    expect(schema.get_type("User").fields.keys).to eq %w[id name petNames]
  end

  let(:source) do
    GraphWeaver::Codegen.new(
      schema:,
      client: "FederatedSchema",
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
