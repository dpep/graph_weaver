# typed: true
# frozen_string_literal: true

require "graphql"
require "json"

require_relative "../schema_loader"
require_relative "../transport"
require_relative "subgraphs"

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
          "the local router crosses a boundary by refetching an entity from its @key, and this " \
            "isn't a shape it can do that to. Run this one against a real router.",
        ],
        no_key: [
          "no @key to cross the boundary on",
          "an entity fetch sends a representation built from a @key; with none there's nothing to " \
            "send. Run this one against a real router.",
        ],
        abstract_boundary: [
          "an abstract type at a subgraph boundary",
          "a representation names one concrete __typename, and the local router doesn't resolve a " \
            "type per object to build one. Run this one against a real router.",
        ],
        nested_field_set: [
          "a nested @key or @requires field set",
          "the local router builds representations from flat field sets only. Run this one against " \
            "a real router.",
        ],
        shadowed_key: [
          "an alias shadowing an injected @key",
          "Apollo's router resolves that collision in favour of its own injected key and a " \
            "spec-conformant server doesn't, so there is no one answer to agree with. Rename the alias.",
        ],
        root_fields_span: [
          "a mutation's root fields span subgraphs",
          "root mutation fields run in series and the local router can't serialize across " \
            "subgraphs. Split it into one operation per subgraph, or run this one against a real router.",
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
          "the local router answers introspection from the composed API schema and data from the " \
            "subgraphs, and can't merge the two. Split them into two operations.",
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
    # It plans the two shapes a router spends its life on: an operation that
    # resolves in one subgraph, handed over verbatim, and one that crosses a
    # boundary — split at the crossing, refetched from the owning subgraph
    # through `_entities(representations:)`, and stitched back. Everything it
    # can't plan *faithfully* raises {Unplannable}, before any subgraph runs,
    # so a refusal can never be a half-executed query. Apollo's planner is
    # twenty thousand lines; a double that approximated the rest of it would
    # let a test pass on an answer production disagrees with, which is the
    # most expensive thing this library can produce.
    #
    # Introspection is answered from the composed API schema — never from a
    # subgraph, which would reply with its own slice. That is the one split a
    # real router also makes.
    #
    # #trace records the fetches one execute made, in order (subgraph, query,
    # variables); the same lines go to GraphWeaver.logger at :debug.
    class Router
      # the schema the router serves — the supergraph with its composition
      # machinery stripped, exactly what a real router exposes
      attr_reader :schema

      # who resolves what (GraphWeaver::SchemaLoader::RoutingTable)
      attr_reader :table

      # the fetches the last execute made
      attr_reader :trace

      # the context handed to every subgraph — settable, so one example can
      # run as a different user without rebuilding the router
      attr_accessor :context

      # response keys the planner injects to carry a @key across a boundary,
      # stripped before the caller sees the tree
      PREFIX = "_gw_"

      # subgraphs: names the Ruby schema serving each subgraph. Omit it (or
      # any of its entries) and the rest are derived from what each loaded
      # schema defines — see {Subgraphs}, which also checks the ones you name.
      def initialize(supergraph:, subgraphs: nil, context: {})
        source = supergraph.to_s # a path, or the SDL itself — Pathname included
        @schema = GraphWeaver::SchemaLoader.load(source)
        @table = GraphWeaver::SchemaLoader.routing_table(source)
        @context = context
        @trace = []

        # refuse at construction, not per query: an unread @join__ construct
        # means the routing table is incomplete, and every answer it gives
        # about this supergraph is a guess — including which schema serves
        # which subgraph, so this comes before resolving those
        unless @table.unsupported.empty?
          raise Unplannable.new(
            "this supergraph uses federation constructs the local router doesn't read: " +
              @table.unsupported.join("; "),
            category: :unsupported_federation,
          )
        end

        @subgraphs = Subgraphs.resolve(@table, subgraphs)
        @planner = Planner.new(table: @table, schema: @schema)
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
        # one subgraph answers the whole thing: hand it the document as
        # written, so nothing is rewritten that didn't have to be
        return fetch(plan.entry, query, variables, plan.operation_name) if plan.verbatim

        run(plan, variables)
      end

      # never leak the context (tokens, current_user) through logs or errors
      def inspect = "#<#{self.class.name} subgraphs=#{@subgraphs.keys.inspect}>"
      alias to_s inspect

      private

      # __schema / __type describe the COMPOSED graph; a subgraph would
      # answer with its own slice
      def introspect(query, variables, operation_name)
        @schema.execute(query, variables: variables.to_h, operation_name:).to_h
      end

      # ---- execution ----------------------------------------------------

      def run(plan, variables)
        errors = []
        data = {}
        given = variables.to_h { |name, value| [name.to_s, value] }

        plan.steps.each do |step|
          result = fetch_step(step, plan.operation, given)
          Array(result["errors"]).each { |error| errors << rewrite(error) }
          payload = result["data"]
          if payload.nil?
            # the subgraph nulled its whole response, so every field it was
            # asked for is null — recording that is what lets propagation
            # decide what it does to the merged tree
            step.selections.each { |node| data[node.alias || node.name] = nil }
          else
            payload.each { |key, value| data[key] = value }
          end
        end

        plan.steps.each { |step| stitch(step, [[data, []]], plan.operation, given, errors) }

        # A stitched fetch can leave a null where the composed schema says
        # non-null, and nothing re-applies GraphQL's propagation rules over a
        # merged tree unless this does: without it the local answer is
        # *wrong* rather than incomplete, handing back a populated subtree the
        # router would have nulled.
        merged = propagate(data, plan.root_type, plan.selections, plan.fragments)
        response = { "data" => merged.equal?(BUBBLE) ? nil : merged }
        response["errors"] = errors if errors.any?
        response
      end

      # Everything the plan applies at this level: one _entities fetch per
      # subgraph the level defers to (all nodes at once — _entities answers
      # in representation order), then the same again one level down.
      def stitch(step, nodes, operation, variables, errors)
        return if nodes.empty?

        step.deferrals.group_by(&:subgraph).each do |target, deferrals|
          paths = deferrals.flat_map(&:representation).uniq
          representations = nodes.map do |(node, _)|
            paths.to_h { |path| [path, node[PREFIX + path]] }.merge("__typename" => step.type_name)
          end

          result = entities_fetch(target, step.type_name, deferrals, representations, operation, variables)
          entities = result.dig("data", "_entities") || []
          Array(result["errors"]).each { |error| errors << rewrite(error, nodes) }

          nodes.each_with_index do |(node, _), index|
            entity = entities[index]
            deferrals.each do |deferral|
              # @skip/@include leave a key ABSENT rather than null, and
              # copying a null would invent one the router never emits
              next if entity && !entity.key?(deferral.response_key)

              node[deferral.response_key] = entity && entity[deferral.response_key]
            end
          end

          deferrals.each do |deferral|
            next unless deferral.step

            stitch(deferral.step, descend(nodes, deferral.response_key), operation, variables, errors)
          end
        end

        step.children.each do |key, child|
          stitch(child, descend(nodes, key), operation, variables, errors)
        end

        nodes.each { |(node, _)| strip!(node, step) }
      end

      # Every object the plan's next level applies to, with the response path
      # that reached it — list dimensions flattened, nulls contributing
      # nothing (a null parent has no representation, so it needs no fetch).
      def descend(nodes, key)
        nodes.flat_map { |(node, path)| flatten(node[key], path + [key]) }
      end

      def flatten(value, path)
        case value
        when Array then value.each_with_index.flat_map { |item, i| flatten(item, path + [i]) }
        when Hash then [[value, path]]
        else []
        end
      end

      def strip!(node, step)
        step.injected.each { |path| node.delete(PREFIX + path) }
      end

      # A subgraph reports where the failure was in the query IT ran, and a
      # stitched plan runs queries the caller never wrote: `_entities.<i>.…`
      # is a path into the fetch, and `locations` a position in it. Re-path
      # what can be re-pathed and drop what can't, rather than hand back a
      # line number pointing into a document that doesn't exist.
      def rewrite(error, nodes = nil)
        path = error["path"]
        return error.except("locations") unless nodes && path.is_a?(Array) && path.first == "_entities"

        error.except("locations").merge("path" => (nodes.dig(path[1], 1) || []) + path[2..])
      end

      def fetch_step(step, operation, variables)
        document = GraphQL::Language::Nodes::OperationDefinition.new(
          operation_type: operation.operation_type || "query",
          variables: used_variables(step.selections, operation),
          selections: step.selections,
        )
        run_subgraph(step.subgraph, document, variables)
      end

      def entities_fetch(subgraph, type_name, deferrals, representations, operation, variables)
        nodes = deferrals.map(&:node)
        entities = GraphQL::Language::Nodes::Field.new(
          name: "_entities",
          arguments: [GraphQL::Language::Nodes::Argument.new(
            name: "representations",
            value: GraphQL::Language::Nodes::VariableIdentifier.new(name: REPRESENTATIONS),
          )],
          selections: [GraphQL::Language::Nodes::InlineFragment.new(
            type: GraphQL::Language::Nodes::TypeName.new(name: type_name),
            selections: nodes,
          )],
        )
        document = GraphQL::Language::Nodes::OperationDefinition.new(
          operation_type: "query",
          variables: [REPRESENTATIONS_DEFINITION] + used_variables(nodes, operation),
          selections: [entities],
        )
        run_subgraph(subgraph, document, variables.merge(REPRESENTATIONS => representations))
      end

      REPRESENTATIONS = "representations"
      REPRESENTATIONS_DEFINITION = GraphQL::Language::Nodes::VariableDefinition.new(
        name: REPRESENTATIONS,
        type: GraphQL::Language::Nodes::NonNullType.new(
          of_type: GraphQL::Language::Nodes::ListType.new(
            of_type: GraphQL::Language::Nodes::NonNullType.new(
              of_type: GraphQL::Language::Nodes::TypeName.new(name: "_Any"),
            ),
          ),
        ),
      )

      # A subgraph query may only declare the variables it uses, so each
      # fetch carries the slice of the operation's definitions it reached.
      def used_variables(nodes, operation)
        names = variable_names(nodes)
        operation.variables.select { |definition| names.include?(definition.name) }
      end

      # #children is every child node — arguments, directives, selections,
      # and an argument's value when that value is a node — so a $var reached
      # anywhere under these selections is reached from here.
      def variable_names(node)
        case node
        when GraphQL::Language::Nodes::VariableIdentifier then [node.name]
        when Array then node.flat_map { |item| variable_names(item) }
        when GraphQL::Language::Nodes::AbstractNode then variable_names(node.children)
        else []
        end
      end

      def run_subgraph(subgraph, document, variables)
        declared = document.variables.map(&:name)
        fetch(subgraph, document.to_query_string, variables.slice(*declared), nil)
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

      # ---- null propagation ---------------------------------------------

      # a position whose type forbids null but whose value is null: the
      # parent goes null, and again, until a nullable spot absorbs it
      BUBBLE = Object.new
      private_constant :BUBBLE

      def propagate(value, type, selections, fragments)
        if type.non_null?
          inner = propagate(value, type.of_type, selections, fragments)
          (inner.nil? || inner.equal?(BUBBLE)) ? BUBBLE : inner
        elsif type.list?
          return if value.nil?

          items = value.map { |item| propagate(item, type.of_type, selections, fragments) }
          items.any? { |item| item.equal?(BUBBLE) } ? nil : items
        elsif type.kind.abstract?
          # an abstract subtree only ever goes to ONE subgraph, which applied
          # its own propagation before answering — there is nothing to redo
          value
        elsif type.kind.fields?
          propagate_object(value, type, selections, fragments)
        else
          value
        end
      end

      def propagate_object(value, type, selections, fragments)
        return if value.nil?
        return value unless value.is_a?(Hash)

        # a merged tree carries each subgraph's keys in fetch order; the
        # response is supposed to be in the query's
        ordered = {}
        selections.each do |node|
          key = node.alias || node.name
          ordered[key] = value[key] if value.key?(key)
        end
        value.each { |key, held| ordered[key] = held unless ordered.key?(key) }

        selections.each do |node|
          next if node.name.start_with?("__")

          key = node.alias || node.name
          next unless ordered.key?(key)

          field = type.fields[node.name] or next
          child = unwrap(field.type)
          sub = node.selections.any? ? inline(node.selections, fragments, child.graphql_name) : []
          result = propagate(ordered[key], field.type, sub, fragments)
          return if result.equal?(BUBBLE)

          ordered[key] = result
        end
        ordered
      end

      # Fragments folded in for the propagation walk. Unlike the planner's
      # expand this just skips a fragment on another type: those subtrees ran
      # whole in one subgraph and need no rework.
      def inline(selections, fragments, type_name)
        selections.flat_map do |node|
          case node
          when GraphQL::Language::Nodes::Field then [node]
          when GraphQL::Language::Nodes::InlineFragment
            matches?(node.type&.name, type_name) ? inline(node.selections, fragments, type_name) : []
          when GraphQL::Language::Nodes::FragmentSpread
            fragment = fragments[node.name]
            (fragment && matches?(fragment.type.name, type_name)) ? inline(fragment.selections, fragments, type_name) : []
          else []
          end
        end
      end

      def matches?(condition, type_name) = condition.nil? || condition == type_name

      def unwrap(type)
        type = type.of_type while type.respond_to?(:of_type) && type.of_type
        type
      end

      # Decides which subgraph answers what — and, where an operation crosses
      # a boundary, the tree of fetches that answers it. Separate from the
      # Router because deciding needs only the supergraph: `rake
      # graph_weaver:federation:coverage` measures how much of a query set is
      # plannable without any subgraph being runnable.
      class Planner
        # One subgraph fetch. `selections` go over as written; `injected`
        # names the @key paths added under Router::PREFIX to carry entities
        # across a boundary; `children` and `deferrals` are what happens to
        # the objects it answers with — a child stays in this subgraph and
        # only carries deferrals deeper, a deferral is refetched elsewhere.
        # Both are lists: two selections can share a response key, and each
        # brings its own subtree.
        Step = Struct.new(:subgraph, :type_name, :selections, :injected, :children, :deferrals,
          keyword_init: true) do
          def subgraphs
            [subgraph] + children.flat_map { |_key, child| child.subgraphs } + deferrals.flat_map(&:subgraphs)
          end
        end

        # A field this subgraph can't resolve: refetch the parent entity from
        # `subgraph` and read it there.
        Deferral = Struct.new(:node, :response_key, :subgraph, :step, :key, :requires,
          keyword_init: true) do
          def subgraphs = [subgraph] + (step ? step.subgraphs : [])

          # the paths a representation for this deferral has to carry
          def representation = (key + requires).uniq
        end

        # What one operation costs. `verbatim` is the shape the whole thing
        # resolves in one subgraph, where the document goes over untouched.
        Plan = Struct.new(:steps, :operation, :selections, :fragments, :root_type, :introspection,
          :verbatim, keyword_init: true) do
          def operation_name = operation&.name

          def entry = steps.first&.subgraph

          # every subgraph the plan fetches from, in plan order
          def subgraphs = steps.flat_map(&:subgraphs).uniq

          # which subgraphs it touches, for a report — "accounts+reviews"
          # when it stitches (sorted: fetch order is what #trace is for)
          def where = introspection ? "(introspection)" : subgraphs.sort.join("+")
        end

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
          root = root_type(operation)
          selections = flatten(root.graphql_name, operation.selections, fragments)
          plan = Plan.new(operation:, selections:, fragments:, root_type: root, steps: [])

          introspection, data = selections.partition { |node| INTROSPECTION.include?(node.name) }
          if introspection.any?
            if data.any? { |node| node.name != "__typename" }
              refuse :mixed_introspection,
                "this operation selects #{introspection.map(&:name).uniq.join(" and ")} " \
                "alongside data fields"
            end

            plan.introspection = true
            return plan
          end

          entry = single_subgraph(root.graphql_name, selections, fragments)
          if entry
            plan.verbatim = true
            plan.steps = [step(entry, root.graphql_name)]
            return plan
          end

          plan.steps = root_steps(root.graphql_name, selections, operation, fragments)
          plan
        end

        private

        def step(subgraph, type_name)
          Step.new(subgraph:, type_name:, selections: [], injected: [], children: [], deferrals: [])
        end

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

        def root_type(operation)
          root = (operation.operation_type == "mutation") ? @schema.mutation : @schema.query
          root || refuse(:operation_type,
            "the composed schema has no #{operation.operation_type || "query"} root type")
        end

        # The one subgraph that answers the whole operation, if there is one.
        # Root fields fix the candidates: they're independent, so the ones
        # they share are the only subgraphs that could answer everything.
        def single_subgraph(root, selections, fragments)
          fields = selections.reject { |node| node.name.start_with?("__") }
          shared = fields.map { |node| owners!(root, node.name) }.reduce(:&) || @table.subgraphs
          shared.find { |subgraph| local?(root, selections, subgraph, fragments, []) }
        end

        # Root fields resolve independently, so each picks its own subgraph
        # and one fetch goes to each — preferring a subgraph already in the
        # plan, so a query that could run in fewer doesn't run in more.
        def root_steps(root, selections, operation, fragments)
          if operation.operation_type == "mutation"
            owners = selections.reject { |node| node.name.start_with?("__") }
              .to_h { |node| [node.name, owners!(root, node.name)] }
            # root mutation fields run in series; splitting them across
            # subgraphs would run them in whatever order the plan happens to
            refuse :root_fields_span, "this mutation's root fields span subgraphs: " \
              "#{owners.map { |name, graphs| "#{root}.#{name} (#{graphs.join(" or ")})" }.join(", ")}"
          end

          groups = {}
          loose = []
          selections.each do |node|
            if node.name.start_with?("__")
              loose << node
              next
            end

            graphs = owners!(root, node.name)
            (groups[(graphs & groups.keys).first || graphs.first] ||= []) << node
          end
          groups[@table.subgraphs.first] ||= [] if groups.empty?
          # __typename doesn't route; any subgraph answers it
          groups[groups.keys.first].concat(loose)

          groups.map { |subgraph, nodes| plan_step(root, nodes, subgraph, fragments, [], 0) }
        end

        # Build the fetch for `selections` on `type_name` in `subgraph`.
        # `provided` names fields a @provides copy makes answerable here even
        # though the routing table places them elsewhere.
        def plan_step(type_name, selections, subgraph, fragments, provided, depth)
          refuse(:too_deep, "this operation nests deeper than #{MAX_DEPTH} levels") if depth > MAX_DEPTH

          here = step(subgraph, type_name)
          selections.each do |node|
            # a subtree that never leaves this subgraph goes over as written:
            # the boundary rules govern stitching, so they have no business
            # applying to a query that was never going to cross one
            if node.name.start_with?("__") || local?(type_name, [node], subgraph, fragments, provided)
              here.selections << node
              next
            end

            owners = owners!(type_name, node.name)
            field = @table.field(type_name, node.name)
            if owners.include?(subgraph) || provided.include?(node.name)
              descend(here, type_name, node, subgraph, field, fragments, depth)
            else
              defer(here, type_name, node, subgraph, owners, field, fragments, selections, depth)
            end
          end

          here
        end

        # The field resolves in this subgraph but something under it doesn't.
        def descend(step, type_name, node, subgraph, field, fragments, depth)
          check_requires!(type_name, node, subgraph, field)
          child = plan_child(type_name, node, subgraph, field, fragments, depth)

          step.selections << node.merge(selections: child.selections)
          step.children << [node.alias || node.name, child]
        end

        # The plan for what this field returns, run in `subgraph`.
        def plan_child(type_name, node, subgraph, field, fragments, depth)
          child_type = child_type_name(type_name, node.name)
          # expand first: it refuses a fragment by naming the type that
          # crosses, which reads better than "this field returns a union"
          selections = expand(child_type, node.selections, subgraph, fragments)
          check_concrete!(type_name, node.name, child_type)
          plan_step(child_type, selections, subgraph, fragments, provides(field), depth + 1)
        end

        # The field resolves somewhere else: refetch this object there from
        # its @key, and read the field off the entity that comes back.
        def defer(step, type_name, node, subgraph, owners, field, fragments, siblings, depth)
          target = owners.first
          key = usable_key(type_name, node, subgraph, target)
          requires = requires_paths(type_name, node, field)

          unreachable = requires.reject { |path| @table.owners(type_name, path).include?(subgraph) }
          if unreachable.any?
            holders = unreachable.flat_map { |path| @table.owners(type_name, path) }.uniq
            refuse :requires,
              "#{type_name}.#{node.name} runs in #{target} and @requires #{field.requires.inspect}, " \
              "which #{subgraph} can't supply (#{unreachable.join(", ")} " \
              "#{holders.any? ? "come from #{holders.join(" or ")}" : "belong to no subgraph"})"
          end

          injected = (key + requires).uniq
          check_shadowing!(type_name, node, siblings, injected)
          injected.each { |path| inject(step, path) }

          child = plan_child(type_name, node, target, field, fragments, depth) if node.selections.any?

          step.deferrals << Deferral.new(
            node: child ? node.merge(selections: child.selections) : node,
            response_key: node.alias || node.name,
            subgraph: target,
            step: child || nil,
            key:, requires:,
          )
        end

        def inject(step, path)
          return if step.injected.include?(path)

          step.injected << path
          step.selections << GraphQL::Language::Nodes::Field.new(name: path, field_alias: Router::PREFIX + path)
        end

        # Apollo's router injects the @key under its own name and lets it win,
        # so `{ id: username }` next to a stitched field comes back as the
        # user's id. That is an Apollo bug and a spec-conformant server
        # disagrees — and since we can't match both, refuse rather than hand
        # back an answer one of them contradicts.
        def check_shadowing!(type_name, node, siblings, paths)
          shadowed = siblings.select do |sibling|
            sibling.alias && sibling.alias != sibling.name && paths.include?(sibling.alias)
          end
          return if shadowed.empty?

          refuse :shadowed_key,
            "#{type_name}.#{node.name} is fetched on #{type_name}'s #{paths.map(&:inspect).join(", ")}, " \
            "and this selection aliases " \
            "#{shadowed.map { |s| "#{s.name} as #{s.alias.inspect}" }.join(", ")} over it"
        end

        # A @key field set the source subgraph can build a representation
        # from. An @external copy counts: it exists precisely so this
        # subgraph can name the field in its @key.
        def usable_key(type_name, node, from, to)
          candidates = @table.keys(type_name, to)
          if candidates.empty?
            refuse :no_key,
              "#{type_name}.#{node.name} resolves in #{to}, and #{type_name} has no resolvable " \
              "@key there"
          end

          flat, nested = candidates.partition { |paths| paths.none? { |path| path.include?(".") } }
          usable = flat.find { |paths| paths.all? { |path| declares?(type_name, path, from) } }
          return usable if usable

          if flat.empty?
            refuse :nested_field_set, "#{type_name} is keyed in #{to} on a nested field set " \
              "(#{nested.map { |paths| paths.join(" ").inspect }.join(", ")})"
          end

          refuse :no_key, "#{type_name}.#{node.name} needs a fetch into #{to}, and #{from} can't " \
            "supply any of #{type_name}'s @keys there " \
            "(#{flat.map { |paths| paths.join(" ").inspect }.join(", ")})"
        end

        def requires_paths(type_name, node, field)
          return [] unless field&.requires

          paths = GraphWeaver::SchemaLoader::RoutingTable.parse_field_set(field.requires)
          nested = paths.select { |path| path.include?(".") }
          return paths if nested.empty?

          refuse :nested_field_set, "#{type_name}.#{node.name} @requires a nested field set " \
            "(#{nested.map(&:inspect).join(", ")})"
        end

        # A @requires field set is supplied by the ROUTER: it fetches those
        # fields elsewhere and hands them back in the representation. So a
        # field that stays put is only answerable when its own subgraph
        # already holds every one of them — which, since @requires fields are
        # @external there, it essentially never does.
        def check_requires!(type_name, node, subgraph, field)
          return unless field&.requires

          missing = requires_paths(type_name, node, field)
            .reject { |path| @table.owners(type_name, path).include?(subgraph) }
          return if missing.empty?

          holders = missing.flat_map { |path| @table.owners(type_name, path) }.uniq
          refuse :requires,
            "#{type_name}.#{node.name} runs in #{subgraph} and @requires #{field.requires.inspect}, " \
            "which #{subgraph} doesn't hold (#{missing.join(", ")} " \
            "#{holders.any? ? "come from #{holders.join(" or ")}" : "belong to no subgraph"})"
        end

        # Every field these selections reach is answerable by `subgraph`, so
        # the whole subtree can go over untouched.
        def local?(type_name, selections, subgraph, fragments, provided, depth = 0)
          return false if depth > MAX_DEPTH

          selections.all? do |node|
            case node
            when GraphQL::Language::Nodes::Field
              next true if node.name.start_with?("__")

              local_field?(type_name, node, subgraph, fragments, provided, depth)
            when GraphQL::Language::Nodes::InlineFragment
              condition = node.type&.name || type_name
              declared_in?(condition, subgraph) &&
                local?(condition, node.selections, subgraph, fragments, provided, depth + 1)
            when GraphQL::Language::Nodes::FragmentSpread
              fragment = fragments[node.name] or
                refuse(:undefined_fragment, "the document spreads ...#{node.name}, which it never defines")
              declared_in?(fragment.type.name, subgraph) &&
                local?(fragment.type.name, fragment.selections, subgraph, fragments, provided, depth + 1)
            else false
            end
          end
        end

        def local_field?(type_name, node, subgraph, fragments, provided, depth)
          owners = @table.owners(type_name, node.name)
          return false unless owners.include?(subgraph) || provided.include?(node.name)

          field = @table.field(type_name, node.name)
          if field&.requires
            held = GraphWeaver::SchemaLoader::RoutingTable.parse_field_set(field.requires)
              .all? { |path| @table.owners(type_name, path).include?(subgraph) }
            return false unless held
          end
          return true if node.selections.empty?

          child = raw_child_type(type_name, node.name) or return false
          local?(child, node.selections, subgraph, fragments, provides(field), depth + 1)
        end

        # Inline fragments and named spreads folded in, so a step's selections
        # are plain fields it can route one at a time. A fragment on another
        # type applies to only some objects, and a fetch can't be split
        # conditionally — so that one has to run whole in one subgraph, and
        # travels as written.
        def expand(type_name, selections, subgraph, fragments, depth = 0)
          return [] if depth > MAX_DEPTH

          selections.flat_map do |node|
            case node
            when GraphQL::Language::Nodes::Field then [node]
            when GraphQL::Language::Nodes::InlineFragment
              condition = node.type&.name
              next expand(type_name, node.selections, subgraph, fragments, depth + 1) if
                condition.nil? || condition == type_name

              check_condition!(type_name, condition, node.selections, subgraph, fragments)
              [node]
            when GraphQL::Language::Nodes::FragmentSpread
              fragment = fragments[node.name] or
                refuse(:undefined_fragment, "the document spreads ...#{node.name}, which it never defines")
              next expand(type_name, fragment.selections, subgraph, fragments, depth + 1) if
                fragment.type.name == type_name

              check_condition!(type_name, fragment.type.name, fragment.selections, subgraph, fragments)
              [node]
            else []
            end
          end
        end

        def check_condition!(type_name, condition, selections, subgraph, fragments)
          unless declared_in?(condition, subgraph)
            refuse :crosses_subgraph,
              "#{condition} lives in #{@table.declared_in(condition).join(" and ")}, and this " \
              "operation runs in #{subgraph}"
          end
          return if local?(condition, selections, subgraph, fragments, [])

          refuse :abstract_boundary,
            "this operation selects ...on #{condition} inside #{type_name} and part of it resolves " \
            "outside #{subgraph}"
        end

        # A fragment's type condition has to exist in the subgraph running
        # it; a type only another subgraph declares can't be matched there.
        # Types the routing table says nothing about (scalars, enums) are
        # nobody's.
        def declared_in?(type_name, subgraph)
          declared = @table.declared_in(type_name)
          declared.empty? || declared.include?(subgraph)
        end

        # Whether `subgraph` can hand back this field as part of a
        # representation — an @external copy counts, which is the whole
        # reason one is declared.
        def declares?(type_name, path, subgraph)
          field = @table.field(type_name, path)
          return @table.declared_in(type_name).include?(subgraph) if field.nil?

          field.graphs.include?(subgraph) || field.external.include?(subgraph)
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

        def owners!(type_name, field_name)
          owners = @table.owners(type_name, field_name)
          return owners if owners.any?

          refuse :no_owner, "the supergraph places #{type_name}.#{field_name} in no subgraph"
        end

        def child_type_name(type_name, field_name)
          raw_child_type(type_name, field_name) ||
            refuse(:no_owner, "#{type_name}.#{field_name} is not a field of the composed schema")
        end

        # We only ask past a field whose subtree crosses a boundary, and a
        # representation names one concrete __typename — so an abstract type
        # is as far as the plan goes.
        def check_concrete!(type_name, field_name, child_type)
          kind = @schema.types[child_type]&.kind
          return unless kind&.abstract?

          refuse :abstract_boundary,
            "#{type_name}.#{field_name} returns #{child_type}, " \
            "#{(kind.name == "UNION") ? "a union" : "an interface"}, and part of its selection " \
            "resolves in another subgraph"
        end

        def raw_child_type(type_name, field_name)
          type = @schema.types[type_name]
          return unless type.respond_to?(:fields)

          field = type.fields[field_name] or return
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

        def refuse(category, message)
          raise Unplannable.new(message, category:)
        end
      end
    end
  end
end
