# typed: true
# frozen_string_literal: true

require "graphql"
require "json"

require_relative "../schema_loader"
require_relative "../transport"

module GraphWeaver
  module Testing
    # A query the local router will not plan. Every one of these is a query
    # a real router *would* answer — refusing is the whole design, because
    # the alternative is a test that passes against semantics production
    # doesn't have.
    #
    # A refusal is #detail (what stopped this query) plus the advice its
    # #category carries, so a pile of refusals aggregates by category and
    # still reads as one sentence each. `rake
    # graph_weaver:federation:coverage` is that pile, counted.
    class Unplannable < GraphWeaver::Error
      # every way the local router refuses: the label a report groups by, and
      # the next action the message ends with
      CATEGORIES = {
        crosses_subgraph: [
          "crosses a subgraph boundary",
          "the local router hands one query to one subgraph verbatim and doesn't stitch across a " \
            "boundary. Run this one against a real router.",
        ],
        root_fields_span: [
          "root fields span subgraphs",
          "the local router hands one query to one subgraph verbatim, so every field has to resolve " \
            "in the same one. Split it into one operation per subgraph, or run this one against a " \
            "real router.",
        ],
        requires: [
          "@requires needs a fetch chain",
          "the router fetches those first and hands them back, a chain the local router doesn't " \
            "plan. Run this one against a real router.",
        ],
        no_owner: [
          "the routing table names no subgraph",
          "nothing can route a field the supergraph doesn't place. Run this one against a real router.",
        ],
        mixed_introspection: [
          "introspection mixed with data",
          "the local router answers introspection from the composed API schema and data from one " \
            "subgraph, and can't merge the two. Split them into two operations.",
        ],
        ambiguous_operation: [
          "the document isn't one operation",
          "pass operation_name: naming one of them.",
        ],
        operation_type: [
          "not a query or a mutation",
          "the local router plans queries and mutations against the composed schema's roots. Run " \
            "this one against a real router.",
        ],
        undefined_fragment: [
          "a fragment the document never defines",
          "define it, or point the query at the file that does.",
        ],
        unsupported_federation: [
          "a federation construct the routing table doesn't read",
          "the routing table is incomplete, so every answer it gives about this supergraph would be " \
            "a guess. Run this graph's queries against a real router.",
        ],
        too_deep: [
          "nested deeper than the router walks",
          "run this one against a real router.",
        ],
      }.freeze

      attr_reader :category, :detail

      def initialize(detail, category:)
        @category = category
        @detail = detail
        super("#{detail} — #{CATEGORIES.fetch(category).last}")
      end

      # the short label a report groups this refusal under
      def label = CATEGORIES.fetch(category).first

      def to_h = super.merge("category" => category.to_s, "detail" => detail)
    end

    # A federation router for tests: it satisfies the client contract, so
    # `GraphWeaver.client = router` runs every generated module against your
    # real subgraph resolvers, in-process — no gateway, no node, no sockets.
    #
    #      GraphWeaver::Testing::Router.new(
    #        supergraph: Rails.root.join("supergraph.graphql"),
    #        subgraphs: { "accounts" => Accounts::Schema, "products" => Products::Schema },
    #        context: { current_user: user },
    #      )
    #
    # **It is not a router, and doesn't try to be.** It plans exactly one
    # shape: a query whose every field resolves in a single subgraph, passed
    # to that subgraph verbatim. Anything that crosses a subgraph boundary
    # raises {Unplannable} — before any subgraph runs, so a refusal can never
    # be a half-executed query. Apollo's planner is twenty thousand lines and
    # the interesting part is the stitching; a test double that approximates
    # it would let a test pass on an answer production disagrees with, which
    # is the most expensive thing this library can produce.
    #
    # Introspection is answered from the composed API schema — never from a
    # subgraph, which would reply with its own slice. That is the one split a
    # real router also makes.
    #
    # #trace records the fetch each execute made (subgraph, query, variables);
    # the same line goes to GraphWeaver.logger at :debug.
    class Router
      # the schema the router serves — the supergraph with its composition
      # machinery stripped, exactly what a real router exposes
      attr_reader :schema

      # who resolves what (GraphWeaver::SchemaLoader::RoutingTable)
      attr_reader :table

      # the context handed to every subgraph, and the fetches the last
      # execute made
      attr_reader :context, :trace

      def initialize(supergraph:, subgraphs:, context: {})
        source = supergraph.to_s # a path, or the SDL itself — Pathname included
        @schema = GraphWeaver::SchemaLoader.load(source)
        @table = GraphWeaver::SchemaLoader.routing_table(source)
        @context = context
        @trace = []
        @subgraphs = checked_subgraphs(subgraphs)
        @planner = Planner.new(table: @table, schema: @schema)

        return if @table.unsupported.empty?

        # refuse at construction, not per query: an unread @join__ construct
        # means the routing table is incomplete, and every answer it gives
        # about this supergraph is a guess
        raise Unplannable.new(
          "this supergraph uses federation constructs the local router doesn't read: " +
            @table.unsupported.join("; "),
          category: :unsupported_federation,
        )
      end

      def execute(query, variables: {}, operation_name: nil)
        @trace = []
        document = begin
          GraphQL.parse(query)
        rescue GraphQL::ParseError => e
          return { "data" => nil, "errors" => [graphql_error(e.message, "GRAPHQL_PARSE_FAILED")] }
        end

        # validate the way a router does, so a stale query fails as it fails
        # in production rather than somewhere inside the planner
        errors = @planner.validate(document)
        return { "data" => nil, "errors" => errors } if errors.any?

        plan = @planner.plan(document, operation_name:)
        return introspect(query, variables, plan.operation_name) if plan.introspection

        fetch(plan.subgraph, query, variables, plan.operation_name)
      end

      # never leak the context (tokens, current_user) through logs or errors
      def inspect = "#<#{self.class.name} subgraphs=#{@subgraphs.keys.inspect}>"
      alias to_s inspect

      private

      def checked_subgraphs(subgraphs)
        given = subgraphs.to_h { |name, schema| [name.to_s, schema] }
        missing = @table.subgraphs - given.keys
        unknown = given.keys - @table.subgraphs
        if missing.any? || unknown.any?
          raise ArgumentError,
            "subgraphs: must name every subgraph in the supergraph (#{@table.subgraphs.join(", ")})" \
            "#{" — missing #{missing.join(", ")}" if missing.any?}" \
            "#{" — unknown #{unknown.join(", ")}" if unknown.any?}"
        end

        given
      end

      # __schema / __type describe the COMPOSED graph; a subgraph would
      # answer with its own slice
      def introspect(query, variables, operation_name)
        @schema.execute(query, variables: variables.to_h, operation_name:).to_h
      end

      def fetch(name, query, variables, operation_name)
        @trace << { subgraph: name, query:, variables: variables.to_h }
        tag = GraphWeaver.logger && GraphWeaver::Transport.log_tag(operation_name)

        GraphWeaver.log(:debug) do
          "router -> #{name} #{tag} variables=#{JSON.generate(variables)}\n" \
            "#{GraphWeaver::Transport.truncate_for_log(query)}"
        end

        GraphWeaver.log_timed(:debug, "router -> #{name} #{tag} completed") do
          @subgraphs.fetch(name).execute(query, variables:, operation_name:, context: @context).to_h
        end
      end

      def graphql_error(message, code)
        { "message" => message, "extensions" => { "code" => code } }
      end

      # Decides which subgraph — if any — can answer a whole operation on its
      # own. Separate from the Router because deciding needs only the
      # supergraph: `rake graph_weaver:federation:coverage` measures how much
      # of a query set is plannable without any subgraph being runnable.
      class Planner
        # a plan is a subgraph name, or "answer this from the API schema"
        Plan = Struct.new(:subgraph, :operation_name, :introspection)

        # the fields a router answers itself rather than routing
        INTROSPECTION = %w[__schema __type].freeze

        # a fragment spread can't cycle (validation rejects that), so this is
        # only ever reached by a document validation didn't see
        MAX_DEPTH = 32

        def initialize(table:, schema:)
          @table = table
          @schema = schema
        end

        # the operation's validation errors, GraphQL-wire shaped
        def validate(document)
          @schema.validate(document).map do |error|
            { "message" => error.message, "extensions" => { "code" => "GRAPHQL_VALIDATION_FAILED" } }
          end
        end

        def plan(document, operation_name: nil)
          operation = pick_operation(document, operation_name)
          refuse(:operation_type, "this document is a subscription") if
            operation.operation_type == "subscription"

          fragments = document.definitions
            .grep(GraphQL::Language::Nodes::FragmentDefinition).to_h { |f| [f.name, f] }
          root = root_type_name(operation)
          selections = flatten(root, operation.selections, fragments)

          introspection, data = selections.partition { |node| INTROSPECTION.include?(node.name) }
          if introspection.any?
            if data.any? { |node| node.name != "__typename" }
              refuse :mixed_introspection,
                "this operation selects #{introspection.map(&:name).uniq.join(" and ")} " \
                "alongside data fields"
            end

            return Plan.new(nil, operation.name, true)
          end

          Plan.new(choose(root, operation.selections, fragments), operation.name, false)
        end

        private

        def pick_operation(document, name)
          operations = document.definitions.grep(GraphQL::Language::Nodes::OperationDefinition)
          named = operations.map { |op| op.name || "anonymous" }
          if name
            return operations.find { |op| op.name == name } || refuse(:ambiguous_operation,
              "the document defines no operation named #{name.inspect} (it has #{named.join(", ")})")
          end
          return operations.first if operations.one?

          refuse :ambiguous_operation, "the document holds #{operations.size} operations (#{named.join(", ")})"
        end

        def root_type_name(operation)
          root = (operation.operation_type == "mutation") ? @schema.mutation : @schema.query
          root&.graphql_name || refuse(:operation_type,
            "the composed schema has no #{operation.operation_type || "query"} root type")
        end

        # Which subgraph runs the whole operation. Root fields fix the
        # candidates: they're independent, so the ones they share are the only
        # subgraphs that could answer everything.
        def choose(root, selections, fragments)
          refusals = entry_candidates(root, selections, fragments).map do |subgraph|
            verify!(root, selections, subgraph, fragments, [], 0)
            return subgraph
          rescue Unplannable => e
            e
          end

          # every candidate refused; the first one's reason is the report
          raise refusals.fetch(0)
        end

        def entry_candidates(root, selections, fragments)
          fields = flatten(root, selections, fragments).reject { |node| node.name.start_with?("__") }
          # nothing but __typename: any subgraph answers it
          return @table.subgraphs if fields.empty?

          owners = fields.to_h { |node| [node.name, @table.owners(root, node.name)] }
          if (nowhere = owners.select { |_, graphs| graphs.empty? }.keys).any?
            refuse :no_owner, "the supergraph places #{root}.#{nowhere.first} in no subgraph"
          end

          shared = owners.values.reduce(:&)
          return shared if shared.any?

          refuse :root_fields_span,
            "this operation's root fields span subgraphs: #{describe(owners, root)}"
        end

        # Every field this operation reaches is resolvable by `subgraph`.
        def verify!(type_name, selections, subgraph, fragments, provided, depth)
          refuse(:too_deep, "this operation nests deeper than #{MAX_DEPTH} levels") if depth > MAX_DEPTH

          selections.each do |node|
            case node
            when GraphQL::Language::Nodes::Field
              next if node.name.start_with?("__")

              verify_field!(type_name, node, subgraph, fragments, provided, depth)
            when GraphQL::Language::Nodes::InlineFragment
              condition = node.type&.name || type_name
              verify_type!(condition, subgraph)
              verify!(condition, node.selections, subgraph, fragments, provided, depth + 1)
            when GraphQL::Language::Nodes::FragmentSpread
              fragment = fragments[node.name] or
                refuse(:undefined_fragment, "the document spreads ...#{node.name}, which it never defines")
              verify_type!(fragment.type.name, subgraph)
              verify!(fragment.type.name, fragment.selections, subgraph, fragments, provided, depth + 1)
            end
          end
        end

        def verify_field!(type_name, node, subgraph, fragments, provided, depth)
          owners = @table.owners(type_name, node.name)
          field = @table.field(type_name, node.name)

          unless owners.include?(subgraph) || provided.include?(node.name)
            if owners.empty?
              refuse :no_owner, "the supergraph places #{type_name}.#{node.name} in no subgraph"
            end

            refuse :crosses_subgraph,
              "#{type_name}.#{node.name} is resolved by #{owners.join(" or ")}, " \
              "and this operation runs in #{subgraph}"
          end

          verify_requires!(type_name, node, subgraph, field)
          return if node.selections.empty?

          child = child_type_name(type_name, node.name)
          verify!(child, node.selections, subgraph, fragments, provides(field), depth + 1)
        end

        # A @requires field set is supplied by the ROUTER: it fetches those
        # fields elsewhere and hands them back in the entity representation.
        # So the field is only answerable in place when its own subgraph
        # already holds every one of them — which, since @requires fields are
        # @external there, it essentially never does.
        def verify_requires!(type_name, node, subgraph, field)
          return unless field&.requires

          missing = GraphWeaver::SchemaLoader::RoutingTable.parse_field_set(field.requires)
            .reject { |path| @table.owners(type_name, path).include?(subgraph) }
          return if missing.empty?

          holders = missing.flat_map { |path| @table.owners(type_name, path) }.uniq
          refuse :requires,
            "#{type_name}.#{node.name} runs in #{subgraph} and @requires #{field.requires.inspect}, " \
            "which #{subgraph} doesn't hold (#{missing.join(", ")} " \
            "#{holders.any? ? "come from #{holders.join(" or ")}" : "belong to no subgraph"})"
        end

        # A fragment's type condition has to exist in the subgraph running the
        # operation; a type only another subgraph declares can't be matched
        # there. Types the routing table says nothing about (scalars, enums)
        # are nobody's.
        def verify_type!(type_name, subgraph)
          declared = @table.declared_in(type_name)
          return if declared.empty? || declared.include?(subgraph)

          refuse :crosses_subgraph,
            "#{type_name} lives in #{declared.join(" and ")}, and this operation runs in #{subgraph}"
        end

        # @provides says this subgraph carries its own copy of fields it
        # doesn't own, and the router reads that copy rather than routing to
        # the owner — so a query reaching only provided fields never leaves.
        # Flat sets only; a nested one widens nothing and its fields fall back
        # to the ordinary owner check.
        def provides(field)
          return [] unless field&.provides

          GraphWeaver::SchemaLoader::RoutingTable.parse_field_set(field.provides)
            .reject { |path| path.include?(".") }
        end

        def child_type_name(type_name, field_name)
          type = @schema.types[type_name]
          field = type.fields[field_name] if type.respond_to?(:fields)
          field or refuse(:no_owner, "#{type_name}.#{field_name} is not a field of the composed schema")

          unwrapped = field.type
          unwrapped = unwrapped.of_type while unwrapped.respond_to?(:of_type) && unwrapped.of_type
          unwrapped.graphql_name
        end

        # The root fields as plain Field nodes, with fragments on the root
        # type folded in.
        def flatten(type_name, selections, fragments, depth = 0)
          return [] if depth > MAX_DEPTH

          selections.flat_map do |node|
            case node
            when GraphQL::Language::Nodes::Field then [node]
            when GraphQL::Language::Nodes::InlineFragment
              flatten(type_name, node.selections, fragments, depth + 1)
            when GraphQL::Language::Nodes::FragmentSpread
              fragment = fragments[node.name]
              fragment ? flatten(type_name, fragment.selections, fragments, depth + 1) : []
            else []
            end
          end
        end

        def describe(owners, root)
          owners.map { |name, graphs| "#{root}.#{name} (#{graphs.join(" or ")})" }.join(", ")
        end

        def refuse(category, message)
          raise Unplannable.new(message, category:)
        end
      end
    end
  end
end
