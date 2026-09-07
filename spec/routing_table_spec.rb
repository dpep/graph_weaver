# typed: ignore — the subgraph classes are graphql-ruby DSL, invisible to srb
# frozen_string_literal: true

# The supergraph read as a routing table rather than as a schema: who
# resolves what, which keys they answer on, and what the table admits it
# cannot describe.
describe GraphWeaver::SchemaLoader::RoutingTable do
  # the canonical three-subgraph demo graph, composed by Apollo
  let(:table) { GraphWeaver::SchemaLoader.routing_table(RouterGraph::SUPERGRAPH) }

  it "names the subgraphs the way the router config does" do
    expect(table.subgraphs).to eq %w[accounts products reviews]
    expect(table.unsupported).to be_empty
  end

  it "routes a field to the subgraph that resolves it" do
    expect(table.owners("Query", "me")).to eq ["accounts"]
    expect(table.owners("Query", "topProducts")).to eq ["products"]
    expect(table.owners("User", "reviews")).to eq ["reviews"]
    expect(table.owners("Product", "shippingEstimate")).to eq ["reviews"]
  end

  # @external is a reference to a field owned elsewhere, so the subgraph
  # holding one is not a routing candidate
  it "excludes an @external copy from a field's owners" do
    expect(table.owners("User", "username")).to eq ["accounts"]
    expect(table.field("User", "username").external).to eq ["reviews"]
  end

  # the composer omits @join__field when it has nothing to say, and that
  # omission means "wherever the type lives"
  it "falls back to the type's subgraphs for a field with no @join__field" do
    expect(table.field("Product", "upc")).to be_nil
    expect(table.owners("Product", "upc")).to eq %w[products reviews]
  end

  it "reads @requires and @provides field sets" do
    expect(table.field("Product", "shippingEstimate").requires).to eq "price weight"
    expect(table.field("Review", "author").provides).to eq "username"
  end

  it "reads the @key field sets a subgraph answers on" do
    expect(table.keys("User", "accounts")).to eq [["id"]]
    expect(table.keys("Product", "reviews")).to eq [["upc"]]
    expect(table.keys("Review", "accounts")).to be_empty
    expect(table.declared_in("User")).to eq %w[accounts reviews]
    expect(table.entity?("Review")).to be true
    expect(table.entity?("Announcement")).to be false
  end

  it "knows nothing about a type or field the supergraph never mentions" do
    expect(table.owners("Nope", "nope")).to be_empty
    expect(table.field("Query", "nope")).to be_nil
  end

  # owners answers "who resolves this"; declares? answers "is it here at
  # all" — and a field with no @join__field is still a field
  it "lists every field a type declares, routed or not" do
    expect(table.fields("Product")).to eq %w[name price weight reviews shippingEstimate]
    expect(table.declared_fields("Product"))
      .to eq %w[name price upc weight reviews shippingEstimate]
    expect(table.declared_fields("Nope")).to be_empty
  end

  it "says whether the supergraph carries a coordinate at all" do
    expect(table.declares?("Product")).to be true
    expect(table.declares?("Product", "upc")).to be true
    expect(table.declares?("Product", "dimensions")).to be false
    expect(table.declares?("Nope")).to be false
  end

  it "names who is responsible for a coordinate, falling back to the type" do
    expect(table.responsible("Product", "shippingEstimate")).to eq ["reviews"]
    # a field the supergraph doesn't carry — the case an error message is
    # usually asking about: whoever declares the type is still who to talk to
    expect(table.responsible("Product", "dimensions")).to eq %w[products reviews]
    expect(table.responsible("Nope", "nope")).to be_empty
  end

  # ---- the shapes a hand-built supergraph can carry --------------------

  def supergraph(body, join: <<~JOIN)
    directive @join__field(graph: join__Graph, requires: join__FieldSet, provides: join__FieldSet, type: String, external: Boolean, override: String, usedOverridden: Boolean) repeatable on FIELD_DEFINITION
    directive @join__graph(name: String!, url: String!) on ENUM_VALUE
    directive @join__type(graph: join__Graph!, key: join__FieldSet, extension: Boolean! = false, resolvable: Boolean! = true, isInterfaceObject: Boolean! = false) repeatable on OBJECT | INTERFACE
    scalar join__FieldSet
  JOIN
    GraphWeaver::SchemaLoader.routing_table(<<~SDL)
      #{join}
      enum join__Graph {
        A @join__graph(name: "a", url: "http://a")
        B @join__graph(name: "b", url: "http://b")
      }
      #{body}
    SDL
  end

  it "flattens a nested @key field set to dotted paths" do
    built = supergraph(<<~SDL)
      type Query @join__type(graph: A) { listing: Listing @join__field(graph: A) }
      type Listing @join__type(graph: A, key: "id organization { id }") {
        id: ID!
        organization: Org!
      }
      type Org @join__type(graph: A) { id: ID! }
    SDL

    expect(built.keys("Listing", "a")).to eq [["id", "organization.id"]]
  end

  it "skips a key the subgraph declares but does not resolve" do
    built = supergraph(<<~SDL)
      type Query @join__type(graph: A) { thing: Thing @join__field(graph: A) }
      type Thing @join__type(graph: A, key: "id") @join__type(graph: B, key: "id", resolvable: false) {
        id: ID!
        name: String @join__field(graph: A)
      }
    SDL

    expect(built.declared_in("Thing")).to eq %w[a b]
    expect(built.keys("Thing", "a")).to eq [["id"]]
    expect(built.keys("Thing", "b")).to be_empty
  end

  # the maintenance tail, bounded: a construct the table has not been taught
  # is reported, never skipped
  it "reports a @join__ directive it doesn't read" do
    built = supergraph(<<~SDL, join: <<~JOIN)
      type Query @join__type(graph: A) @join__directive(graphs: [A], name: "cacheControl") {
        hi: String @join__field(graph: A)
      }
    SDL
      directive @join__directive(graphs: [join__Graph!], name: String!) repeatable on SCHEMA | OBJECT | FIELD_DEFINITION
      directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT
    JOIN

    expect(built.unsupported).to contain_exactly(/Query applies @join__directive/)
  end

  it "reports an @interfaceObject it cannot attribute field by field" do
    built = supergraph(<<~SDL)
      type Query @join__type(graph: A) { media: Media @join__field(graph: A) }
      type Media @join__type(graph: A, key: "id") @join__type(graph: B, key: "id", isInterfaceObject: true) {
        id: ID!
        rating: Float @join__field(graph: B)
      }
    SDL

    expect(built.unsupported).to contain_exactly(/Media is an @interfaceObject/)
  end

  it "refuses a schema that carries no routing table" do
    expect { GraphWeaver::SchemaLoader.routing_table("type Query { hi: String }") }
      .to raise_error(GraphWeaver::Error, /no routing table here/)
    expect { GraphWeaver::SchemaLoader.routing_table({ "data" => {} }) }
      .to raise_error(GraphWeaver::Error, /introspection result carries no routing table/)
  end
end
