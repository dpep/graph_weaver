# typed: true
# frozen_string_literal: true

require "graphql"

require_relative "fake_client"

module GraphWeaver
  module Testing
    # A subgraph this process doesn't serve, answered with fabricated data.
    #
    # Composed into the supergraph but routed to another service, a subgraph
    # has no schema class here, so by default {Router} refuses any query that
    # reaches its fields. `subgraphs: { "reviews" => :fake }` swaps that
    # refusal for schema-correct fabricated data — mid-migration that's often
    # what you want: the fields exist, the shapes are right, and nothing has
    # to be stood up to exercise the rest of the graph.
    #
    # It satisfies the same contract every other subgraph does, including the
    # `_entities(representations:)` fetch a boundary crossing sends. Each
    # representation names its own `__typename`, so the entity comes back as
    # that type — a `_Entity` union faked the ordinary way would answer as a
    # random member and match nothing the query asked for.
    #
    # Fabricated data is invented data, and a green test against invented
    # data is worse than a red one — so {Router} marks every fetch that came
    # from here (`faked: true` in #trace) and logs it at :warn.
    class FakeSubgraph
      # the subgraph being faked, as the supergraph names it
      attr_reader :name

      # the schema responses are fabricated against — the composed API
      # schema, which carries every type this subgraph can be asked for
      attr_reader :schema

      def initialize(name, schema, **options)
        @name = name
        @schema = schema
        @client = FakeClient.new(schema:, **options)
      end

      def inspect = "#<#{self.class.name} #{@name.inspect}>"
      alias to_s inspect

      # context: is accepted for contract parity and ignored — there are no
      # resolvers here to receive one.
      def execute(query, variables: {}, operation_name: nil, context: nil)
        document = GraphQL.parse(query)
        operation = document.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).first
        entities = entities_field(operation)
        return @client.execute(query, variables:, operation_name:) unless entities

        { "data" => { "_entities" => entities_value(entities, document, operation, variables) } }
      end

      private

      # the router sends _entities as the operation's only root field
      def entities_field(operation)
        operation&.selections&.find do |node|
          node.is_a?(GraphQL::Language::Nodes::Field) && node.name == "_entities"
        end
      end

      # one object per representation, in order and as the type it names —
      # which is the contract _entities answers on
      def entities_value(field, document, operation, variables)
        fragments = document.definitions
          .grep(GraphQL::Language::Nodes::FragmentDefinition).to_h { |node| [node.name, node] }

        representations(variables).map do |representation|
          type_name = representation["__typename"] or raise GraphWeaver::Error,
            "a representation sent to #{@name} carries no __typename: #{representation.inspect}"

          @client.object(type_name, field.selections, fragments:, variables:, operation:)
        end
      end

      def representations(variables)
        found = variables.to_h.transform_keys(&:to_s)["representations"]
        (found || []).map { |representation| representation.to_h.transform_keys(&:to_s) }
      end
    end
  end
end
