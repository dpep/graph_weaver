# typed: true
# frozen_string_literal: true

require "graphql"
require "json"

require_relative "../parsing"
require_relative "../schema_loader"
require_relative "../internal/selection"
require_relative "../internal"
require_relative "../transport"
require_relative "../internal/planner"
require_relative "../internal/subgraphs"

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
        context_argument: [
          "a @fromContext argument no fetch here can supply",
          "federation 2.8's @context/@fromContext fills the argument from a selection on an " \
            "ancestor, and only the gateway that planned the fetch knows what to put there. Run " \
            "this one against a real router.",
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
    # (`subgraphs:` is optional — they're derived from what each loaded
    # schema defines.)
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

      # subgraphs several loaded schema classes fit equally, so detection
      # can't say which serves them — refused per query like an absent one,
      # and the refusal lists the candidates
      def ambiguous = @ambiguous.keys

      # subgraphs answered with fabricated data instead of that refusal
      attr_reader :faked

      # The context handed to every subgraph — settable, so one example can
      # run as a different user without rebuilding the router. A proc is
      # answered from the request's headers, which only a wire supplies:
      # `context: ->(headers) { { current_user: User.find_by(token:
      # headers["Authorization"]) } }` served through {Endpoint}.
      attr_accessor :context

      # The planner injects key fields under this prefix, and the concrete
      # __typename under that key; reading an answer back means stripping
      # both, so the two sides share one definition.
      PREFIX = Internal::Planner::PREFIX
      TYPENAME = Internal::Planner::TYPENAME
      private_constant :PREFIX, :TYPENAME

      # subgraphs: names the Ruby schema serving each subgraph. Omit it (or
      # any of its entries) and the rest are derived from what each loaded
      # schema defines — see {Internal::Subgraphs}, which also checks the ones you name.
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

        resolution = Internal::Subgraphs.resolve(@table, subgraphs)
        served = resolution.served
        @ambiguous = resolution.ambiguous.freeze
        @faked = served.select { |_name, schema| schema == Internal::Subgraphs::FAKE }.keys.freeze
        @absent = (@table.subgraphs - served.keys - @ambiguous.keys).freeze
        @subgraphs = served.reject { |_name, schema| schema == Internal::Subgraphs::FAKE }
        @built_fake = check_fake!(fake)
        @fake = @built_fake
        build_fakes
        @planner = Internal::Planner.new(table: @table, schema: @schema, absent: @absent, ambiguous: @ambiguous)
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

      # How faked subgraphs fabricate, for the example in hand: the pins and
      # options {FakeClient} takes, in one hash (`"Shipment.carrier" => "UPS",
      # list_size: 2`), merged onto the ones the router was built with. A router is
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
          return { "data" => nil, "errors" => [Internal::Wire.graphql_error(e.message, "GRAPHQL_PARSE_FAILED")] }
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
        parts << "ambiguous=#{ambiguous.inspect}" if @ambiguous.any?
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
        # rspec's --seed already drives the fake, and a router is built once
        # for the suite — a seed here would pin every example to one run
        if options.key?(:seed) || options.key?("seed")
          raise GraphWeaver::ConfigurationError, "seed: isn't a fake: option — `rspec --seed 1234` " \
            "reproduces a run, and GraphWeaver::Testing.config.seed sets one for a harness that isn't rspec"
        end
        return options.freeze if options.empty? || @faked.any?

        raise GraphWeaver::ConfigurationError, "fake: says how faked subgraphs fabricate, and this " \
          "router fakes none — ask for one with subgraphs: { \"#{@table.subgraphs.first}\" => " \
          "#{Internal::Subgraphs::FAKE.inspect} }"
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
          next true unless GraphWeaver::Internal::Selection::CONDITIONAL_DIRECTIVES.include?(directive.name)

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
        if step.is_a?(Internal::Planner::Branches)
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
          tree = Internal::Planner.field_tree(deferrals.flat_map(&:representation).uniq)
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
        # the field it feeds was excluded, so this is a fetch a real router
        # never makes — and a test double that runs a resolver production
        # wouldn't is answering a different question
        wanted = step.prefetches.select { |prefetch| included?(prefetch.node, variables) }

        # two @requires field sets that cross into the same subgraph on the
        # same @key ride one entity fetch, as Apollo's do — the representations
        # are identical, so a second call would only re-run resolvers
        wanted.group_by { |prefetch| [prefetch.subgraph, prefetch.key] }.each do |(subgraph, keys), group|
          key = Internal::Planner.field_tree(keys)
          representations = nodes.map { |(node, _)| representation(node, key, step.type_name) }
          selections = Internal::Planner.injected_selections(group.flat_map(&:paths).uniq)
          roots = selections.map(&:alias)

          result = entities_fetch(subgraph, step.type_name, selections, representations, operation, variables)
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
      private_constant :REPRESENTATIONS, :REPRESENTATIONS_DEFINITION

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
        tag = GraphWeaver.logger && GraphWeaver::Internal::Wire.log_tag(operation_name)

        # a fabricated answer that passes silently is worse than a failing
        # one, so it says so every fetch rather than once at construction
        if faked
          GraphWeaver::Internal::Log.log(:warn) { "router -> #{name} #{tag} FAKED: fabricated data, not #{name}'s" }
        end

        GraphWeaver::Internal::Log.log(:debug) do
          "router -> #{name} #{tag} variables=#{JSON.generate(GraphWeaver::Internal::Log.filter_variables(variables))}
" \
            "#{GraphWeaver::Internal::Wire.truncate_for_log(query)}"
        end

        GraphWeaver::Internal::Log.log_timed(:debug, "router -> #{name} #{tag} completed") do
          @subgraphs.fetch(name).execute(query, variables:, operation_name:,
            context: Internal::Util.context!(@context)).to_h
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

    end
  end
end
