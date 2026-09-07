# typed: true
# frozen_string_literal: true

require "graphql"

module GraphWeaver
  # The graphql-ruby schema classes already in this process, and what each
  # one defines. Where {SchemaLoader} *builds* a schema from a source — a
  # path, SDL, an introspection dump — this reads classes the app loaded
  # itself.
  #
  # Two features ask exactly these two questions, and match a schema on the
  # coordinates it defines rather than on its class name: {Testing::Subgraphs}
  # (which schema serves which subgraph) and {Federation::Drift} (has a
  # subgraph changed without a recompose). They share the answers so the two
  # can't drift apart.
  module Schemas
    class << self
      # Every named GraphQL::Schema in the process. An anonymous one is
      # graphql-ruby building from SDL — the router's own view of the
      # supergraph is one — and never an app's subgraph.
      def loaded
        descendants(GraphQL::Schema).select(&:name)
      end

      # Does this schema carry the coordinate — "Type", or "Type.field"?
      def defines?(schema, coordinate)
        type_name, field_name = coordinate.split(".", 2)
        type = schema.get_type(type_name) or return false
        return true unless field_name

        return type.fields.key?(field_name) if type.respond_to?(:fields)
        # an input object's members are arguments, not fields
        return type.arguments.key?(field_name) if type.respond_to?(:arguments)

        false
      end

      private

      def descendants(klass)
        klass.subclasses.flat_map { |subclass| [subclass] + descendants(subclass) }
      end
    end
  end
end
