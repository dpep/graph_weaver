# typed: true
# frozen_string_literal: true

require "graphql"
require "json"

require_relative "../parsing"
require_relative "../schema_loader"
require_relative "../selection"
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
        no_key: [
          "no @key to cross the boundary on",
          "an entity fetch sends a representation built from a @key; with none there's nothing to " \
            "send. Run this one against a real router.",
        ],
        abstract_boundary: [
          "an abstract type the supergraph doesn't break down",
          "the local router crosses an abstract boundary by bucketing objects on their " \
            "__typename, so it has to know which concrete types the subgraph can answer with — " \
            "and this supergraph doesn't say. Run this one against a real router.",
        ],
        interface_object: [
          "an @interfaceObject the routing table can't attribute",
          "one subgraph resolves a whole interface's implementations there, so the supergraph " \
            "doesn't say which subgraph answers each of its fields. Run this one against a real " \
            "router.",
        ],
        chained_requires: [
          "a @requires whose field set names another @requires field",
          "the router satisfies a @requires with one fetch, so it can't first satisfy that " \
            "field's own requirement. Run this one against a real router.",
        ],
        nested_field_set: [
          "a nested field set no one fetch can build",
          "a representation carries a nested field set as one object, so one fetch has to answer " \
            "the whole of it — and here every subgraph answers only part. Run this one against a " \
            "real router.",
        ],
        conditional_fragment: [
          "@skip/@include on both a fragment and its field",
          "one selection can't carry two conditions of the same name. Spell the condition once, " \
            "on the field or on the fragment.",
        ],
        shadowed_key: [
          "an alias shadowing an injected @key",
          "the local router injects the @key it crosses on under a reserved response key and " \
            "Apollo injects it under the field's own name, so either way this alias claims a key " \
            "the fetch needs. Rename the alias.",
        ],
        root_fields_span: [
          "a mutation's root fields span subgraphs",
          "root mutation fields run in series and the local router can't serialize across " \
            "subgraphs. Split it into one operation per subgraph, or run this one against a real router.",
        ],
        no_owner: [
          "the routing table names no subgraph",
          "nothing can route a field the supergraph doesn't place. Run this one against a real router.",
        ],
        absent_subgraph: [
          "a subgraph nothing here serves",
          "a query that never reaches an absent subgraph's fields still runs, so nothing else has " \
            "to change.",
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

      # Refuse a supergraph the routing table couldn't read whole. An unread
      # @join__ construct leaves the table incomplete, so every answer drawn
      # from it is a guess — including which schema serves which subgraph, so
      # this comes before resolving those. Router and Coverage both refuse at
      # construction, before any query, and say it the same way.
      def self.unsupported!(table)
        return if table.unsupported.empty?

        raise new(
          "this supergraph uses federation constructs the local router doesn't read: " +
            table.unsupported.join("; "),
          category: :unsupported_federation,
        )
      end

      def to_h = super.merge("category" => category.to_s, "detail" => detail)
    end

    # A federation router for tests: it satisfies the client contract, so
    # `GraphWeaver.client = router` runs every generated module against your
    # real subgraph resolvers, in-process — no gateway, no node, no sockets.
    #
    #      GraphWeaver::Testing::Router.new(
    #        supergraph: Rails.root.join("supergraph.graphql"),
    #        context: { current_user: user },
    #      )
    #
    # (`subgraphs:` is optional — see {Subgraphs}.)
    #
    # A supergraph only **partly** local — the rest of it served by other
    # processes — needs nothing extra: the subgraphs nobody here defines are
    # absent, the router builds and runs, and only a query that reaches an
    # absent subgraph's fields is refused, at plan time, naming it. Ask for
    # fabricated data instead with `subgraphs: { "reviews" => :fake }`; every
    # fetch that came from one is marked `faked: true` in #trace.
    #
    # It plans the shapes a router spends its life on: an operation that
    # resolves in one subgraph, handed over verbatim; one that crosses a
    # boundary — split at the crossing, refetched from the owning subgraph
    # through `_entities(representations:)`, and stitched back; a `@requires`
    # field set, fetched from the subgraph that holds it and handed back in
    # the representation; a nested `@key` or `@requires`, which crosses as
    # the object the SDL spells rather than as a flattened path; and a union
    # or interface at a boundary, planned per concrete type and bucketed on
    # the `__typename` the data comes back with.
    #
    # Everything it can't plan *faithfully* raises {Unplannable}, before any
    # subgraph runs, so a refusal can never be a half-executed query. Apollo's
    # planner is twenty thousand lines; a double that approximated the rest of
    # it would let a test pass on an answer production disagrees with, which is
    # the most expensive thing this library can produce.
    #
    # Introspection is answered from the composed API schema — never from a
    # subgraph, which would reply with its own slice. That is the one split a
    # real router also makes.
    #
    # #trace records the fetches made since the last #reset_trace, in order
    # (subgraph, query, variables); the same lines go to GraphWeaver.logger
    # at :debug. The rspec integration resets it per example; anywhere else,
    # reset it yourself around the code path you're measuring.
    class Router
      include GraphWeaver::Parsing

      # the schema the router serves — the supergraph with its composition
      # machinery stripped, exactly what a real router exposes
      attr_reader :schema

      # who resolves what (GraphWeaver::SchemaLoader::RoutingTable)
      attr_reader :table

      # every fetch made since the last {#reset_trace}, in order — so "which
      # subgraphs did this code path touch" is answerable for a service
      # object that runs more than one query
      attr_reader :trace

      # subgraphs no schema here serves: a query reaching their fields is
      # refused at plan time, everything else runs
      attr_reader :absent

      # subgraphs answered with fabricated data instead of that refusal
      attr_reader :faked

      # the context handed to every subgraph — settable, so one example can
      # run as a different user without rebuilding the router
      attr_accessor :context

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

      # one error in the shape a GraphQL response carries them — a class
      # method because the Planner refuses documents before a Router exists
      def self.graphql_error(message, code)
        { "message" => message, "extensions" => { "code" => code } }
      end

      # subgraphs: names the Ruby schema serving each subgraph. Omit it (or
      # any of its entries) and the rest are derived from what each loaded
      # schema defines — see {Subgraphs}, which also checks the ones you name.
      # A subgraph nothing serves is absent (refused per query, not here);
      # `"reviews" => :fake` fabricates its answers instead.
      # fake: how those fabricate — see {#fake=}.
      def initialize(supergraph:, subgraphs: nil, context: {}, fake: {})
        source = supergraph.to_s # a path, or the SDL itself — Pathname included
        @schema = GraphWeaver::SchemaLoader.load(source)
        @table = GraphWeaver::SchemaLoader.routing_table(source)
        @context = context
        @trace = []

        Unplannable.unsupported!(@table)

        served = Subgraphs.resolve(@table, subgraphs)
        @faked = served.select { |_name, schema| schema == Subgraphs::FAKE }.keys.freeze
        @absent = (@table.subgraphs - served.keys).freeze
        @subgraphs = served.reject { |_name, schema| schema == Subgraphs::FAKE }
        @built_fake = check_fake!(fake)
        @fake = @built_fake
        build_fakes
        @planner = Planner.new(table: @table, schema: @schema, absent: @absent)
      end

      # Drop the fetches recorded so far, so #trace answers about what runs
      # next. For counting fetches across part of a run — the whole example
      # boundary is #reset!.
      def reset_trace
        @trace = []
        self
      end

      # An example boundary. A router is built once and reused (the rspec tag
      # builds one per suite), so a faked subgraph would otherwise keep
      # fabricating from wherever the previous example left its sequence —
      # making the same example give different data alone than in a full run,
      # which is exactly what `rspec --seed` promises it won't.
      def reset!
        reset_trace
        @fake = @built_fake
        build_fakes
        self
      end

      # How faked subgraphs fabricate, for the example in hand: the options
      # {FakeClient} takes (overrides:, list_size:, null_chance:, values:,
      # seed:), merged onto the ones the router was built with. A router is
      # built once for the suite, so this is how one example pins the data a
      # faked subgraph answers with; {#reset!} puts it back.
      def fake=(options)
        @fake = check_fake!(@built_fake.merge(options.to_h))
        build_fakes
      end

      # the options every faked subgraph is currently fabricating with
      attr_reader :fake

      def execute(query, variables: {}, operation_name: nil)
        document = begin
          GraphQL.parse(query)
        rescue GraphQL::ParseError => e
          return { "data" => nil, "errors" => [Router.graphql_error(e.message, "GRAPHQL_PARSE_FAILED")] }
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
      def inspect
        parts = ["subgraphs=#{(@subgraphs.keys - @faked).inspect}"]
        parts << "faked=#{@faked.inspect}" if @faked.any?
        parts << "absent=#{@absent.inspect}" if @absent.any?
        "#<#{self.class.name} #{parts.join(" ")}>"
      end
      alias to_s inspect

      private

      def build_fakes
        @faked.each { |name| @subgraphs[name] = FakeSubgraph.new(name, @schema, **@fake) }
      end

      # Options nothing fabricates with pin nothing and leave the example
      # green — the same silent pass a typo'd override key is refused for.
      def check_fake!(options)
        options = options.to_h
        return options.freeze if options.empty? || @faked.any?

        raise GraphWeaver::ConfigurationError, "fake: says how faked subgraphs fabricate, and this " \
          "router fakes none — ask for one with subgraphs: { \"#{@table.subgraphs.first}\" => " \
          "#{Subgraphs::FAKE.inspect} }"
      end

      # __schema / __type describe the COMPOSED graph; a subgraph would
      # answer with its own slice
      def introspect(query, variables, operation_name)
        @schema.execute(query, variables: variables.to_h, operation_name:).to_h
      end

      # ---- execution ----------------------------------------------------

      def run(plan, variables)
        errors = []
        data = {}
        # An operation's declared defaults are part of the variables, and
        # graphql-ruby applies them — so @skip/@include has to see them too,
        # or a field the caller never opted out of goes missing.
        given = variable_defaults(plan.operation)
          .merge(variables.to_h { |name, value| [name.to_s, value] })

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

      # Only for evaluating @skip/@include, which read Booleans — so only the
      # scalar defaults the parser hands back as Ruby values are wanted. An
      # enum or input-object default is an AST node; sending one to a subgraph
      # puts a parser back-pointer on the wire, or raises inside JSON. The
      # subgraph applies those itself: used_variables copies each declaration
      # verbatim, defaults and all.
      def variable_defaults(operation)
        operation.variables.each_with_object({}) do |definition, defaults|
          value = definition.default_value
          next unless value == true || value == false

          defaults[definition.name] = value
        end
      end

      # @skip/@include against the variables in hand, defaults included. A
      # variable with neither reads as absent, which excludes under @include
      # and includes under @skip — the same way graphql-ruby resolves it.
      def included?(node, variables)
        node.directives.all? do |directive|
          next true unless GraphWeaver::Selection::CONDITIONAL_DIRECTIVES.include?(directive.name)

          argument = directive.arguments.find { |arg| arg.name == "if" } or next true
          value = argument.value
          value = variables[value.name] if value.is_a?(GraphQL::Language::Nodes::VariableIdentifier)

          directive.name == "skip" ? !value : !value.nil? && value != false
        end
      end

      # Everything the plan applies at this level: one _entities fetch per
      # subgraph the level defers to (all nodes at once — _entities answers
      # in representation order), then the same again one level down.
      def stitch(step, nodes, operation, variables, errors)
        return if nodes.empty?

        # An abstract position: the plan holds one branch per concrete type
        # the subgraph can answer with, and only the data says which applies.
        # So bucket on the __typename that came back — each bucket then
        # crosses on its own type's @key, which is what a representation
        # needs and what the planner could not have known.
        if step.is_a?(Planner::Branches)
          step.steps.each do |type_name, branch|
            stitch(branch, nodes.select { |(node, _)| node[TYPENAME] == type_name },
              operation, variables, errors)
          end
          return
        end

        blocked = prefetch(step, nodes, operation, variables, errors)

        # A fetch for a selection the operation excluded is a fetch a real
        # router never makes, and `trace` is something specs assert on. The
        # plan is built once and reused, so only here are the variables known.
        wanted = step.deferrals.select { |d| included?(d.node, variables) }

        # a @requires fetch and a plain one need different node sets, so they
        # can't share a call even into the same subgraph — which is the split
        # a real router makes too
        wanted.group_by { |d| [d.subgraph, d.requires.any?] }.each do |(target, chained), deferrals|
          fetched = chained ? nodes.reject { |(node, _)| blocked.include?(node.object_id) } : nodes
          tree = Router.field_tree(deferrals.flat_map(&:representation).uniq)
          representations = fetched.map { |(node, _)| representation(node, tree, step.type_name) }

          entities = []
          if fetched.any?
            result = entities_fetch(target, step.type_name, deferrals.map(&:node), representations, operation, variables)
            entities = result.dig("data", "_entities") || []
            Array(result["errors"]).each { |error| errors << rewrite(error, fetched) }
          end

          fetched.each_with_index do |(node, _), index|
            entity = entities[index]
            deferrals.each do |deferral|
              # @skip/@include leave a key ABSENT rather than null, and
              # copying a null would invent one the router never emits
              next if entity && !entity.key?(deferral.response_key)

              node[deferral.response_key] = entity && entity[deferral.response_key]
            end
          end

          # nothing supplied its @requires, so nothing can resolve the field
          (nodes - fetched).each do |(node, _)|
            deferrals.each { |deferral| node[deferral.response_key] = nil }
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

      # The @requires fields the router has to hand back, fetched into hidden
      # keys before the fetch whose representation carries them. Returns the
      # nodes the holding subgraph didn't recognize: their required fields
      # don't exist, so nothing depending on them can resolve.
      def prefetch(step, nodes, operation, variables, errors)
        blocked = []
        step.prefetches.each do |prefetch|
          # the field it feeds was excluded, so this is a fetch a real router
          # never makes — and a test double that runs a resolver production
          # wouldn't is answering a different question
          next unless included?(prefetch.node, variables)

          key = Router.field_tree(prefetch.key)
          representations = nodes.map { |(node, _)| representation(node, key, step.type_name) }
          selections = Router.injected_selections(prefetch.paths)
          roots = selections.map(&:alias)

          result = entities_fetch(prefetch.subgraph, step.type_name, selections, representations, operation, variables)
          entities = result.dig("data", "_entities") || []
          Array(result["errors"]).each { |error| errors << rewrite(error, nodes) }

          nodes.each_with_index do |(node, _), index|
            entity = entities[index]
            blocked << node.object_id if entity.nil?
            roots.each { |root| node[root] = entity && entity[root] }
          end
        end
        blocked
      end

      # The representation an entity fetch sends for one object: every path
      # the field set names, read back out of the response key its injected
      # selection landed under. Pruned to that field set — one selection can
      # carry two deferrals' fields, and a representation holding fields the
      # @key doesn't name isn't the one a router sends.
      def representation(node, tree, type_name)
        tree.to_h { |root, children| [root, prune(node[PREFIX + root], children)] }
          .merge("__typename" => type_name)
      end

      # a null object contributes a null rather than dropping the field, which
      # is the representation a real gateway sends for one too
      def prune(value, tree)
        return value if tree.empty?

        case value
        when Array then value.map { |item| prune(item, tree) }
        when Hash then tree.to_h { |name, children| [name, prune(value[name], children)] }
        end
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
        step.injected.each { |key| node.delete(key) }
      end

      # A subgraph reports where the failure was in the query IT ran, and a
      # stitched plan runs queries the caller never wrote: `_entities.<i>.…`
      # is a path into the fetch, and `locations` a position in it. Re-path
      # what can be re-pathed and drop what can't, rather than hand back a
      # line number pointing into a document that doesn't exist.
      def rewrite(error, nodes = nil)
        path = error["path"]
        return error.except("locations") unless path.is_a?(Array)

        stitched = nodes && path.first == "_entities"
        prefix = stitched ? (nodes.dig(path[1], 1) || []) : []
        error.except("locations").merge("path" => prefix + unalias(stitched ? path[2..] : path))
      end

      # The @key/@requires fields we inject are ours; an error path naming one
      # points the caller at a field no schema has.
      def unalias(path)
        Array(path).map { |segment| segment.is_a?(String) ? segment.delete_prefix(PREFIX) : segment }
      end

      def fetch_step(step, operation, variables)
        document = GraphQL::Language::Nodes::OperationDefinition.new(
          operation_type: operation.operation_type || "query",
          variables: used_variables(step.selections, operation),
          selections: step.selections,
        )
        run_subgraph(step.subgraph, document, variables)
      end

      def entities_fetch(subgraph, type_name, nodes, representations, operation, variables)
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
        faked = @faked.include?(name)
        entry = { subgraph: name, query:, variables: variables.to_h }
        entry[:faked] = true if faked
        @trace << entry
        tag = GraphWeaver.logger && GraphWeaver::Transport.log_tag(operation_name)

        # a fabricated answer that passes silently is worse than a failing
        # one, so it says so every fetch rather than once at construction
        if faked
          GraphWeaver.log(:warn) { "router -> #{name} #{tag} FAKED: fabricated data, not #{name}'s" }
        end

        GraphWeaver.log(:debug) do
          "router -> #{name} #{tag} variables=#{JSON.generate(variables)}\n" \
            "#{GraphWeaver::Transport.truncate_for_log(query)}"
        end

        GraphWeaver.log_timed(:debug, "router -> #{name} #{tag} completed") do
          @subgraphs.fetch(name).execute(query, variables:, operation_name:, context: @context).to_h
        end
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
          # which selections apply here is a fact about the data: the same
          # __typename the fetch bucketed by says what this object is. Without
          # one the subtree ran whole in one subgraph, which already applied
          # its own propagation — there is nothing to redo.
          # get_type, not types[]: the latter merges every type through a
          # visibility filter into a fresh hash, and this runs once per
          # response row — so it would cost rows x schema size
          concrete = value.is_a?(Hash) ? @schema.get_type(value[TYPENAME] || value["__typename"]) : nil
          return value unless concrete&.kind&.fields?

          propagate_object(value, concrete, @planner.narrow(concrete.graphql_name, selections, fragments), fragments)
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
        # an injected key is the router's own bookkeeping, never the caller's
        value.each { |key, held| ordered[key] = held unless ordered.key?(key) || key.start_with?(PREFIX) }

        selections.each do |node|
          next if node.name.start_with?("__")

          key = node.alias || node.name
          next unless ordered.key?(key)

          field = type.fields[node.name] or next
          child = field.type.unwrap
          # an abstract position picks its selections per object, from the
          # __typename in the data — nothing can inline them for a type yet
          sub =
            if node.selections.empty? then []
            elsif child.kind.abstract? then node.selections
            else @planner.narrow(child.graphql_name, node.selections, fragments)
            end
          result = propagate(ordered[key], field.type, sub, fragments)
          return if result.equal?(BUBBLE)

          ordered[key] = result
        end
        ordered
      end

      # Decides which subgraph answers what — and, where an operation crosses
      # a boundary, the tree of fetches that answers it. Separate from the
      # Router because deciding needs only the supergraph: `rake
      # graph_weaver:federation:coverage` measures how much of a query set is
      # plannable without any subgraph being runnable.
      class Planner
        # One subgraph fetch. `selections` go over as written; `keys` names the
        # @key/@requires paths this fetch also asks for, to carry entities
        # across a boundary, and `injected` the response keys those land under
        # (Router::PREFIX + the path's first segment — a nested field set
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
          name: "__typename", field_alias: Router::TYPENAME,
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

        # absent: subgraphs no schema serves here. Planning is otherwise
        # unchanged — coverage plans with none of them loaded, which is why
        # absence is a fact about this process rather than about the graph.
        def initialize(table:, schema:, absent: [])
          @table = table
          @schema = schema
          @absent = absent
          @interface_objects = table.interface_objects
        end

        # the operation's validation errors, GraphQL-wire shaped
        def validate(document)
          @schema.validate(document)
            .map { |error| Router.graphql_error(error.message, "GRAPHQL_VALIDATION_FAILED") }
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
          (shared - @absent).find { |subgraph| local?(root, selections, subgraph, fragments, []) }
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
          here.selections.concat(Router.injected_selections(here.keys))
          here.injected = (here.keys + here.prefetches.flat_map(&:paths))
            .map { |path| Router::PREFIX + path.split(".").first }.uniq
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
        def field_set(paths) = render_field_set(Router.field_tree(paths))

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
          here = owners - @absent
          return here if here.any?

          absent = owners.map(&:inspect)
          refuse :absent_subgraph, "#{coordinate} resolves in #{absent.join(" or ")}, which no " \
            "schema here serves — nothing loaded defines what the supergraph says " \
            "#{absent.first} resolves. #{advice(absent.first)}"
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
          raise Unplannable.new(message, category:)
        end
      end
    end
  end
end
