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

  # the older spelling of the same machinery: @core instead of @link, plus
  # @join__owner
  it "loads a federation v1 supergraph" do
    schema = GraphWeaver::SchemaLoader.load(<<~GRAPHQL)
      schema
        @core(feature: "https://specs.apollo.dev/core/v0.1")
        @core(feature: "https://specs.apollo.dev/join/v0.1", for: EXECUTION)
      {
        query: Query
      }

      directive @core(feature: String!, for: core__Purpose) repeatable on SCHEMA
      directive @join__owner(graph: join__Graph!) on OBJECT | INTERFACE
      directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT | INTERFACE
      directive @join__field(graph: join__Graph, requires: join__FieldSet) on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE

      scalar join__FieldSet
      enum core__Purpose { EXECUTION SECURITY }
      enum join__Graph { USERS @join__graph(name: "users", url: "http://users/graphql") }

      type Query { user(id: ID!): User @join__field(graph: USERS) }

      type User @join__owner(graph: USERS) @join__type(graph: USERS, key: "id") {
        id: ID! @join__field(graph: USERS)
        name: String! @join__field(graph: USERS)
      }
    GRAPHQL

    expect(schema.types.keys.grep(/join__|core__/)).to be_empty
    expect(schema.get_type("User").fields.keys).to eq %w[id name]
  end
end

# Which names are federation's own is declared by the schema, through @link
# (fed 2) or @core (fed 1) — the spec URL names the namespace, `as:` renames
# it, and `import:` binds names into the root namespace. Reading those beats
# a fixed join__/link__/core__ list: the fixed list misses every graph that
# uses a spec it doesn't know, and misses a renamed @inaccessible entirely.
describe "federation / @link namespaces" do
  def load(sdl) = GraphWeaver::SchemaLoader.load(sdl)

  LINK_DEF = <<~GRAPHQL
    directive @link(url: String!, as: String, for: link__Purpose, import: [link__Import]) repeatable on SCHEMA
    scalar link__Import
    enum link__Purpose { SECURITY EXECUTION }
    directive @join__type(graph: join__Graph!) repeatable on OBJECT
    enum join__Graph { A @join__graph(name: "a", url: "http://a") }
  GRAPHQL

  # fed 2.5+ auth: @requiresScopes/@policy/@context each bring a namespaced
  # type along, and none of those namespaces is join__/link__/core__
  it "strips the namespaces a fed-2.5 auth graph links" do
    schema = load(<<~GRAPHQL)
      schema
        @link(url: "https://specs.apollo.dev/link/v1.0")
        @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
        @link(url: "https://specs.apollo.dev/federation/v2.5", import: ["@requiresScopes", "@policy"])
        @link(url: "https://specs.apollo.dev/context/v0.1", for: SECURITY)
      {
        query: Query
      }

      #{LINK_DEF}
      directive @requiresScopes(scopes: [[federation__Scope!]!]!) on FIELD_DEFINITION | OBJECT
      directive @policy(policies: [[federation__Policy!]!]!) on FIELD_DEFINITION | OBJECT
      directive @context(name: String!) repeatable on OBJECT
      directive @context__fromContext(field: context__ContextFieldValue) on ARGUMENT_DEFINITION

      scalar federation__Scope
      scalar federation__Policy
      scalar context__ContextFieldValue

      type Query @join__type(graph: A) @context(name: "ctx") {
        user: User @requiresScopes(scopes: [["read:user"]]) @policy(policies: [["viewer"]])
      }

      type User @join__type(graph: A) { id: ID! name: String! }
    GRAPHQL

    expect(schema.types.keys.grep(/federation__|context__|join__|link__/)).to be_empty
    expect(schema.get_type("User").fields.keys).to eq %w[id name]
  end

  it "follows an `as:` rename of the join spec" do
    schema = load(<<~GRAPHQL)
      schema
        @link(url: "https://specs.apollo.dev/link/v1.0")
        @link(url: "https://specs.apollo.dev/join/v0.3", as: "j", for: EXECUTION)
      {
        query: Query
      }

      directive @link(url: String!, as: String, for: link__Purpose, import: [link__Import]) repeatable on SCHEMA
      scalar link__Import
      enum link__Purpose { SECURITY EXECUTION }
      directive @j__type(graph: j__Graph!) repeatable on OBJECT
      directive @j__field(graph: j__Graph) on FIELD_DEFINITION
      scalar j__FieldSet
      enum j__Graph { A @j__graph(name: "a", url: "http://a") }

      type Query @j__type(graph: A) { user: User @j__field(graph: A) }
      type User @j__type(graph: A) { id: ID! name: String! }
    GRAPHQL

    expect(schema.types.keys.grep(/j__|link__/)).to be_empty
    expect(schema.get_type("User").fields.keys).to eq %w[id name]
  end

  # the correctness one: a missed rename leaves the hidden field in the derived
  # API schema, so codegen over-permits what the router will actually serve
  {
    "an import: rename" =>
      '@link(url: "https://specs.apollo.dev/federation/v2.5", import: [{name: "@inaccessible", as: "@private"}])',
    "a spec-level as:" =>
      '@link(url: "https://specs.apollo.dev/inaccessible/v0.2", as: "private")',
  }.each do |label, link|
    it "hides a field behind @inaccessible renamed by #{label}" do
      schema = load(<<~GRAPHQL)
        schema
          @link(url: "https://specs.apollo.dev/link/v1.0")
          @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
          #{link}
        {
          query: Query
        }

        #{LINK_DEF}
        directive @private on FIELD_DEFINITION | OBJECT

        type Query @join__type(graph: A) { user: User }
        type User @join__type(graph: A) { id: ID! name: String! ssn: String @private }
      GRAPHQL

      expect(schema.get_type("User").fields.keys).to eq %w[id name]
      expect(schema.types.keys.grep(/join__|link__/)).to be_empty
    end
  end

  # fed 1 with nothing merged: no @join__ marker at all, but the core schema
  # still carries core__Purpose and still hides elements
  it "strips a @core-only fed-1 schema" do
    schema = load(<<~GRAPHQL)
      schema
        @core(feature: "https://specs.apollo.dev/core/v0.2")
        @core(feature: "https://specs.apollo.dev/inaccessible/v0.1", for: SECURITY)
      {
        query: Query
      }

      directive @core(feature: String!, as: String, for: core__Purpose) repeatable on SCHEMA
      directive @inaccessible on FIELD_DEFINITION | OBJECT
      enum core__Purpose { EXECUTION SECURITY }

      type Query { user: User }
      type User { id: ID! name: String! secret: String @inaccessible }
    GRAPHQL

    expect(schema.types.keys.grep(/core__/)).to be_empty
    expect(schema.get_type("User").fields.keys).to eq %w[id name]
  end

  # the other direction: derivation must not start eating names that merely
  # look federation-ish (v0.4.6 fixed a user type named `link` being dropped)
  it "keeps user types and fields that only look federation-ish" do
    schema = load(<<~GRAPHQL)
      schema
        @link(url: "https://specs.apollo.dev/link/v1.0")
        @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
      {
        query: Query
      }

      #{LINK_DEF}
      type Link @join__type(graph: A) { url: String! }
      type Query @join__type(graph: A) { join: String link: Link core: Int inaccessible: Boolean }
    GRAPHQL

    expect(schema.get_type("Link")).not_to be_nil
    expect(schema.get_type("Query").fields.keys).to eq %w[join link core inaccessible]
  end

  # https://specs.apollo.dev/link/v1.0/ — the last two path segments name the
  # spec: a query, a fragment and a trailing slash don't count, and a final
  # segment that isn't a version tag is the name itself
  it "normalizes the spec URL the way the link spec says" do
    schema = load(<<~GRAPHQL)
      schema
        @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
        @link(url: "https://spec.example.com/a/b/mySchema/v1.0/?q=v#frag")
        @link(url: "https://spec.example.com/vX")
        @link(url: "https://specs.apollo.dev/v1.0")
      {
        query: Query
      }

      directive @join__type(graph: join__Graph!) repeatable on OBJECT
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      scalar mySchema__Thing
      scalar vX__Thing

      type Query @join__type(graph: A) { a: Int }
    GRAPHQL

    expect(schema.types.keys.grep(/mySchema__|vX__/)).to be_empty
    # the nameless URL is an opaque identifier — it derives nothing, and takes
    # nothing with it
    expect(schema.get_type("Query").fields.keys).to eq %w[a]
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

  # apollo-federation emits fed-2 SDL as `extend schema @link(...)` with the
  # directives under the link's namespace — @federation__key, not @key
  it "loads a real fed-2 subgraph that @links the federation spec" do
    sdl = sdl_of(FederationDemo::UsersV2::Schema)
    expect(sdl).to include("@federation__key") # the shape under test

    expect(GraphWeaver::SchemaLoader.load(sdl).get_type("User").fields.keys).to eq %w[id name]
  end

  it "loads an unnamespaced @link subgraph too" do
    schema = GraphWeaver::SchemaLoader.load(<<~GRAPHQL)
      extend schema
        @link(url: "https://specs.apollo.dev/federation/v2.3", import: ["@key", "@shareable"])

      type Query { user(id: ID!): User }
      type User @key(fields: "id") { id: ID! name: String! @shareable }
    GRAPHQL

    expect(schema.get_type("User").fields.keys).to eq %w[id name]
  end

  # a duplicate definition is a hard error in graphql-ruby, so the subgraph's
  # own declarations must win and only the rest get supplied
  it "leaves a subgraph's own directive definitions alone" do
    schema = GraphWeaver::SchemaLoader.load(<<~GRAPHQL)
      directive @key(fields: _FieldSet!) repeatable on OBJECT
      scalar _FieldSet
      type Query { user: User }
      type User @key(fields: "id") { id: ID! email: String @external }
    GRAPHQL

    expect(schema.get_type("_FieldSet")).not_to be_nil
    expect(schema.get_type("FieldSet")).to be_nil # @key kept its own FieldSet type
    expect(schema.get_type("User").fields.keys).to eq %w[id email] # @external was supplied
  end

  # weaver's injected helper scalars are namespaced, so a subgraph is free to
  # own the obvious names — an unnamespaced `scalar FieldSet` used to be
  # shadowed by (or, for an object type, collide with) the injected @key
  it "doesn't collide with a subgraph's own FieldSet type" do
    schema = GraphWeaver::SchemaLoader.load(<<~GRAPHQL)
      type FieldSet { paths: [String!]! }
      type Query { user: User }
      type User @key(fields: "id") { id: ID! mask: FieldSet }
    GRAPHQL

    expect(schema.get_type("FieldSet").fields.keys).to eq %w[paths]
    expect(schema.get_type("User").fields["mask"].type.unwrap.graphql_name).to eq "FieldSet"
  end

  it "detects a subgraph, and doesn't mistake a plain schema or a supergraph for one" do
    expect(GraphWeaver::SchemaLoader.subgraph_sdl?(sdl_of(FederationDemo::Users::Schema))).to be true
    expect(GraphWeaver::SchemaLoader.subgraph_sdl?("type Query { a: Int }")).to be false
    expect(GraphWeaver::SchemaLoader.subgraph_sdl?(SUPERGRAPH_SDL)).to be false
  end

  # a published subgraph SDL never contains the entity resolver it serves, so
  # the artifact people actually hold can't type the one query only a subgraph
  # describes — weaver supplies the spec's plumbing the way it supplies @key
  describe "entity plumbing" do
    it "supplies _entities over the subgraph's own @key'd types" do
      schema = GraphWeaver::SchemaLoader.load(sdl_of(FederationDemo::Catalog::Schema))

      expect(schema.get_type("Query").fields.keys).to include("_entities", "_service")
      expect(schema.possible_types(schema.get_type("_Entity")).map(&:graphql_name))
        .to eq %w[Listing Product Variant Warehouse]
    end

    it "reads @key through a namespace, and through a type extension" do
      v2 = GraphWeaver::SchemaLoader.load(sdl_of(FederationDemo::UsersV2::Schema)) # @federation__key
      pets = GraphWeaver::SchemaLoader.load(sdl_of(FederationDemo::Pets::Schema)) # `extend type User`

      [v2, pets].each do |schema|
        expect(schema.possible_types(schema.get_type("_Entity")).map(&:graphql_name)).to eq %w[User]
      end
    end

    it "leaves a schema with no entities, and a subgraph that declares its own, alone" do
      plain = GraphWeaver::SchemaLoader.load("type Query { a: Int }")
      expect(plain.get_type("_Entity")).to be_nil

      own = GraphWeaver::SchemaLoader.load(<<~GRAPHQL)
        scalar _Any
        union _Entity = User
        type Query { user: User _entities(representations: [_Any!]!): [_Entity]! }
        type User @key(fields: "id") { id: ID! }
      GRAPHQL
      expect(own.get_type("Query").fields.keys).to eq %w[user _entities]
    end
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

# The input side of an _entities query. A representation must carry
# __typename and satisfy one of the entity's @key field sets — both hard
# requirements of the subgraph spec, and both invisible in a bare `[_Any!]!`
# variable. Codegen reads the @key directives the subgraph SDL carries and
# emits a typed builder per entity the query can resolve.
describe "federation / _entities representations" do
  def sdl_of(schema) = schema.execute("{ _service { sdl } }").to_h.dig("data", "_service", "sdl")

  # eval'd rather than required: the generated module is the thing under
  # test, and sorbet-runtime checks its sigs as we call them
  def build(schema, query, module_name)
    source = GraphWeaver::Codegen.new(schema:, query:, module_name:, client: "Fake").generate
    container = Module.new
    container.module_eval(source, "(graph_weaver spec)", 1)
    [container.const_get(module_name), source]
  end

  let(:catalog) { GraphWeaver::SchemaLoader.load(sdl_of(FederationDemo::Catalog::Schema)) }

  ENTITY_QUERY = "query($reps: [_Any!]!) { _entities(representations: $reps) { ... on %s } }"

  # Product's key is compound, Listing's nested, Variant's alternative —
  # Warehouse is an entity this query never names
  CATALOG_ENTITIES = <<~GRAPHQL
    query($reps: [_Any!]!) {
      _entities(representations: $reps) {
        __typename
        ... on Product { upc title }
        ... on Listing { id price }
        ... on Variant { id color }
      }
    }
  GRAPHQL

  let(:reps) { build(catalog, CATALOG_ENTITIES, "CatalogEntities").first::Representations }

  it "injects __typename and types a single key's fields as required kwargs" do
    schema = GraphWeaver::SchemaLoader.load(sdl_of(FederationDemo::Users::Schema))
    mod, source = build(schema, ENTITY_QUERY % "User { id name }", "UserEntities")

    expect(source).to include("def self.user(id:)")
    expect(mod::Representations.user(id: "1")).to eq({ "__typename" => "User", "id" => "1" })
  end

  it "builds a compound key, typed field by field from the schema" do
    expect(reps.product(upc: "u-1", sku: 42))
      .to eq({ "__typename" => "Product", "upc" => "u-1", "sku" => 42 })
    # Product.sku is Int! — the sig, not the wire, is what catches a bad one
    expect { reps.product(upc: "u-1", sku: "42") }.to raise_error(TypeError)
  end

  it "builds a nested key, keeping only what the key set declares" do
    expect(reps.listing(id: "1", organization: { id: "org-1" }))
      .to eq({ "__typename" => "Listing", "id" => "1", "organization" => { "id" => "org-1" } })
    # string keys read the same, and a field outside the key set stays off the wire
    expect(reps.listing(id: "1", organization: { "id" => "org-1", "name" => "Acme" }))
      .to eq({ "__typename" => "Listing", "id" => "1", "organization" => { "id" => "org-1" } })
  end

  it "lets either of two alternative keys resolve an entity" do
    expect(reps.variant(id: "v-1")).to eq({ "__typename" => "Variant", "id" => "v-1" })
    expect(reps.variant(serial: "s-1")).to eq({ "__typename" => "Variant", "serial" => "s-1" })
  end

  it "names the fix for an entity the selection never reached" do
    # builders are query-driven, so Warehouse has none — and a bare
    # NoMethodError points at nothing
    expect { reps.warehouse(id: "w-1") }.to raise_error(NoMethodError) do |e|
      expect(e.message).to include("no representation builder for Warehouse")
      expect(e.message).to include("this query builds: listing, product, variant")
      expect(e.message).to include("... on Warehouse { __typename }")
    end
  end

  it "raises on a representation that satisfies no key" do
    expect { reps.variant }.to raise_error(GraphWeaver::InputError, /Variant.*"id".*"serial"/)

    # a single key set names the one field that's short, on the error too
    expect { reps.listing(id: "1", organization: {}) }
      .to raise_error(GraphWeaver::InputError) { |e| expect(e.field).to eq "organization.id" }
  end

  it "emits builders only for the entities the query reaches" do
    expect(reps).to respond_to(:product, :listing, :variant)
    expect(reps).not_to respond_to(:warehouse) # an entity of the same subgraph

    # ...and none at all for a query that asks for no entities
    _, source = build(catalog, "{ warehouse { region } }", "WarehouseQuery")
    expect(source).not_to include("Representations")
  end

  # what docs/federation.md tells you to write: a built representation goes
  # straight into the [_Any!]! variable, and the result comes back typed
  it "feeds execute, which returns the entities in order" do
    sent = nil
    client = Class.new do
      define_method(:execute) do |_query, variables:, operation_name: nil|
        sent = variables
        { "data" => { "_entities" => [{ "__typename" => "Variant", "id" => "v-1", "color" => "red" }, nil] } }
      end
    end.new

    mod = build(catalog, CATALOG_ENTITIES, "CatalogExecute").first
    result = mod.execute!(client:, reps: [reps.variant(id: "v-1"), reps.variant(serial: "gone")])

    expect(sent["reps"]).to eq [
      { "__typename" => "Variant", "id" => "v-1" },
      { "__typename" => "Variant", "serial" => "gone" },
    ]
    # order-preserving with a null hole for what the subgraph couldn't resolve
    expect(result._entities.map { |e| e&.__typename }).to eq ["Variant", nil]
  end

  it "reads @key under a link namespace" do
    schema = GraphWeaver::SchemaLoader.load(sdl_of(FederationDemo::UsersV2::Schema)) # @federation__key
    mod, = build(schema, ENTITY_QUERY % "User { id }", "UserV2Entities")

    expect(mod::Representations.user(id: "1")).to eq({ "__typename" => "User", "id" => "1" })
  end

  # a builder is a Ruby method, so names that can't be one are refused at
  # generation rather than emitting a file that won't load
  {
    "an entity whose name is a Ruby keyword" => [
      "type End @key(fields: \"id\") { id: ID! }",
      "End { id }",
      /Representations\.end/,
    ],
    "two entities that build the same method" => [
      "type User @key(fields: \"id\") { id: ID! }\ntype USER @key(fields: \"id\") { id: ID! }",
      "User { id } __typename ... on USER { id }",
      /User and USER/,
    ],
    "a @key naming a field the type doesn't declare" => [
      "type Ghost @key(fields: \"missing\") { id: ID! }",
      "Ghost { id }",
      /Ghost @key names "missing"/,
    ],
    # a representation carries fields, so a field set that isn't plain
    # fields has no wire shape to build — refuse rather than guess at one
    "a @key field set holding anything but plain fields" => [
      "type Boxed @key(fields: \"... on Boxed { id }\") { id: ID! }",
      "Boxed { id }",
      /field set holds plain fields only/,
    ],
  }.each do |label, (types, condition, message)|
    it "refuses #{label}" do
      schema = GraphWeaver::SchemaLoader.load("type Query { anchor: String }\n#{types}")

      expect { build(schema, ENTITY_QUERY % condition, "RefusedEntities") }
        .to raise_error(GraphWeaver::Error, message)
    end
  end

  # `resolvable: false` declares a key this subgraph does NOT answer for, so
  # nothing can be resolved by it — a builder offering it would be a lie
  it "ignores a key the subgraph declares unresolvable" do
    schema = GraphWeaver::SchemaLoader.load(<<~GRAPHQL)
      type Query { user: User }
      type User @key(fields: "id") @key(fields: "email", resolvable: false) {
        id: ID! email: String!
      }
    GRAPHQL
    mod, source = build(schema, ENTITY_QUERY % "User { id }", "ResolvableEntities")

    expect(source).to include("def self.user(id:)") # id required, email absent
    expect(mod::Representations.user(id: "1")).to eq({ "__typename" => "User", "id" => "1" })
  end
end
