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

# The artifact a service repo actually holds — one subgraph's own SDL, which
# applies @key/@external/... without declaring them (fed-1 leaves them
# implicit, fed-2 imports them via @link). SchemaLoader supplies the missing
# definitions so it loads like any schema.
describe "federation / subgraph SDL" do
  # what `rover subgraph fetch` / `_service { sdl }` hands you
  def sdl_of(schema)
    schema.execute("{ _service { sdl } }").to_h.dig("data", "_service", "sdl")
  end

  it "loads a real fed-1 subgraph, keeping its own type shapes" do
    schema = GraphWeaver::SchemaLoader.load(sdl_of(FederationDemo::Users::Schema))

    expect(schema.get_type("User").fields.keys).to eq %w[id name]
    expect(schema.get_type("Query").fields["user"].type.unwrap.graphql_name).to eq "User"
  end

  it "loads a subgraph that extends an entity it doesn't own" do
    schema = GraphWeaver::SchemaLoader.load(sdl_of(FederationDemo::Pets::Schema))

    expect(schema.get_type("User").fields.keys).to eq %w[id petNames]
  end

  it "loads a fed-2 subgraph that @links the federation spec" do
    schema = GraphWeaver::SchemaLoader.load(<<~GRAPHQL)
      extend schema
        @link(url: "https://specs.apollo.dev/federation/v2.3", import: ["@key", "@shareable"])

      type Query { user(id: ID!): User }
      type User @key(fields: "id") { id: ID! name: String! @shareable }
    GRAPHQL

    expect(schema.get_type("User").fields.keys).to eq %w[id name]
  end

  it "leaves a subgraph's own directive definitions alone" do
    schema = GraphWeaver::SchemaLoader.load(<<~GRAPHQL)
      directive @key(fields: _FieldSet!) repeatable on OBJECT
      scalar _FieldSet
      type Query { user: User }
      type User @key(fields: "id") { id: ID! }
    GRAPHQL

    expect(schema.get_type("_FieldSet")).not_to be_nil
    expect(schema.get_type("FieldSet")).to be_nil
  end

  it "detects a subgraph, and doesn't mistake a plain schema or a supergraph for one" do
    expect(GraphWeaver::SchemaLoader.subgraph_sdl?(sdl_of(FederationDemo::Users::Schema))).to be true
    expect(GraphWeaver::SchemaLoader.subgraph_sdl?("type Query { a: Int }")).to be false
    expect(GraphWeaver::SchemaLoader.subgraph_sdl?(SUPERGRAPH_SDL)).to be false
  end

  it "generates typed structs from a subgraph SDL" do
    source = GraphWeaver::Codegen.new(
      schema: GraphWeaver::SchemaLoader.load(sdl_of(FederationDemo::Users::Schema)),
      client: "SubgraphSchema",
      query: "query($id: ID!) { user(id: $id) { id name } }",
      module_name: "SubgraphUserQuery",
    ).generate

    expect(source).to include("const :name, String")
  end
end
