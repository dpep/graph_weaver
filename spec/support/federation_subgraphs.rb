# typed: ignore — graphql-ruby class DSL
# frozen_string_literal: true

require "apollo-federation"

# Two real Apollo Federation subgraphs (the apollo-federation gem wires
# _service { sdl } and _entities): USERS owns User, PETS extends it with
# petNames via entity resolution — so a query touching both fields forces
# the router to plan across subgraphs.
module FederationDemo
  class BaseField < GraphQL::Schema::Field
    include ApolloFederation::Field
  end

  class BaseObject < GraphQL::Schema::Object
    include ApolloFederation::Object
    field_class BaseField
  end

  PEOPLE = { "1" => "Daniel" }.freeze
  PETS = { "1" => %w[Shelby Brownie] }.freeze

  module Users
    class User < BaseObject
      graphql_name "User"
      key fields: :id

      field :id, ID, null: false
      field :name, String, null: false

      def self.resolve_reference(reference, _context)
        id = reference[:id] || reference["id"]
        { id:, name: PEOPLE.fetch(id.to_s) }
      end
    end

    class Query < BaseObject
      graphql_name "Query"

      field :user, User, null: true do
        argument :id, ID, required: true
      end

      def user(id:)
        name = PEOPLE[id.to_s]
        name && { id:, name: }
      end
    end

    class Schema < GraphQL::Schema
      include ApolloFederation::Schema
      query Query
    end
  end

  module Pets
    class User < BaseObject
      graphql_name "User"
      extend_type
      key fields: :id

      field :id, ID, null: false, external: true
      field :pet_names, [String], null: false

      def pet_names
        id = object[:id] || object["id"]
        PETS.fetch(id.to_s, [])
      end

      def self.resolve_reference(reference, _context)
        reference
      end
    end

    class Query < BaseObject
      graphql_name "Query"

      field :pet_count, Integer, null: false

      def pet_count
        PETS.values.sum(&:size)
      end

      # graphql-ruby 2.6 drops orphan_types from the printed SDL, so the
      # extended User must be reachable from a root field for the
      # subgraph to advertise it — realistic anyway (owners-by-pets)
      field :pet_owners, [User], null: false

      def pet_owners
        PETS.keys.map { |id| { id: } }
      end
    end

    class Schema < GraphQL::Schema
      include ApolloFederation::Schema
      query Query
    end
  end
end
