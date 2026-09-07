# typed: ignore
# A 3-subgraph chain, and the smallest graph that asks one question: what
# happens to a @requires whose field set names another @requires field?
# a.w -> b.mid @requires "w" -> c.top @requires "mid". Every field set here is
# flat, so this is not the nested_field_set case.
require "graphql"
require "apollo-federation"

module Chain
  class BaseField < GraphQL::Schema::Field
    include ApolloFederation::Field
  end
  class BaseObject < GraphQL::Schema::Object
    include ApolloFederation::Object
    field_class BaseField
  end

  def self.at(obj, *names)
    return nil if obj.nil?
    names.each { |n| [n, n.to_s, n.to_sym].each { |k| return obj[k] if obj.respond_to?(:key?) && obj.key?(k) } }
    nil
  end

  module A
    class Thing < Chain::BaseObject
      graphql_name "Thing"
      key fields: :id
      field :id, ID, null: false
      field :w, Integer, null: false
      def self.resolve_reference(reference, _ctx)
        id = Chain.at(reference, :id).to_s
        { id:, w: id == "bad" ? nil : 10 }
      end
    end
    class Query < Chain::BaseObject
      graphql_name "Query"
      field :thing, Thing, null: true do
        argument :id, ID, required: true
      end
      def thing(id:) = { id:, w: id.to_s == "bad" ? nil : 10 }
    end
    class Schema < GraphQL::Schema
      include ApolloFederation::Schema
      query Query
    end
  end

  module B
    class Thing < Chain::BaseObject
      graphql_name "Thing"
      key fields: :id
      field :id, ID, null: false
      field :w, Integer, null: false, external: true
      field :mid, Integer, null: false, requires: { fields: "w" }
      def mid = Chain.at(object, :w).to_i + 1
      def self.resolve_reference(reference, _ctx) = reference
    end
    class Query < Chain::BaseObject
      graphql_name "Query"
      field :b_ping, String, null: false
      def b_ping = "b"
    end
    class Schema < GraphQL::Schema
      include ApolloFederation::Schema
      orphan_types Thing
      query Query
    end
  end

  module C
    class Thing < Chain::BaseObject
      graphql_name "Thing"
      key fields: :id
      field :id, ID, null: false
      field :mid, Integer, null: false, external: true
      field :top, Integer, null: false, requires: { fields: "mid" }
      def top = Chain.at(object, :mid).to_i * 100
      def self.resolve_reference(reference, _ctx) = reference
    end
    class Query < Chain::BaseObject
      graphql_name "Query"
      field :c_ping, String, null: false
      def c_ping = "c"
    end
    class Schema < GraphQL::Schema
      include ApolloFederation::Schema
      orphan_types Thing
      query Query
    end
  end

  SUBGRAPHS = { "a" => A::Schema, "b" => B::Schema, "c" => C::Schema }.freeze
  SUPERGRAPH = File.expand_path("federation/supergraph_chain.graphql", __dir__)

  HEADER = <<~SDL
    extend schema
      @link(url: "https://specs.apollo.dev/federation/v2.5", import: [
        "@key", "@shareable", "@external", "@requires", "@provides", "@extends"
      ])

  SDL
  def self.sdl(schema) = HEADER + schema.federation_sdl
end
