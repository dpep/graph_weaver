# typed: true
# frozen_string_literal: true

module GraphWeaver
  module Internal
    # The client a generated module runs against while a test mode is
    # installed — the slot `graphql: :fake` and its siblings fill, and the one
    # a `graphql_*` helper writes to.
    #
    # A tag used to work by swapping GraphWeaver.client, which is the LAST
    # place a module looks: one generated with `client:` reads its baked
    # DEFAULT_CLIENT first and never got there, so the tag quietly didn't
    # apply. The mode installs itself here instead, and QueryModule asks
    # before it reads that constant — so a tag reaches every module the
    # example runs, bound or not.
    #
    # Keyed by the graph a module was generated from (its baked GRAPH), since
    # the honest answer varies: :fake for a billing module has to fabricate
    # billing's shapes, not the other schema's. A helper names its graphs the
    # same way and lands in the same table, so what an example says applies to
    # the modules it runs.
    #
    # Test-time only. Nothing installs a mode in production, where #for is an
    # ivar read that returns nil.
    module TestClients
      class << self
        # Install `mode` for one example — nil installs nothing.
        def install(mode)
          @mode = mode
          @clients = {}
          @context = nil
        end

        # Back to no mode: every module resolves its own client again.
        def reset!
          @mode = nil
          @clients = nil
          @context = nil
        end

        # Whether an example is running under a mode — what tells suite setup
        # apart from an example changing it out from under itself.
        def installed? = !@mode.nil?

        # The GraphQL context every stand-in runs with: this example's, else
        # the suite baseline. graphql_context writes it, and the stand-ins
        # already built take it in place — a :wire example's are built before
        # the example body runs.
        def context = @context || GraphWeaver::Testing.config.context

        def context=(values)
          @context = values
          @clients&.each_value { |client| client.context = values if client.respond_to?(:context=) }
        end

        # `client` stands in for every graph in `graphs`, in place of the one
        # the mode would build. This is a helper called in an example saying
        # what the modules it names run against.
        def override!(client, graphs)
          graphs.each { |graph| @clients[graph&.name] = client }
          client
        end

        # The stand-in for `mod`, or nil when there is nothing to stand in for.
        def for(mod)
          return unless @mode
          # neither takes the client slot: :live is the app's own clients,
          # untouched, and :wire serves the resolvers at the endpoint each
          # client already posts to — the transport you ship, running
          # unchanged, is the whole point
          return if @mode == :live || @mode == :wire

          standin(graph_for!(mod))
        end

        # The stand-in `graph`'s modules run against under the installed mode,
        # built once per example. :wire reaches it too — its clients sit
        # behind the served endpoints rather than in the client slot, but they
        # are the same objects graphql_context has to reach.
        def standin(graph)
          @clients[graph&.name] ||= client_for(@mode, graph)
        end

        # The client `mode` runs `graph` against — the one answer to "what
        # does this tag mean", asked per module here and once per example by
        # the rspec hook. nil for the two modes that take no client slot:
        # :live is the app's own clients, untouched, and :wire serves the
        # resolvers at the endpoint each client already posts to.
        def client_for(mode, graph = app_graph)
          config = GraphWeaver::Testing.config
          case mode
          when :fake
            GraphWeaver::Testing::FakeClient.new(schema: config.reference_schema!(graph),
              registry: graph&.registry)
          when :in_process
            GraphWeaver::InProcess.new(config.schema_class!(graph), context:)
          when :router
            router = config.built_router(graph)
            router.context = context
            # a router is built once per supergraph, so it has to be told
            # where this example starts — the trace, and any faked subgraph's
            # fabricated data
            router.reset!
          when :wire
            # what sits behind the wire is decided the way the other tags
            # already decide it, per graph — the router when that graph is in
            # a composed supergraph, its live schema class otherwise
            client_for(config.supergraph?(graph) ? :router : :in_process, graph)
          end
        end

        # The graph a mode builds for when no module named one: this app's
        # only graph. With several the honest answer varies per module, so
        # there is no app-wide one and each module resolves its own.
        def app_graph
          graphs = GraphWeaver.graphs
          graphs.first if graphs.one?
        end

        # The graphs a helper stands in for: the ones `schema` names, else
        # this app's only graph. A helper that reaches no module is the silent
        # pass this slot exists to stop, so nothing to reach is a refusal —
        # and `advice` is how THIS helper is told which graph it means.
        def targets!(helper, schema, advice)
          named = named_graphs(schema)
          return named if named.any?

          graphs = GraphWeaver.graphs
          return graphs if graphs.one?

          raise GraphWeaver::Error, "#{helper} stands in for the modules of one graph, and " \
            "#{schema ? "#{schema} names none of this app's graphs" : "this app has #{graphs.size}"} " \
            "(#{declared_names}) — #{advice}"
        end

        private

        # The graphs `schema` names: a schema class is matched against what
        # each graph runs in-process, which is the only thing that ties a
        # class to a graph. A graph named by a dump can't be named this way,
        # and correctly isn't.
        def named_graphs(schema)
          return [] unless schema

          GraphWeaver.graphs.select { |graph| graph.live_schema.equal?(schema) }
        end

        def declared_names = GraphWeaver.graphs.map { |graph| graph.name.inspect }.join(", ")

        # The graph `mod` was generated from, by the name codegen baked in.
        # An app with several graphs and a module that names none was
        # generated before its graph was declared, or by an older release —
        # and guessing would fake one schema's shapes at another's module.
        def graph_for!(mod)
          graphs = GraphWeaver.graphs
          return graphs.first if graphs.one?

          name = mod.const_defined?(:GRAPH, false) ? mod.const_get(:GRAPH) : nil
          found = graphs.find { |graph| graph.name == name }
          return found if found

          raise GraphWeaver::Error, "#{mod} doesn't say which of this app's graphs " \
            "(#{declared_names}) it was generated from, so #{@mode.inspect} has nothing to run " \
            "it against — regenerate (rake graph_weaver:generate)."
        end
      end
    end
  end
end
