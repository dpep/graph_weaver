# typed: ignore
# frozen_string_literal: true

# The smallest graph that carries a federation 2.8 `@context`/`@fromContext`,
# and the smallest query that makes it matter: `Store` sets the context,
# `Store.products` resolves in the OTHER subgraph, so reaching
# `Product.price` means an entity fetch back into catalog — and the argument
# `@fromContext` fills has to ride along in it. Apollo composes this happily;
# only the gateway knows what to put in the argument.
#
# `apollo-federation` (Ruby) has no `@context`, so these are SDL rather than
# schema classes. Recompose after editing them:
#
#     node compose.mjs < input.json   # in spec/support/federation
module ContextGraph
  SUPERGRAPH = File.expand_path("federation/supergraph_context.graphql", __dir__)

  CATALOG = <<~SDL
    extend schema @link(url: "https://specs.apollo.dev/federation/v2.8",
      import: ["@key", "@context", "@fromContext"])

    type Query { store(id: ID!): Store }

    type Store @key(fields: "id") @context(name: "storeCtx") {
      id: ID!
      country: String!
    }

    type Product @key(fields: "id") {
      id: ID!
      price(currency: String @fromContext(field: "$storeCtx { country }")): Float!
    }
  SDL

  REVIEWS = <<~SDL
    extend schema @link(url: "https://specs.apollo.dev/federation/v2.8", import: ["@key"])

    type Query { reviews: [String!]! }

    type Store @key(fields: "id") { id: ID! products: [Product!]! }

    type Product @key(fields: "id") { id: ID! }
  SDL
end
