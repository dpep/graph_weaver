# typed: true
# frozen_string_literal: true

require "graphql"

module GraphWeaver
  # Shared query-selection walking — the rules Codegen, FakeClient, and
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

      operations = doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition)
      # One file, one operation. Requests do carry operationName now, so a
      # second operation would run fine on the wire — what has no answer is
      # naming: a module is named after its FILE (person.graphql =>
      # PersonQuery), and one file can't name two. A convention, not a limit.
      if operations.size > 1
        names = operations.map { |op| op.name ? "'#{op.name}'" : "an anonymous operation" }
        raise GraphWeaver::Error,
          "document defines #{operations.size} operations (#{names.join(", ")}) — " \
          "split them into one file each, since a module is named after its file"
      end

      operations.first
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
    # field_node, conditional) per field: plain fields yield directly; inline
    # fragments and named spreads recurse when their type condition applies.
    # `conditional` is true when any fragment on the way down carried
    # @skip/@include — the whole block may be absent from the response, so
    # everything under it is as optional as a directly-skipped field.
    def each_field(type, selections, visiting = Set.new, conditional: false, &block)
      selections.each do |selection|
        case selection
        when GraphQL::Language::Nodes::Field
          yield(selection.alias || selection.name, selection, conditional)
        when GraphQL::Language::Nodes::InlineFragment
          next unless applies?(selection.type&.name, type)

          each_field(type, selection.selections, visiting,
            conditional: conditional || conditional?(selection), &block)
        when GraphQL::Language::Nodes::FragmentSpread
          fragment = @fragments.fetch(selection.name) do
            raise ArgumentError, "unknown fragment: #{selection.name}"
          end
          if visiting.include?(selection.name)
            raise GraphWeaver::Error, "fragment cycle through #{selection.name}"
          end

          if applies?(fragment.type.name, type)
            # the directive rides on the SPREAD, not the definition it names
            each_field(type, fragment.selections, visiting | [selection.name],
              conditional: conditional || conditional?(selection), &block)
          end
        else
          raise GraphWeaver::Error, "unsupported selection: #{selection.class}"
        end
      end
    end

    # each_field grouped by result key: repeated selections of one field
    # (`a { x } a { y }`, or the same field reached through two fragments)
    # collect together, so callers MERGE their sub-selections rather than
    # last-writer-wins. Codegen relies on this; FakeClient/Anonymizer must too,
    # or they'd fabricate/keep a shape the generated struct can't cast.
    def gather(type, selections)
      gather_conditional(type, selections).transform_values { |occurrences| occurrences.map(&:first) }
    end

    # gather, keeping each occurrence's [field_node, conditional] — the wire
    # key is guaranteed only when SOME occurrence is unconditional.
    def gather_conditional(type, selections)
      out = {}
      each_field(type, selections) { |key, node, conditional| (out[key] ||= []) << [node, conditional] }
      out
    end

    # Directives that can drop a selection from the response whatever the
    # schema says — the reason a conditional field's generated type is nilable.
    CONDITIONAL_DIRECTIVES = %w[skip include].freeze

    # Is this AST node (field, inline fragment, or spread) behind @skip/@include?
    def conditional?(node)
      node.directives.any? { |directive| CONDITIONAL_DIRECTIVES.include?(directive.name) }
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
