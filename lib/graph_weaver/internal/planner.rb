# typed: true
# frozen_string_literal: true

require "graphql"

require_relative "../selection"
require_relative "subgraphs"

module GraphWeaver
  module Internal
    # Decides which subgraph answers what — and, where an operation crosses
    # a boundary, the tree of fetches that answers it. Separate from the
    # Router because deciding needs only the supergraph: `rake
    # graph_weaver:federation:coverage` measures how much of a query set is
    # plannable without any subgraph being runnable.
    class Planner
      # response keys the planner injects to carry a @key across a boundary,
      # stripped before the caller sees the tree
      PREFIX = "_gw_"

      # Where the injected __typename lands. Which concrete type an abstract
      # position holds is a fact only the data carries, so every abstract
      # fetch asks for it — under this key whether or not the caller did.
      TYPENAME = "#{PREFIX}__typename"

      # A field set as dotted paths, back into the selection set it was parsed
      # from ({"origin" => {"lat" => {}, "lon" => {}}}). Both sides of a
      # crossing need it: one to ask for the fields, the other to read them
      # back in the shape the SDL spells.
      def self.field_tree(paths)
        paths.each_with_object({}) do |path, tree|
          path.split(".").reduce(tree) { |node, segment| node[segment] ||= {} }
        end
      end

      # What a fetch adds to carry a field set across a boundary: one field
      # per root, aliased under PREFIX so the caller's answer never gains a
      # field it didn't ask for, and nested exactly as the field set is —
      # `origin { lat lon }` comes back whole, under one response key.
      def self.injected_selections(paths)
        field_tree(paths).map do |root, children|
          GraphQL::Language::Nodes::Field.new(
            name: root, field_alias: PREFIX + root, selections: field_selections(children),
          )
        end
      end

      def self.field_selections(tree)
        tree.map do |name, children|
          GraphQL::Language::Nodes::Field.new(name:, selections: field_selections(children))
        end
      end
      private_class_method :field_selections

      # One subgraph fetch. `selections` go over as written; `keys` names the
      # @key/@requires paths this fetch also asks for, to carry entities
      # across a boundary, and `injected` the response keys those land under
      # (PREFIX + the path's first segment — a nested field set
      # arrives as one object), which the answer is stripped of. `children`
      # and `deferrals` are what happens to the objects it answers with — a
      # child stays in this subgraph and only carries deferrals deeper, a
      # deferral is refetched elsewhere. Both are lists: two selections can
      # share a response key, and each brings its own subtree.
      Step = Struct.new(:subgraph, :type_name, :selections, :keys, :injected, :prefetches,
        :children, :deferrals, keyword_init: true) do
        def subgraphs
          [subgraph] + prefetches.map(&:subgraph) +
            children.flat_map { |_key, child| child.subgraphs } + deferrals.flat_map(&:subgraphs)
        end
      end

      # the __typename every abstract fetch asks for, under the router's own
      # response key so the caller's answer never gains one it didn't ask for
      TYPENAME_FIELD = GraphQL::Language::Nodes::Field.new(
        name: "__typename", field_alias: TYPENAME,
      )

      # What a field returning an abstract type defers to: one plan per
      # concrete type the subgraph can answer with. Which of them applies is
      # a fact about the data, and the planner runs before any fetch — so it
      # plans them all and {Router#stitch} picks by __typename.
      Branches = Struct.new(:steps, keyword_init: true) do
        def subgraphs = steps.each_value.flat_map(&:subgraphs)

        # what the parent's fetch asks for: each branch under its own type
        # condition, and the __typename that says which one answered
        def selections
          [TYPENAME_FIELD] + steps.filter_map do |type_name, step|
            next if step.selections.empty?

            GraphQL::Language::Nodes::InlineFragment.new(
              type: GraphQL::Language::Nodes::TypeName.new(name: type_name),
              selections: step.selections,
            )
          end
        end
      end

      # A @requires field set the router has to supply: fetch those fields
      # from the subgraph that holds them, into hidden keys on the object,
      # before the fetch whose representation carries them.
      # `node` is the selection whose @requires this feeds — the fetch is
      # only made when that selection survives @skip/@include.
      Prefetch = Struct.new(:subgraph, :key, :paths, :node, keyword_init: true)

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

      # absent: subgraphs no schema serves here. ambiguous: the ones
      # several loaded classes fit, as { name => candidate class names }.
      # Planning is otherwise unchanged — coverage plans with neither, which
      # is why both are facts about this process rather than about the
      # graph.
      def initialize(table:, schema:, absent: [], ambiguous: {})
        @table = table
        @schema = schema
        @absent = absent
        @ambiguous = ambiguous
        @unserved = absent + ambiguous.keys
        @interface_objects = table.interface_objects
      end

      # the operation's validation errors, GraphQL-wire shaped
      def validate(document)
        @schema.validate(document)
          .map { |error| Wire.graphql_error(error.message, "GRAPHQL_VALIDATION_FAILED") }
      end

      def plan(document, operation_name: nil)
        operation = pick_operation(document, operation_name)
        refuse(:operation_type, "this document is a subscription") if
          operation.operation_type == "subscription"

        fragments = document.definitions
          .grep(GraphQL::Language::Nodes::FragmentDefinition).to_h { |f| [f.name, f] }
        root = root_type(operation)
        selections = narrow(root.graphql_name, operation.selections, fragments)
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

        check_interface_objects!(root.graphql_name, selections, fragments) if @interface_objects.any?

        entry = single_subgraph(root.graphql_name, selections, fragments)
        if entry
          plan.verbatim = true
          plan.steps = [step(entry, root.graphql_name)]
          return plan
        end

        plan.steps = root_steps(root.graphql_name, selections, operation, fragments)
        plan
      end

      # The selections that apply to ONE concrete type, as plain fields a
      # step can route one at a time: fields written at this position, plus
      # every fragment whose condition that type satisfies, folded in. A
      # fragment it can't be never matches, so it is dropped rather than
      # travelling as written — every position a step plans is concrete, so
      # a condition either holds for all of its objects or for none.
      #
      # Public because {Router#propagate} asks the same question of the
      # merged tree: which selections describe the object in hand.
      def narrow(concrete, selections, fragments, depth = 0)
        return [] if depth > MAX_DEPTH

        selections.flat_map do |node|
          case node
          when GraphQL::Language::Nodes::Field then [node]
          when GraphQL::Language::Nodes::InlineFragment
            next [] unless applies?(node.type&.name, concrete)

            carry(node, narrow(concrete, node.selections, fragments, depth + 1))
          when GraphQL::Language::Nodes::FragmentSpread
            fragment = fragments[node.name] or
              refuse(:undefined_fragment, "the document spreads ...#{node.name}, which it never defines")
            next [] unless applies?(fragment.type.name, concrete)

            carry(node, narrow(concrete, fragment.selections, fragments, depth + 1))
          else []
          end
        end
      end

      private

      # Every type these selections reach, refused if one of them is an
      # @interfaceObject: a subgraph resolves the whole interface there, so
      # the supergraph records no per-field routing for it and every fetch
      # planned against it would be a guess. Asked per query rather than at
      # construction — one such directive shouldn't cost you the queries
      # that never touch the type.
      def check_interface_objects!(type_name, selections, fragments, depth = 0)
        return if depth > MAX_DEPTH

        selections.each do |node|
          case node
          when GraphQL::Language::Nodes::Field
            next if node.name.start_with?("__")

            child = raw_child_type(type_name, node.name) or next
            interface_object!(child, "#{type_name}.#{node.name} returns #{child}")
            check_interface_objects!(child, node.selections, fragments, depth + 1)
          when GraphQL::Language::Nodes::InlineFragment
            condition = node.type&.name || type_name
            interface_object!(condition, "this operation selects ... on #{condition}")
            check_interface_objects!(condition, node.selections, fragments, depth + 1)
          when GraphQL::Language::Nodes::FragmentSpread
            fragment = fragments[node.name] or next
            condition = fragment.type.name
            interface_object!(condition, "...#{node.name} is on #{condition}")
            check_interface_objects!(condition, fragment.selections, fragments, depth + 1)
          end
        end
      end

      def interface_object!(type_name, where)
        graphs = @interface_objects[type_name] or return

        refuse :interface_object,
          "#{where}, which #{graphs.join(" and ")} resolves as an @interfaceObject"
      end

      # Whether a fragment's condition holds for every object of `concrete`
      # — the type itself, or an abstract type it satisfies.
      def applies?(condition, concrete)
        return true if condition.nil? || condition == concrete

        type = @schema.get_type(condition)
        !!type&.kind&.abstract? && @schema.possible_types(type).any? { |t| t.graphql_name == concrete }
      end

      def step(subgraph, type_name)
        Step.new(subgraph:, type_name:, selections: [], keys: [], injected: [], prefetches: [],
          children: [], deferrals: [])
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
        # no refusal here: an absent candidate just isn't one, and the
        # per-field walk below names it if that's what stops the query
        (shared - @unserved).find { |subgraph| local?(root, selections, subgraph, fragments, []) }
      end

      # Root fields resolve independently, so each picks its own subgraph
      # and one fetch goes to each — preferring a subgraph already in the
      # plan, so a query that could run in fewer doesn't run in more.
      def root_steps(root, selections, operation, fragments)
        if operation.operation_type == "mutation"
          owners = selections.reject { |node| node.name.start_with?("__") }
            .to_h { |node| [node.name, owners!(root, node.name)] }
          # Root mutation fields run in series. Sharing a subgraph, they go
          # over as one document and it serializes them; only roots in
          # *different* subgraphs would run in whatever order the plan
          # happens to. Whatever stitches below a root is an ordinary read
          # afterwards, so it doesn't bear on the ordering.
          shared = owners.values.reduce(:&) || @table.subgraphs
          if shared.empty?
            refuse :root_fields_span, "this mutation's root fields span subgraphs: " \
              "#{owners.map { |name, graphs| "#{root}.#{name} (#{graphs.join(" or ")})" }.join(", ")}"
          end

          # one root field: shared IS its owners, so an absence names it
          subject = owners.one? ? "#{root}.#{owners.keys.first}" : root
          return [plan_step(root, selections, available!(shared, subject).first, fragments, [], 0)]
        end

        groups = {}
        loose = []
        selections.each do |node|
          if node.name.start_with?("__")
            loose << node
            next
          end

          graphs = available!(owners!(root, node.name), "#{root}.#{node.name}")
          (groups[(graphs & groups.keys).first || graphs.first] ||= []) << node
        end
        groups[available!(@table.subgraphs, root).first] ||= [] if groups.empty?
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
            here.selections << inline_spreads(node, fragments)
            next
          end

          owners = owners!(type_name, node.name)
          field = @table.field(type_name, node.name)
          resolves_here = owners.include?(subgraph) || provided.include?(node.name)
          if resolves_here && held?(type_name, field, subgraph)
            descend(here, type_name, node, subgraph, field, fragments, depth)
          else
            # a field whose @requires this subgraph can't supply is refetched
            # even when it resolves here — the fields have to arrive in a
            # representation, and only an entity fetch carries one
            target = resolves_here ? subgraph : available!(owners, "#{type_name}.#{node.name}").first
            defer(here, type_name, node, subgraph, target, field, fragments, selections, depth)
          end
        end

        check_one_source!(type_name, here, subgraph)
        # every crossing this fetch feeds, asked for once and together: a
        # field set shared by two deferrals is one selection, and a nested
        # one is nested rather than a dotted alias no schema has
        here.selections.concat(Planner.injected_selections(here.keys))
        here.injected = (here.keys + here.prefetches.flat_map(&:paths))
          .map { |path| PREFIX + path.split(".").first }.uniq
        check_reserved!(type_name, selections, here.injected)
        here
      end

      # The keys a fetch injects are stripped from the answer, so a caller's
      # alias spelling one is stripped with it — silently, since the two are
      # then indistinguishable. Asked of what this fetch actually injects
      # rather than of the prefix, so an alias that collides with nothing
      # still runs.
      def check_reserved!(type_name, selections, injected)
        clash = selections.select { |node| injected.include?(node.alias) }
        return if clash.empty?

        refuse :shadowed_key, "#{type_name} crosses on a field set the router carries under " \
          "#{injected.map(&:inspect).join(", ")}, and this selection aliases " \
          "#{clash.map { |node| "#{node.name} as #{node.alias.inspect}" }.join(", ")} over it"
      end

      # A subtree that goes over as written may still hold a fragment spread
      # — `narrow` only expands the ones at a position it routes. A fetch
      # carries no fragment definitions, so spell each spread as the inline
      # fragment it is: same condition, same directives, and the variables
      # inside it now reachable by used_variables.
      def inline_spreads(node, fragments, depth = 0)
        refuse(:too_deep, "this operation nests deeper than #{MAX_DEPTH} levels") if depth > MAX_DEPTH
        selections = node.respond_to?(:selections) ? node.selections : []
        return node if selections.empty?

        node.merge(selections: selections.map do |child|
          inline_spreads(spread_inline(child, fragments), fragments, depth + 1)
        end)
      end

      def spread_inline(node, fragments)
        return node unless node.is_a?(GraphQL::Language::Nodes::FragmentSpread)

        fragment = fragments[node.name] or
          refuse(:undefined_fragment, "the document spreads ...#{node.name}, which it never defines")
        GraphQL::Language::Nodes::InlineFragment.new(
          type: GraphQL::Language::Nodes::TypeName.new(name: fragment.type.name),
          directives: node.directives,
          selections: fragment.selections,
        )
      end

      # The field resolves in this subgraph but something under it doesn't.
      def descend(step, type_name, node, subgraph, field, fragments, depth)
        child = plan_child(type_name, node, subgraph, field, fragments, depth)

        step.selections << node.merge(selections: child.selections)
        step.children << [node.alias || node.name, child]
      end

      # The plan for what this field returns, run in `subgraph`.
      def plan_child(type_name, node, subgraph, field, fragments, depth)
        child_type = child_type_name(type_name, node.name)
        return plan_branches(type_name, node, child_type, subgraph, field, fragments, depth) if
          @schema.get_type(child_type)&.kind&.abstract?

        plan_step(child_type, narrow(child_type, node.selections, fragments), subgraph, fragments,
          provides(field), depth + 1)
      end

      # One plan per concrete type `subgraph` can answer this abstract type
      # with — the supergraph says which those are, and a fetch may only name
      # those: a subgraph rejects an `... on T` its own schema doesn't place
      # in the abstract type.
      def plan_branches(type_name, node, abstract_name, subgraph, field, fragments, depth)
        possible = @table.possible_types(abstract_name, subgraph)
        if possible.nil?
          refuse :abstract_boundary, "#{type_name}.#{node.name} returns #{abstract_name}, and " \
            "the supergraph doesn't record which concrete types #{subgraph} answers it with " \
            "(no @join__unionMember or @join__implements, and #{abstract_name} is in more than " \
            "one subgraph)"
        end
        if possible.empty?
          refuse :abstract_boundary, "#{type_name}.#{node.name} returns #{abstract_name}, and " \
            "the supergraph places none of its concrete types in #{subgraph}"
        end

        Branches.new(steps: possible.sort.to_h do |concrete|
          [concrete, plan_step(concrete, narrow(concrete, node.selections, fragments), subgraph,
            fragments, provides(field), depth + 1)]
        end)
      end

      # Refetch this object from its @key in the subgraph that resolves the
      # field, and read the field off the entity that comes back. `target`
      # is this subgraph when the field lives here but @requires fields it
      # doesn't hold — the router refetches for those too.
      def defer(step, type_name, node, subgraph, target, field, fragments, siblings, depth)
        key = usable_key(type_name, node, subgraph, target)
        requires = requires_paths(field)
        check_shadowing!(type_name, node, siblings, (key + requires).uniq)

        # a @requires field this subgraph doesn't hold is fetched from the
        # one that does and handed back in the representation — a fetch
        # before the fetch, which is what makes this a chain
        elsewhere = requires.reject { |path| path_owners(type_name, path).include?(subgraph) }
        prefetch(step, type_name, node, subgraph, elsewhere)

        ((key + requires).uniq - elsewhere).each { |path| inject(step, path) }

        child = plan_child(type_name, node, target, field, fragments, depth) if node.selections.any?

        step.deferrals << Deferral.new(
          node: child ? node.merge(selections: child.selections) : node,
          response_key: node.alias || node.name,
          subgraph: target,
          step: child || nil,
          key:, requires:,
        )
      end

      # One fetch per subgraph holding a @requires field this one doesn't,
      # ahead of the fetch that needs them. Only one hop: the key for each
      # has to come from `subgraph` itself, so a chain can't grow a chain.
      def prefetch(step, type_name, node, subgraph, paths)
        paths.each { |path| check_chain!(type_name, node, path) }

        paths.group_by { |path| requires_holder(type_name, node, path) }.each do |holder, held|
          key = usable_key(type_name, node, subgraph, holder)
          key.each { |path| inject(step, path) }
          step.prefetches << Prefetch.new(subgraph: holder, key:, paths: held, node:)
        end
      end

      # A prefetch sends the entity's own @key and nothing else, so a required
      # field that is itself @requires-ed gets computed from a representation
      # missing its input — silently, and the same field then holds two
      # different values in one response. Asked of every field a path walks
      # through, not only its first: nesting doesn't make a chain shallower.
      def check_chain!(type_name, node, path)
        walk(type_name, path).each do |owner, name|
          inner = @table.field(owner, name)&.requires or next

          refuse :chained_requires,
            "#{type_name}.#{node.name} @requires #{path.inspect}, and #{owner}.#{name} " \
              "itself @requires #{inner.inspect}"
        end
      end

      def requires_holder(type_name, node, path)
        owners = path_owners(type_name, path)
        return available!(owners, "#{type_name}.#{path}").first if owners.any?

        # two different facts, and only the second is about nesting: a field
        # the supergraph places nowhere, or one whose path it places in
        # subgraphs that don't overlap
        pairs = walk(type_name, path)
        orphan = pairs.find { |owner, name| @table.owners(owner, name).empty? }
        missing = pairs.empty? ? "#{type_name}.#{path}" : orphan&.join(".")
        refuse(:no_owner, "#{type_name}.#{node.name} @requires #{path.inspect}, and the " \
          "supergraph places #{missing} in no subgraph") if missing

        refuse :nested_field_set, "#{type_name}.#{node.name} @requires a nested field set " \
          "(#{field_set([path]).inspect}) no one subgraph holds whole (" +
          pairs.map { |owner, name| "#{owner}.#{name} in #{@table.owners(owner, name).join(" or ")}" }
            .join(", ") + ")"
      end

      def inject(step, path)
        step.keys << path unless step.keys.include?(path)
      end

      # A nested field set arrives as ONE object under one response key, so
      # every path sharing a root has to come from the same fetch: half of
      # `origin` from here and half from a prefetch leaves the object
      # half-built, and two prefetches overwrite each other's half.
      def check_one_source!(type_name, step, subgraph)
        sources = Hash.new { |roots, root| roots[root] = {} }
        step.keys.each { |path| sources[path.split(".").first][path] = subgraph }
        step.prefetches.each do |prefetch|
          prefetch.paths.each { |path| sources[path.split(".").first][path] = prefetch.subgraph }
        end

        sources.each do |root, from|
          next if from.values.uniq.one?

          refuse :nested_field_set, "#{type_name}'s #{root.inspect} is part of a field set this " \
            "fetch would have to build from more than one subgraph " \
            "(#{from.map { |path, graph| "#{path} from #{graph}" }.join(", ")})"
        end
      end

      # Apollo's router injects the @key under its own name and lets it win,
      # so `{ id: username }` next to a stitched field comes back as the
      # user's id. That is an Apollo bug and a spec-conformant server
      # disagrees — and since we can't match both, refuse rather than hand
      # back an answer one of them contradicts.
      def check_shadowing!(type_name, node, siblings, paths)
        # Apollo injects a field set under its own names, so what an alias
        # can collide with is each path's first segment — the field a flat
        # path is, or the object a nested one arrives in
        roots = paths.map { |path| path.split(".").first }.uniq
        shadowed = siblings.select do |sibling|
          sibling.alias && sibling.alias != sibling.name && roots.include?(sibling.alias)
        end
        return if shadowed.empty?

        refuse :shadowed_key,
          "#{type_name}.#{node.name} is fetched on #{type_name}'s #{roots.map(&:inspect).join(", ")}, " \
          "and this selection aliases " \
          "#{shadowed.map { |s| "#{s.name} as #{s.alias.inspect}" }.join(", ")} over it"
      end

      # A @key field set the source subgraph can build a representation
      # from — the first the supergraph declares that it can, nested or
      # flat. An @external copy counts: it exists precisely so this
      # subgraph can name the field in its @key.
      def usable_key(type_name, node, from, to)
        candidates = @table.keys(type_name, to)
        if candidates.empty?
          refuse :no_key,
            "#{type_name}.#{node.name} resolves in #{to}, and #{type_name} has no resolvable " \
            "@key there"
        end

        usable = candidates.find { |paths| paths.all? { |path| declares?(type_name, path, from) } }
        return usable if usable

        refuse :no_key, "#{type_name}.#{node.name} needs a fetch into #{to}, and #{from} can't " \
          "supply any of #{type_name}'s @keys there " \
          "(#{candidates.map { |paths| field_set(paths).inspect }.join(", ")})"
      end

      def requires_paths(field)
        return [] unless field&.requires

        GraphWeaver::SchemaLoader::RoutingTable.parse_field_set(field.requires)
      end

      # Dotted paths back to the selection set they were parsed from — the
      # inverse of RoutingTable.parse_field_set, so a refusal spells the
      # field set the way the schema does and is greppable against it.
      def field_set(paths) = render_field_set(Planner.field_tree(paths))

      def render_field_set(tree)
        tree.map { |name, children|
          children.empty? ? name : "#{name} { #{render_field_set(children)} }"
        }.join(" ")
      end

      # A @requires field set is supplied by the ROUTER: it fetches those
      # fields elsewhere and hands them back in the representation. So a
      # field is only answerable in place when its own subgraph already
      # holds every one of them — which, since @requires fields are
      # @external there, it essentially never does. When it doesn't, the
      # field is planned as a fetch chain instead (see prefetch).
      def held?(type_name, field, subgraph)
        return true unless field&.requires

        GraphWeaver::SchemaLoader::RoutingTable.parse_field_set(field.requires)
          .all? { |path| path_owners(type_name, path).include?(subgraph) }
      end

      # The subgraphs that can answer a field set path in ONE fetch: the
      # owners of every field it walks through, intersected. A representation
      # carries the nested object whole, so a path answerable only a level at
      # a time is answerable by nobody.
      def path_owners(type_name, path)
        pairs = walk(type_name, path)
        return [] if pairs.empty?

        pairs.map { |owner, name| @table.owners(owner, name) }.reduce(:&)
      end

      # Every [type, field] a dotted path names, from `type_name` down —
      # empty when the composed schema doesn't carry the whole walk.
      def walk(type_name, path)
        pairs = []
        path.split(".").each do |segment|
          return [] if type_name.nil?

          pairs << [type_name, segment]
          type_name = raw_child_type(type_name, segment)
        end
        pairs
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
        return false unless held?(type_name, field, subgraph)
        return true if node.selections.empty?

        child = raw_child_type(type_name, node.name) or return false
        local?(child, node.selections, subgraph, fragments, provides(field), depth + 1)
      end

      # Folding a same-type fragment into its parent drops the fragment node,
      # so whatever @skip/@include it carried has to move onto the selections
      # it guarded — otherwise a stitched plan answers a selection the
      # operation excluded, and fetches a subgraph to do it.
      def carry(node, expanded)
        return expanded if node.directives.empty?

        expanded.map do |field|
          clash = field.directives.map(&:name) & node.directives.map(&:name)
          if clash.any?
            # one selection can't hold two conditions of the same name
            refuse :conditional_fragment,
              "#{field.alias || field.name} carries @#{clash.first}, and so does the fragment " \
                "spread around it"
          end

          field.merge(directives: node.directives + field.directives)
        end
      end

      # A fragment's type condition has to exist in the subgraph running
      # it; a type only another subgraph declares can't be matched there.
      # Types the routing table says nothing about (scalars, enums) are
      # nobody's.
      def declared_in?(type_name, subgraph)
        declared = @table.declared_in(type_name)
        declared.empty? || declared.include?(subgraph)
      end

      # Whether `subgraph` can hand back this field set path as part of a
      # representation — every field it walks through, since a nested path
      # is selected there in one go. An @external copy counts, which is the
      # whole reason one is declared.
      def declares?(type_name, path, subgraph)
        pairs = walk(type_name, path)
        pairs.any? && pairs.all? { |owner, name| declares_field?(owner, name, subgraph) }
      end

      def declares_field?(type_name, field_name, subgraph)
        field = @table.field(type_name, field_name)
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

      # The subgraphs among `owners` this process actually serves. A
      # supergraph is routinely only partly local, so absence is refused
      # here — where the field that reached for it is still in hand —
      # rather than at construction, which would refuse the whole suite
      # over fields it may never touch.
      def available!(owners, coordinate)
        here = owners - @unserved
        return here if here.any?

        # ambiguity first: it's the one with a fix that isn't "stand the
        # service up", and the classes are right here to name
        unsettled = owners.find { |name| @ambiguous.key?(name) }
        ambiguous!(unsettled, coordinate) if unsettled

        absent = owners.map(&:inspect)
        refuse :absent_subgraph, "#{coordinate} resolves in #{absent.join(" or ")}, which no " \
          "schema here serves — nothing loaded defines what the supergraph says " \
          "#{absent.first} resolves. #{advice(absent.first)}"
      end

      # Which class serves this subgraph is a question only the caller can
      # answer — but it is only worth asking about the subgraphs a query
      # reaches, since which classes happen to be loaded is not a fact
      # about the query.
      def ambiguous!(name, coordinate)
        found = @ambiguous.fetch(name)
        raise GraphWeaver::ConfigurationError, "#{coordinate} resolves in #{name.inspect}, and " \
          "#{found.size} loaded schema classes define everything the supergraph says it " \
          "resolves (#{found.join(", ")}) — which of them serves it is a question only you can " \
          "answer. Pin it: subgraphs: { #{name.inspect} => #{found.first} } " \
          "(GraphWeaver::Testing.config.router = { subgraphs: … } under the rspec tag, or " \
          "subgraphs: on Router.new)."
      end

      # Two causes, and only one of them applies at a time. A class Rails
      # hasn't autoloaded yet is the usual one — but not when eager loading
      # is already on, and *that* the library can just ask, rather than
      # leading with a guess it can see is wrong. The other cause is a
      # subgraph that genuinely runs in another service, and its fix has to
      # come first for the reader it applies to. Either way the surface
      # named is the one an rspec example can reach: there is no Router.new
      # in sight from inside one.
      def advice(name)
        fake = "subgraphs: { #{name} => #{Subgraphs::FAKE.inspect} } " \
          "(GraphWeaver::Testing.config.router = { subgraphs: … } under the rspec tag, or " \
          "subgraphs: on Router.new) — or a schema class in place of #{Subgraphs::FAKE.inspect}"
        if eager_loaded?
          "Eager loading is on, so it isn't a class waiting to be autoloaded — it runs " \
            "elsewhere. Fabricate its answers: #{fake}."
        else
          "Rails autoloads, so the class is probably just not loaded yet: eager-load it " \
            "(config.eager_load, or config.rake_eager_load under rake). If it runs elsewhere, " \
            "fabricate its answers instead — #{fake}."
        end
      end

      # Whether the "not autoloaded yet" half of the advice is already ruled
      # out. Outside Rails there is no autoloading to blame either.
      # const_get rather than a bare Rails: sorbet can't resolve a constant
      # the gem doesn't depend on.
      def eager_loaded?
        return false unless Object.const_defined?(:Rails)

        config = Object.const_get(:Rails).application&.config or return false
        !!(config.eager_load ||
          (Object.const_defined?(:Rake) && config.respond_to?(:rake_eager_load) && config.rake_eager_load))
      rescue NoMethodError
        false # something else named Rails
      end

      def child_type_name(type_name, field_name)
        raw_child_type(type_name, field_name) ||
          refuse(:no_owner, "#{type_name}.#{field_name} is not a field of the composed schema")
      end

      def raw_child_type(type_name, field_name)
        type = @schema.get_type(type_name)
        return unless type.respond_to?(:fields)

        field = type.fields[field_name] or return
        field.type.unwrap.graphql_name
      end

      def refuse(category, message)
        raise Testing::Unplannable.new(message, category:)
      end
    end
  end
end
