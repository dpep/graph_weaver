# typed: ignore — graphql-ruby class DSL
# frozen_string_literal: true

require "apollo-federation"

# The canonical Apollo demo graph, as three real federation subgraphs:
#
#   accounts  owns User
#   products  owns Product
#   reviews   owns Review, extends User (reviews) and Product (reviews,
#             shippingEstimate @requires "price weight")
#
# Bigger than FederationDemo's users/pets pair on purpose — it carries the
# shapes a router actually has to think about (@requires, @provides, an
# entity reached from two directions, a union inside one subgraph), so the
# local router's boundary can be tested where it really falls.
#
# spec/support/federation/supergraph.graphql is these three composed by
# Apollo; spec/integration/router_spec.rb re-composes and fails if it drifts.
module RouterGraph
  SUPERGRAPH = File.expand_path("federation/supergraph.graphql", __dir__)

  class BaseField < GraphQL::Schema::Field
    include ApolloFederation::Field
  end

  class BaseObject < GraphQL::Schema::Object
    include ApolloFederation::Object
    field_class BaseField
  end

  USERS = {
    "1" => { id: "1", username: "dpep", email: "pepper.daniel@gmail.com" },
    "2" => { id: "2", username: "ada", email: "ada@example.com" },
  }.freeze

  PRODUCTS = {
    "p1" => { upc: "p1", name: "Table", price: 899, weight: 100 },
    "p2" => { upc: "p2", name: "Couch", price: 1299, weight: 900 },
    "p3" => { upc: "p3", name: "Chair", price: 54, weight: 50 },
    # OVERWEIGHT: shippingEstimate raises on it, so a stitched fetch can put a
    # null where the composed schema says Int! and null propagation has
    # something to do
    "p4" => { upc: "p4", name: "Piano", price: 4200, weight: OVERWEIGHT = 1000 },
  }.freeze

  REVIEWS = [
    { id: "r1", body: "Love it", author_id: "1", upc: "p1" },
    { id: "r2", body: "Too expensive", author_id: "1", upc: "p2" },
    { id: "r3", body: "Could be better", author_id: "2", upc: "p3" },
  ].freeze

  # a review pointing at a product no subgraph can resolve: the entity fetch
  # comes back null where Review.product says Product!
  ORPHAN_REVIEWS = [{ id: "r9", body: "Vanished product", author_id: "1", upc: "gone" }].freeze

  module Accounts
    class User < RouterGraph::BaseObject
      graphql_name "User"
      key fields: :id

      field :id, ID, null: false
      field :username, String, null: false
      field :email, String, null: false

      def self.resolve_reference(reference, _context)
        USERS[(reference[:id] || reference["id"]).to_s]
      end
    end

    class Query < RouterGraph::BaseObject
      graphql_name "Query"

      field :me, User, null: true
      field :user, User, null: true do
        argument :id, ID, required: true
      end
      field :users, [User], null: false

      # context is the whole reason a test router takes one
      def me = USERS[(context[:current_user_id] || "1").to_s]
      def user(id:) = USERS[id.to_s]
      def users = USERS.values
    end

    class Schema < GraphQL::Schema
      include ApolloFederation::Schema
      query Query
    end
  end

  module Products
    class Product < RouterGraph::BaseObject
      graphql_name "Product"
      key fields: :upc

      field :upc, String, null: false
      field :name, String, null: false
      field :price, Integer, null: false
      field :weight, Integer, null: false

      def self.resolve_reference(reference, _context)
        PRODUCTS[(reference[:upc] || reference["upc"]).to_s]
      end
    end

    class Query < RouterGraph::BaseObject
      graphql_name "Query"

      field :top_products, [Product], null: false do
        argument :first, Integer, required: false, default_value: 3
      end
      field :product, Product, null: true do
        argument :upc, String, required: true
      end

      def top_products(first:) = PRODUCTS.values.first(first)
      def product(upc:) = PRODUCTS[upc.to_s]
    end

    class Schema < GraphQL::Schema
      include ApolloFederation::Schema
      query Query
    end
  end

  module Reviews
    class User < RouterGraph::BaseObject
      graphql_name "User"
      extend_type
      key fields: :id

      field :id, ID, null: false, external: true
      # accounts owns username; reviews declares it @external so Review.author
      # can @provide the copy it already has
      field :username, String, null: false, external: true
      field :reviews, ["RouterGraph::Reviews::Review"], null: false

      def reviews
        id = (object[:id] || object["id"]).to_s
        REVIEWS.select { |review| review[:author_id] == id }
      end

      def self.resolve_reference(reference, _context) = reference
    end

    class Product < RouterGraph::BaseObject
      graphql_name "Product"
      extend_type
      key fields: :upc

      field :upc, String, null: false, external: true
      field :price, Integer, null: false, external: true
      field :weight, Integer, null: false, external: true

      field :reviews, ["RouterGraph::Reviews::Review"], null: false
      field :shipping_estimate, Integer, null: false, requires: { fields: "price weight" }

      def reviews
        upc = (object[:upc] || object["upc"]).to_s
        REVIEWS.select { |review| review[:upc] == upc }
      end

      def shipping_estimate
        weight = object[:weight] || object["weight"]
        raise GraphQL::ExecutionError, "carrier unavailable" if weight == OVERWEIGHT

        (weight * 0.5).round
      end

      def self.resolve_reference(reference, _context) = reference
    end

    class Review < RouterGraph::BaseObject
      graphql_name "Review"
      key fields: :id

      field :id, ID, null: false
      field :body, String, null: false
      # @provides: reviews carries its own copy of the author's username, so a
      # query asking only for that never leaves this subgraph
      field :author, User, null: false, provides: { fields: "username" }
      field :product, Product, null: false

      def author = { id: object[:author_id], username: USERS.fetch(object[:author_id])[:username] }
      def product = { upc: object[:upc] }

      def self.resolve_reference(reference, _context)
        REVIEWS.find { |review| review[:id] == (reference[:id] || reference["id"]).to_s }
      end
    end

    class Announcement < RouterGraph::BaseObject
      graphql_name "Announcement"

      field :headline, String, null: false
    end

    # a union entirely inside ONE subgraph — nothing crosses a boundary, so
    # there is nothing here for a router to refuse
    class FeedItem < GraphQL::Schema::Union
      graphql_name "FeedItem"
      possible_types Review, Announcement

      def self.resolve_type(object, _context)
        object.key?(:headline) ? Announcement : Review
      end
    end

    class Query < RouterGraph::BaseObject
      graphql_name "Query"

      field :feed, [FeedItem], null: false
      field :reviews, [Review], null: false
      field :orphan_reviews, [Review], null: false
      field :review, Review, null: true do
        argument :id, ID, required: true
      end

      def feed = [REVIEWS.first, { headline: "New in stock" }]
      def reviews = REVIEWS
      def orphan_reviews = ORPHAN_REVIEWS
      def review(id:) = REVIEWS.find { |r| r[:id] == id.to_s }
    end

    class Schema < GraphQL::Schema
      include ApolloFederation::Schema
      query Query
      orphan_types User, Product
    end
  end

  SUBGRAPHS = {
    "accounts" => Accounts::Schema,
    "products" => Products::Schema,
    "reviews" => Reviews::Schema,
  }.freeze

  # The same accounts and reviews subgraphs composed with two — SHIPPING and
  # BILLING — that no Ruby schema in this process serves: the shape of a
  # migration, where part of the supergraph is already routed to another
  # service. Query and Review both reach into SHIPPING, so a query can avoid
  # it entirely, need it at a root field, or cross a boundary into it; BILLING
  # is the second one, so faking one and refusing the other is testable.
  #
  # Hand-written rather than composed: there is no subgraph to compose from,
  # which is the whole point. Only what Accounts::Schema and Reviews::Schema
  # really define is attributed to them, so detection still matches both.
  PARTIAL_SUPERGRAPH = <<~SDL
    schema @link(url: "https://specs.apollo.dev/link/v1.0")
      @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
    { query: Query }
    directive @join__field(graph: join__Graph, requires: join__FieldSet,
      provides: join__FieldSet, external: Boolean) repeatable on FIELD_DEFINITION
    directive @join__graph(name: String!, url: String!) on ENUM_VALUE
    directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT
    scalar join__FieldSet
    enum join__Graph {
      ACCOUNTS @join__graph(name: "accounts", url: "http://accounts")
      REVIEWS @join__graph(name: "reviews", url: "http://reviews")
      SHIPPING @join__graph(name: "shipping", url: "http://shipping")
      BILLING @join__graph(name: "billing", url: "http://billing")
    }
    type Query @join__type(graph: ACCOUNTS) @join__type(graph: REVIEWS)
      @join__type(graph: SHIPPING) @join__type(graph: BILLING) {
      me: User @join__field(graph: ACCOUNTS)
      reviews: [Review!]! @join__field(graph: REVIEWS)
      shipments: [Shipment!]! @join__field(graph: SHIPPING)
      invoices: [Invoice!]! @join__field(graph: BILLING)
    }
    type User @join__type(graph: ACCOUNTS, key: "id") @join__type(graph: REVIEWS, key: "id") {
      id: ID! @join__field(graph: ACCOUNTS) @join__field(graph: REVIEWS, external: true)
      username: String! @join__field(graph: ACCOUNTS)
      email: String! @join__field(graph: ACCOUNTS)
      reviews: [Review!]! @join__field(graph: REVIEWS)
    }
    type Review @join__type(graph: REVIEWS, key: "id") @join__type(graph: SHIPPING, key: "id") {
      id: ID! @join__field(graph: REVIEWS) @join__field(graph: SHIPPING, external: true)
      body: String! @join__field(graph: REVIEWS)
      shipment: Shipment @join__field(graph: SHIPPING)
    }
    type Shipment @join__type(graph: SHIPPING) {
      id: ID! @join__field(graph: SHIPPING)
      carrier: String! @join__field(graph: SHIPPING)
    }
    type Invoice @join__type(graph: BILLING) {
      id: ID! @join__field(graph: BILLING)
      total: Int! @join__field(graph: BILLING)
    }
  SDL
end
