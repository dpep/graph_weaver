# typed: ignore — schemas built from SDL, invisible to srb
# frozen_string_literal: true

require "graphql"

# A two-subgraph graph and three versions of one subgraph's schema — the
# same code before and after someone changed it without recomposing. Type
# names are unique to this fixture so these schemas can never be mistaken
# for another graph's subgraph by the process-wide detection.
module DriftGraph
  SUPERGRAPH = <<~SDL
    schema @link(url: "https://specs.apollo.dev/link/v1.0")
      @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
    { query: Query }
    directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
    directive @join__graph(name: String!, url: String!) on ENUM_VALUE
    directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT
    scalar join__FieldSet
    enum join__Graph {
      WIDGETS @join__graph(name: "widgets", url: "http://widgets")
      DEPOTS @join__graph(name: "depots", url: "http://depots")
    }
    type Query @join__type(graph: WIDGETS) @join__type(graph: DEPOTS) {
      widget(sku: String!): Widget @join__field(graph: WIDGETS)
      depot(id: ID!): Depot @join__field(graph: DEPOTS)
    }
    type Widget @join__type(graph: WIDGETS, key: "sku") {
      sku: String!
      name: String! @join__field(graph: WIDGETS)
      weight: Int! @join__field(graph: WIDGETS)
    }
    type Depot @join__type(graph: DEPOTS, key: "id") {
      id: ID!
      location: String! @join__field(graph: DEPOTS)
    }
  SDL

  # const_set names the anonymous class from_definition returns, which is
  # what detection and the drift report print
  def self.schema(name, sdl) = const_set(name, GraphQL::Schema.from_definition(sdl))

  schema :Widgets, <<~SDL
    type Query { widget(sku: String!): Widget }
    type Widget { sku: String! name: String! weight: Int! }
  SDL

  # the field the supergraph still promises is gone
  schema :WidgetsStale, <<~SDL
    type Query { widget(sku: String!): Widget }
    type Widget { sku: String! name: String! }
  SDL

  # the key field, which the supergraph routes to nobody in particular
  schema :WidgetsUnkeyed, <<~SDL
    type Query { widget(sku: String!): Widget }
    type Widget { name: String! weight: Int! }
  SDL

  # a field that hasn't been composed in yet
  schema :WidgetsAhead, <<~SDL
    type Query { widget(sku: String!): Widget }
    type Widget { sku: String! name: String! weight: Int! dimensions: String }
  SDL

  schema :Depots, <<~SDL
    type Query { depot(id: ID!): Depot }
    type Depot { id: ID! location: String! }
  SDL
end
