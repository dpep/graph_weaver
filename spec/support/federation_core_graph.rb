# typed: ignore — graphql-ruby class DSL
# frozen_string_literal: true

# The shape a large monolith hits: a foundational subgraph every other one
# extends, and more than one loaded schema class that satisfies it. Detection
# can't say which serves "core" — but almost no query reaches a field core
# *owns*, so refusing at construction would refuse a whole suite over one
# subgraph it never touches.
module CoreGraph
  SUPERGRAPH = <<~SDL
    schema @link(url: "https://specs.apollo.dev/link/v1.0")
      @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
    { query: Query }
    directive @join__field(graph: join__Graph, external: Boolean) repeatable on FIELD_DEFINITION
    directive @join__graph(name: String!, url: String!) on ENUM_VALUE
    directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT
    scalar join__FieldSet
    enum join__Graph {
      CORE @join__graph(name: "core", url: "http://core")
      CATALOG @join__graph(name: "catalog", url: "http://catalog")
    }
    type Query @join__type(graph: CORE) @join__type(graph: CATALOG) {
      health: String! @join__field(graph: CORE)
      items: [Item!]! @join__field(graph: CATALOG)
    }
    type Item @join__type(graph: CORE, key: "id") @join__type(graph: CATALOG, key: "id") {
      id: ID! @join__field(graph: CORE) @join__field(graph: CATALOG, external: true)
      audit: String! @join__field(graph: CORE)
      name: String! @join__field(graph: CATALOG)
    }
  SDL

  class Item < GraphQL::Schema::Object
    graphql_name "Item"
    field :id, ID, null: false
    field :audit, String, null: false
    def audit = "audited"
  end

  # everything the supergraph says "core" resolves, and nothing catalog does
  class CoreQuery < GraphQL::Schema::Object
    graphql_name "Query"
    field :health, String, null: false
    def health = "ok"
  end

  class Schema < GraphQL::Schema
    query CoreQuery
    orphan_types Item
    def self.resolve_type(_type, _object, _context) = Item
  end

  # A second class fitting "core" exactly as well — a shared base extracted
  # into an engine, a subclass with one override, a legacy alias still loaded.
  class Twin < GraphQL::Schema
    query CoreQuery
    orphan_types Item
    def self.resolve_type(_type, _object, _context) = Item
  end

  module Catalog
    class Item < GraphQL::Schema::Object
      graphql_name "Item"
      field :id, ID, null: false
      field :name, String, null: false
    end

    class Query < GraphQL::Schema::Object
      graphql_name "Query"
      field :items, [Item], null: false
      def items = [{ id: "i1", name: "Table" }]
    end

    class Schema < GraphQL::Schema
      query Query
      def self.resolve_type(_type, _object, _context) = Item
    end
  end
end
