# typed: true
# frozen_string_literal: true

require_relative "../graph_weaver"

# faker is optional — semantic values (name/email/age/price/...) when
# present, type-based values when not
begin
  require "faker"
rescue LoadError
  # fall back to type-based generation
end

# Opt-in test tooling: require "graph_weaver/testing" from your spec
# helper (never from production code). Nothing here needs configuring —
# what a mode runs against is derived (see CLIENT_MODES). Configure to
# override a derivation, or to tune fabricated values:
#
#      GraphWeaver::Testing.configure do |config|
#        config.schema = MySchema                  # overrides the derived schema
#        config.router = { subgraphs: { "reviews" => :fake } }  # or supergraph:,
#                                                  # when it isn't the dump, or
#                                                  # fake: for how those fabricate
#        config.context = { current_user: }        # baseline GraphQL context
#        config.default_mode = :fake               # untagged examples; :live (the
#                                                  # default) leaves your client alone
#        config.seed = 42                          # reproducible fakes
#        config.overrides = { "Person.name" => "Daniel" }
#        config.list_size = 2..4
#        config.cassette_dir = "spec/cassettes"
#      end
#
# Anything whose honest answer differs per example belongs on the fake, not
# here: graphql_fake(null_chance: 1.0) for the empty-state example,
# graphql_fake(values: :literal) for the one that reads better without
# faker's prose, and overrides:/list_size: to say what one example's data is.
#
# rspec users: require "graph_weaver/rspec" instead — it hooks the suite
# (seed from rspec, a client per example from its `graphql:` tag).
module GraphWeaver
  module Testing
    # How a fake writes its values, named by the `values:` a fake takes —
    # graphql_fake(values: :literal), FakeClient.new(values:):
    #
    #      :faker   semantic, matched on the field name (needs the faker gem)
    #      :literal plain type-derived values ("name-1", seeded numbers)
    #      nil      auto: :faker when the gem is loaded, else :literal
    VALUE_STYLES = %i[faker literal].freeze

    # What an example can run against, named by the rspec tag that selects
    # it — `it "…", graphql: :in_process` (see graph_weaver/rspec):
    #
    #      :live        your app's own client, exactly as it is — the
    #                   default, and how one example steps back out of
    #                   config.default_mode
    #      :fake        fabricated, schema-correct data; no resolvers run
    #      :in_process  your resolvers, one live schema class, in-process
    #      :router      your resolvers, across a federated graph
    #      :wire        your schema, served at your client's endpoint so
    #                   your real transport runs
    CLIENT_MODES = %i[live fake in_process router wire].freeze

    class Config
      # How long an unbounded list fabricates when nothing names it — the
      # starting #list_size, and the fallback under a Hash one with no
      # `default:`.
      DEFAULT_LIST_SIZE = (1..3).freeze

      attr_accessor :overrides, :seed, :list_size, :cassette_dir, :record, :anonymize
      attr_reader :context
      # #schema is read with a fallback (below), the way #router and
      # #default_mode are read plainly and written with a check
      attr_reader :router, :default_mode

      def initialize
        @overrides = {}
        @seed = nil
        @list_size = DEFAULT_LIST_SIZE
        @schema = nil
        @located = nil # the committed dump, once located
        @located_path = nil # and the path it was located at
        # not under spec/fixtures: `fixtures :all` globs that path for
        # `{**,*}/*.yml` and would try to load cassettes as ActiveRecord
        # fixtures, a subdirectory included
        @cassette_dir = "spec/cassettes"
        # what an example with no `graphql:` tag runs against. :live leaves
        # GraphWeaver.client alone: swapping every example onto something
        # else is too surprising to be a default.
        @default_mode = :live
        # the GraphQL context every :in_process / :router example starts
        # from; graphql_context merges onto it
        @context = {}
        # Router arguments, when the composed supergraph isn't the
        # conventional dump — { supergraph:, subgraphs: }, subgraphs optional
        @router = nil
        # GRAPHWEAVER_RECORD=1 rspec ...  -> Testing.cassette re-records
        @record = !ENV["GRAPHWEAVER_RECORD"].to_s.empty?
        # anonymize responses as they're recorded (needs config.schema)
        @anonymize = false
      end

      # the explicitly configured schema, else the conventional dump
      # (SchemaLoader.locate at GraphWeaver.schema_path) — nil when
      # neither exists
      def schema
        # the dump memoizes separately: explicit_schema has to stay honest
        # about whether anyone set one, since :in_process won't run a dump's
        # resolver-less types as if they were the live class
        return @schema if @schema

        # keyed on the path it came from, so schema_path= and root= aren't
        # invisible — a memo that outlived them faked the previous schema's
        # shapes with nothing said. Worth keeping: loading a real
        # introspection dump is ~100ms and every fake asks.
        path = GraphWeaver::SchemaLoader.locate_path
        return unless path

        @located = GraphWeaver::SchemaLoader.load(path) unless @located_path == path
        @located_path = path
        @located
      end

      # What every mode derives from — suite setup, like #context and for the
      # same reason: an example's clients are built before any group `before`
      # runs, so one set there is read too late (see {refuse_late!}).
      def schema=(schema)
        refuse_late!("config.schema", "graphql_in_process(MySchema) / graphql_fake(schema: MySchema)")
        @schema = schema
      end

      # What's been set, without falling back to the dump — so validating
      # overrides at configure time doesn't force a schema load on a suite
      # that never asks for one.
      def explicit_schema = @schema

      # The baseline every example starts from — suite setup, not something an
      # example changes out from under itself: an example's clients are built
      # before any group hook runs (a :wire example's, before its endpoints
      # are stubbed), so a `before { config.context = … }` used to be read too
      # late and silently never reach a resolver.
      def context=(values)
        if GraphWeaver::Internal::TestClients.installed?
          raise GraphWeaver::Error, "config.context is the baseline every example starts from, " \
            "read when that example's clients are built — so setting it from inside an example " \
            "would never reach a resolver. Say it for this example with " \
            "graphql_context(current_user: …), or for the suite in GraphWeaver::Testing.configure " \
            "(an around hook works too — it wraps the setup a tag does)."
        end

        @context = values
      end

      def default_mode=(mode)
        unless CLIENT_MODES.include?(mode)
          raise ArgumentError,
            "default_mode: must be one of #{CLIENT_MODES.inspect}, got #{mode.inspect} — " \
            ":live leaves GraphWeaver.client exactly as it is, and is the default"
        end

        @default_mode = mode
      end

      # Router arguments — every key optional, and each answers a different
      # question. `supergraph:` is for one derivation can't find; without it
      # the conventional dump is used, when that dump is itself a supergraph.
      # `subgraphs:` is for what derivation can't settle, or for `"reviews"
      # => :fake`, which fabricates a subgraph this process doesn't serve —
      # the commonest reason to configure a router at all, and no reason to
      # have to restate where the supergraph is. `fake:` says how those
      # fabricate; graphql_router(fake: …) says it for one example.
      def router=(arguments)
        refuse_late!("config.router", "graphql_router(fake: …)")
        unless arguments.nil? || arguments.is_a?(Hash)
          raise ArgumentError, "router: must be the arguments to build one, e.g. " \
            "{ supergraph: \"supergraph.graphql\" } or { subgraphs: { \"reviews\" => :fake } }, " \
            "got #{arguments.inspect}"
        end
        if arguments&.key?(:context)
          # the rspec hook resets the router's context from config.context
          # every example, so one set here would silently never be read
          raise ArgumentError, "router: context: is set as config.context — the baseline every " \
            ":in_process and :router example starts from"
        end
        unknown = (arguments&.keys || []) - %i[supergraph subgraphs fake]
        raise ArgumentError, "router: doesn't take #{unknown.join(", ")}" if unknown.any?

        @router = arguments
        @built_routers = nil
      end

      # The router `graph` plans against, built once per supergraph: parsing
      # one is setup, not per-example work, and two graphs naming the same
      # supergraph are one plan. #context is settable, so an example that runs
      # as someone else sets that rather than rebuilding.
      def built_router(graph = nil)
        source = supergraph!(graph)
        @built_routers ||= {}
        @built_routers[source] ||= Router.new(
          supergraph: source,
          subgraphs: @router && @router[:subgraphs],
          fake: (@router && @router[:fake]) || {},
        )
      end

      # Whether `graph` has a composed supergraph to plan against — what
      # decides whether :wire serves the router or the live schema class,
      # the same question :router and :in_process each answer for themselves.
      def supergraph?(graph = nil) = !supergraph_for(graph).nil?

      # The composed supergraph `graph` plans against, or the refusal saying
      # what was looked for. Per graph, because a graph that is in no
      # supergraph must be refused by name rather than routed into someone
      # else's.
      private def supergraph!(graph = nil)
        supergraph_for(graph) ||
          raise(GraphWeaver::Error, supergraph_advice(graph, GraphWeaver::SchemaLoader.locate_path))
      end

      # The lookup on its own, nil when there is none — so asking the
      # question doesn't build an error. Every GraphWeaver::Error writes a
      # warn line as it is constructed, and a predicate that raised to say
      # "no" put a refusal that never happened in the log of every :wire
      # example. The one that graph names, else config.router[:supergraph],
      # else the conventional dump when that's what it is, else the dump the
      # app's own client was built from. A client's *schema* can't supply one
      # — it is the API schema a router serves, with the @join__* routing
      # table stripped out — but the file behind it carries the table.
      private def supergraph_for(graph)
        # named_schema?, so a graph that declared no schema of its own falls
        # through to config.router rather than past it to the conventional dump
        named = (graph.supergraph if graph&.named_schema?)
        return named if named
        return @router[:supergraph] if @router&.key?(:supergraph)

        path = GraphWeaver::SchemaLoader.locate_path
        return path if path && GraphWeaver::Internal::Util.composed?(path)

        # Last, because codegen for the default graph reads the conventional
        # dump, and the router must plan against what the modules were typed
        # against.
        client = GraphWeaver.client
        source = client.schema_source if client.respond_to?(:schema_source)
        source if source && GraphWeaver::Internal::Util.composed?(source)
      end

      # what to do about it, which differs by who asked: a graph in no
      # supergraph is one schema, so the tag for one schema is the answer;
      # the app-wide ask is told the two app-wide places to name one
      private def supergraph_advice(graph, path)
        if graph&.name
          ":router plans a query across a composed supergraph, and graph #{graph.name.inspect} " \
            "is in none — tag the example graphql: :in_process, which runs one schema class's " \
            "resolvers, or name the supergraph where the graph is declared: " \
            "GraphWeaver.graph(#{graph.name.inspect}) { schema \"supergraph.graphql\" }."
        else
          ":router needs the composed supergraph SDL — a client's schema is the API schema the " \
            "router serves, with the @join__* routing table stripped out, so the supergraph has " \
            "to be named. #{path ? "#{path} carries no @join__* markers" : "Nothing on disk at #{GraphWeaver.schema_path}"}. " \
            "Set GraphWeaver::Testing.config.router = { supergraph: \"supergraph.graphql\" }, or " \
            "name it where the graph is declared: GraphWeaver.graph(:api) { schema \"supergraph.graphql\" }."
        end
      end

      # The live schema class :in_process runs when the example didn't name
      # one — config.schema if that is a class, else the one `graph` names,
      # else whatever the app's own client already runs in-process. Only a
      # live class has resolvers, so there is nothing else to fall back to:
      # a dump is type information.
      def schema_class!(graph = nil)
        # a named graph is told how to name its own class; the app-wide answer
        # is told the two app-wide ways to say it
        schema_class_for(graph) || raise(GraphWeaver::Error, ":in_process runs your resolvers, " \
          "so it needs the live GraphQL::Schema class — and #{schema_class_advice(graph)}")
      end

      # Whether `graph` has a live schema class at all — what decides, with
      # #supergraph?, which of the three things :wire serves. Asked without
      # building an error, for the reason {supergraph_for} gives.
      def schema_class?(graph = nil) = !schema_class_for(graph).nil?

      # The schema everything else derives from: the one you set, else the one
      # `graph` names — the schema its generated code was checked against —
      # else the one this app's single graph names, else the committed dump,
      # else the schema the app's client talks to.
      def reference_schema!(graph = nil)
        return explicit_schema if explicit_schema
        return graph.schema if graph&.named_schema?

        declared = GraphWeaver.graphs
        # more than one graph and nothing named: the honest answer varies per
        # example, and picking the first would fake one schema's shapes at
        # another's module — a wrong answer that looks authoritative
        if declared.size > 1
          raise GraphWeaver::Error, "this app has #{declared.size} graphs " \
            "(#{declared.map { |graph| graph.name.inspect }.join(", ")}), so which schema to fake " \
            "against varies per example — name it: graphql_fake(schema: MySchema) or " \
            "graphql_in_process(MySchema). Set GraphWeaver::Testing.config.schema only if the whole " \
            "suite means one of them."
        end

        found = (declared.first.schema if declared.first.named_schema?)
        found ||= schema || (GraphWeaver.client.schema if GraphWeaver.client.respond_to?(:schema))
        return found if found

        raise GraphWeaver::Error, "no schema to run against — GraphWeaver.client isn't set, " \
          "there's no schema dump at #{GraphWeaver.schema_path}, and " \
          "GraphWeaver::Testing.config.schema is unset. Set any one of them."
      end

      private

      # explicit_schema, not schema: the latter falls back to the committed
      # dump, which loads as an anonymous GraphQL::Schema subclass — runnable
      # by every test that matters, and holding not one resolver.
      def schema_class_for(graph)
        runnable(explicit_schema) || graph&.live_schema || GraphWeaver::Internal::Util.live_schema
      end

      # One rule for every suite-setup setting: say it at load, or in an
      # `around` — a plain `before` is too late, because the tag builds (and
      # under :wire serves) this example's clients in a `before` of its own,
      # and rspec runs that one first. Silence there is the expensive
      # outcome: the example passes against whatever the tag already picked.
      def refuse_late!(setting, per_example)
        return unless GraphWeaver::Internal::TestClients.built?

        raise GraphWeaver::Error, "#{setting} is read when this example's clients are built, and " \
          "the graphql: tag already built them — it does that in a `before` hook of its own, which " \
          "rspec runs before yours, so setting it now reaches nothing. Say it for the suite in " \
          "GraphWeaver::Testing.configure, or in an `around` hook, which wraps the tag's setup; " \
          "say it for one example in the helper (#{per_example})."
      end

      # what to do about it, which differs by who asked: a graph names its
      # own class where it is declared, the app names one for the suite
      def schema_class_advice(graph)
        if graph&.name
          "graph #{graph.name.inspect} names " \
            "#{graph.named_schema? ? "type information, not a class" : "no schema of its own"}. " \
            "Declare it with the class: GraphWeaver.graph(#{graph.name.inspect}) " \
            "{ schema -> { MySchema } }."
        else
          "GraphWeaver.client isn't running one in-process to borrow. Name it in the example — " \
            "graphql_in_process(MySchema) — or set GraphWeaver::Testing.config.schema = MySchema " \
            "for the whole suite. A federated app names the subgraph it means, per example; " \
            "graphql: :router runs the graph stitched."
        end
      end

      # config.schema doubles as the :in_process class when it is one — but a
      # dump has no resolvers, so it can only ever be type information.
      def runnable(schema)
        schema if schema.is_a?(Class) && schema <= GraphQL::Schema
      end

    end

    class << self
      def config
        @config ||= Config.new
      end

      def configure
        yield config
        # a typo'd override or list_size key names nothing and the test still
        # passes, so catch it here — while the block that set it is still on
        # the stack
        if (schema = config.explicit_schema)
          Internal::Overrides.validate!(schema, config.overrides)
          Internal::Overrides.validate_list_size!(schema, config.list_size)
        end
        config
      end

      # back to defaults — between tests, or to undo an experiment
      def reset!
        @config = nil
      end

      # resolve a cassette name ("github") against cassette_dir; paths
      # with separators or extensions name the file themselves
      def cassette_path(name)
        return Internal::Util.resolve(name) if name.include?("/") || name.end_with?(".yml", ".yaml")

        File.join(cassette_dir, "#{name}.yml")
      end

      # The configured directory as a real path — a rake task or an rspec run
      # starts from wherever it starts from; the cassettes don't move.
      def cassette_dir = Internal::Util.resolve(config.cassette_dir)

      # Whether a scalar's two definitions agree: the server's
      # coerce_input/coerce_result, and your register_scalar. No schema
      # carries the server's half — a scalar's SDL is its name and a url —
      # so nothing `verify`, `schema:diff` or `generate` reads can say. A
      # schema CLASS carries both, and this runs them against each other.
      #
      # Per scalar the schema declares and your app registered: fabricate a
      # value the way :fake does, cast it, send it back out through
      # `serialize:`, through the server's `coerce_input` and `coerce_result`,
      # and back through `cast:`. Raises naming every scalar that disagreed
      # and how; silent when they all agree.
      #
      # Pass the schema CLASS. A dump's scalars pass values through, so
      # against one this checks only that a registration's `cast:` accepts
      # what its own `serialize:` writes — which is worth knowing, and is not
      # the same question.
      #
      # The fabricated value is what the check has to work with, so pin the
      # one that matters where it matters —
      # `config.overrides = { "Decimal" => "123456789.123456789" }` is how
      # the precision case gets exercised at all.
      def check_scalars!(schema)
        registry = Internal::Util.registry_for(schema)
        values = Internal::Values.new(seed: 0, schema:, registry:)
        context = GraphQL::Query.new(schema, "{ __typename }").context

        disagreed = schema.types.values.sort_by(&:graphql_name).filter_map do |type|
          next unless type.kind.name == "SCALAR"
          # the built-in entries are the library's own; it is your
          # registration that can be wrong about this server
          next if registry.builtin_scalar?(type.graphql_name) ||
            !registry.scalar_registry.key?(type.graphql_name)

          disagreement(registry.scalar(type.graphql_name), type, values, context)
        end
        return if disagreed.empty?

        raise GraphWeaver::Error, "#{disagreed.size} scalar(s) disagree with #{schema}:\n" +
          disagreed.map { |line| "  #{line}" }.join("\n")
      end

      private

      # One scalar's verdict, or nil when the two halves agree. Each step is
      # a different mistake, so each says which.
      def disagreement(scalar, type, values, context)
        name = type.graphql_name
        wire = values.scalar(name, name)
        cast = cast_proc(scalar)
        begin
          sample = cast.call(wire)
        rescue StandardError => e
          return "#{name}: cast: can't read #{wire.inspect}, the value fabricated for it (#{e.message}) " \
            "— pin the form this server sends: overrides: { #{name.inspect} => ... }"
        end

        if scalar.serialize? && !scalar.serialize_value?
          return "#{name}: serialize: is a Proc, which builds source for the generated file rather " \
            "than converting a value, so there is nothing here to run it against"
        end

        out = scalar.serialize_value(sample)
        refused = "#{name}: the server refused #{out.inspect}, the wire form serialize: writes"
        begin
          received = type.coerce_input(out, context)
        rescue StandardError => e
          return "#{refused} (#{e.message})"
        end
        return "#{refused} (coerce_input returned nil)" if received.nil? && !out.nil?

        result = type.coerce_result(received, context)
        begin
          back = cast.call(result)
        rescue StandardError => e
          return "#{name}: cast: refused #{result.inspect}, the result form the server's " \
            "coerce_result writes (#{e.message})"
        end
        return if back == sample

        "#{name}: round-trips lossily — sent #{sample.inspect}, got back #{back.inspect}"
      end

      # The registration's `cast:`, RUN rather than emitted. A cast builds
      # SOURCE for the generated file, so evaluating it is the only way to
      # run one — at the top level, where a generated file's own constants
      # resolve from.
      def cast_proc(scalar)
        source = scalar.cast("wire")
        return ->(wire) { wire } if source.nil?

        eval("->(wire) { #{source} }", TOPLEVEL_BINDING, __FILE__, __LINE__) # rubocop:disable Security/Eval
      end
    end
  end
end

require_relative "internal/overrides"
require_relative "internal/values"
require_relative "testing/fake_client"
require_relative "testing/fake_subgraph"
require_relative "testing/failure"
require_relative "testing/cassette"
require_relative "testing/endpoint"
require_relative "testing/router"
require_relative "testing/coverage"
