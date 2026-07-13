# typed: true
# frozen_string_literal: true

require "graphql"

module GraphWeaver
  # Shared query-selection walking — the rules Codegen, FakeExecutor, and
  # the cassette Anonymizer all follow, in one place so they can't drift:
  # how fragments flatten into selections, and when a type condition
  # applies. Hosts set @schema and call load_operation before walking.
  module Selection
    include Kernel # for sorbet: hosts are Objects

    # Parse a query, stash its fragment definitions for the walk, and
    # return the operation.
    def load_operation(query)
      doc = GraphQL.parse(query)
      @fragments = doc.definitions
        .grep(GraphQL::Language::Nodes::FragmentDefinition)
        .to_h { |fragment| [fragment.name, fragment] }

      doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).first
    end

    # The schema type an operation's selections start from.
    def operation_root_type(operation)
      case operation&.operation_type
      when "query", nil then @schema.query
      when "mutation" then @schema.mutation
      else raise GraphWeaver::Error, "unsupported operation: #{operation.operation_type}"
      end
    end

    # Flatten a selection set as seen by `type`, yielding (result_key,
    # field_node) per field: plain fields yield directly; inline fragments
    # and named spreads recurse when their type condition applies.
    def each_field(type, selections, &block)
      selections.each do |selection|
        case selection
        when GraphQL::Language::Nodes::Field
          yield(selection.alias || selection.name, selection)
        when GraphQL::Language::Nodes::InlineFragment
          each_field(type, selection.selections, &block) if applies?(selection.type&.name, type)
        when GraphQL::Language::Nodes::FragmentSpread
          fragment = @fragments.fetch(selection.name) do
            raise ArgumentError, "unknown fragment: #{selection.name}"
          end
          each_field(type, fragment.selections, &block) if applies?(fragment.type.name, type)
        else
          raise GraphWeaver::Error, "unsupported selection: #{selection.class}"
        end
      end
    end

    # A fragment's type condition applies when it names this type exactly,
    # or an interface/union this type belongs to (`... on Named { ... }`).
    def applies?(condition, type)
      return true if condition.nil? || condition == type.graphql_name

      condition_type = @schema.get_type(condition)
      return false unless condition_type

      kind = condition_type.kind.name
      (kind == "INTERFACE" || kind == "UNION") &&
        @schema.possible_types(condition_type).include?(type)
    end
  end
end
