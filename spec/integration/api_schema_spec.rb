# typed: ignore — harness plumbing
require "json"
require "open3"

# Weaver derives the API schema from a supergraph itself — stripping the
# join/link machinery and subtracting @inaccessible — rather than shelling out
# to Apollo's JS tooling. This is the check that the derivation is the same
# one: compose real supergraphs with @apollo/composition, then diff weaver's
# result against Apollo's own toAPISchema().
#
# Needs node + the harness deps (npm install in spec/support/federation, run
# automatically on first use). Part of `make integration`.
describe "API schema parity with Apollo composition", :integration do
  COMPOSE_HARNESS = File.expand_path("../support/federation", __dir__)

  before(:all) do
    unless Dir.exist?(File.join(COMPOSE_HARNESS, "node_modules"))
      system("npm", "install", "--silent", chdir: COMPOSE_HARNESS, exception: true)
    end
  end

  # [supergraph SDL, Apollo's API schema SDL] for a set of subgraphs
  def compose(subgraphs)
    input = JSON.generate(subgraphs.map { |name, sdl| { name:, sdl: } })
    out, err, status = Open3.capture3("node", "compose.mjs", stdin_data: input, chdir: COMPOSE_HARNESS)
    raise "composition failed: #{err}" unless status.success?

    JSON.parse(out).values_at("supergraph", "apiSchema")
  end

  # Both sides printed by graphql-ruby, so the diff is about the schema
  # rather than about two printers disagreeing on whitespace and ordering.
  def parity(subgraphs, contains:)
    supergraph, api_schema = compose(subgraphs)
    contains.each { |marker| expect(supergraph).to include(marker) }

    weaver = GraphWeaver::SchemaLoader.load(supergraph)
    apollo = GraphQL::Schema.from_definition(api_schema)
    expect(weaver.to_definition).to eq apollo.to_definition
  end

  # a shared entity, plus @inaccessible imported under a local name — the
  # rename weaver reads off the @link rather than assuming
  it "matches on an aliased @inaccessible" do
    parity(
      {
        "users" => <<~SDL,
          extend schema @link(url: "https://specs.apollo.dev/federation/v2.5",
            import: ["@key", "@shareable", { name: "@inaccessible", as: "@private" }])
          type Query { user(id: ID!): User }
          type User @key(fields: "id") { id: ID! name: String! ssn: String @private }
        SDL
        "pets" => <<~SDL,
          extend schema @link(url: "https://specs.apollo.dev/federation/v2.5", import: ["@key"])
          type Query { petCount: Int! }
          type User @key(fields: "id") { id: ID! petNames: [String!]! }
        SDL
      },
      contains: ["@join__type", "@inaccessible"],
    )
  end

  it "matches on @interfaceObject" do
    parity(
      {
        "media" => <<~SDL,
          extend schema @link(url: "https://specs.apollo.dev/federation/v2.3", import: ["@key"])
          type Query { media(id: ID!): Media }
          interface Media @key(fields: "id") { id: ID! title: String! }
          type Book implements Media @key(fields: "id") { id: ID! title: String! isbn: String! }
          type Film implements Media @key(fields: "id") { id: ID! title: String! minutes: Int! }
        SDL
        "reviews" => <<~SDL,
          extend schema @link(url: "https://specs.apollo.dev/federation/v2.3",
            import: ["@key", "@interfaceObject"])
          type Query { hottest: Media }
          type Media @key(fields: "id") @interfaceObject { id: ID! rating: Float! }
        SDL
      },
      contains: ["isInterfaceObject: true"],
    )
  end

  # the two join directives that don't sit on a type or a field
  it "matches on @join__unionMember and @join__enumValue" do
    parity(
      {
        "posts" => <<~SDL,
          extend schema @link(url: "https://specs.apollo.dev/federation/v2.5",
            import: ["@key", "@shareable", "@inaccessible"])
          type Query { feed: [FeedItem!]! status: Status! }
          union FeedItem = Post | Secret
          type Post @shareable { id: ID! title: String! }
          type Secret @inaccessible { id: ID! }
          enum Status { OPEN CLOSED HIDDEN @inaccessible }
        SDL
        "photos" => <<~SDL,
          extend schema @link(url: "https://specs.apollo.dev/federation/v2.5",
            import: ["@key", "@shareable", "@inaccessible"])
          type Query { gallery: [FeedItem!]! archived: Status! }
          union FeedItem = Post | Photo
          type Post @shareable { id: ID! title: String! }
          type Photo { id: ID! url: String! }
          enum Status { OPEN CLOSED HIDDEN @inaccessible }
        SDL
      },
      contains: ["@join__unionMember", "@join__enumValue"],
    )
  end
end
