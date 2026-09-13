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
      # The app client slot under a mode in an app with several graphs. It
      # fills the duck-typed slot the same way every other client does, and
      # answers the one question asked of it with the reason there is no
      # answer — the alternative is the real endpoint, silently.
      class NoAppClient
        def initialize(mode) = @mode = mode

        def execute(_query, **)
          graphs = GraphWeaver.graphs
          raise GraphWeaver::Error, "#{@mode.inspect} stands in for a graph's modules, and this " \
            "app has #{graphs.size} graphs (#{graphs.map { |g| g.name.inspect }.join(", ")}) — so " \
            "GraphWeaver.client has no one right answer, and this request would have gone to the " \
            "real endpoint. A generated module runs against its own graph's stand-in; to reach one " \
            "directly, call the client a helper returns (graphql_fake(graph: #{graphs.first.name.inspect}), " \
            "graphql_in_process(graph: #{graphs.first.name.inspect})). Tag the example graphql: :live " \
            "for the app's own client."
        end

        def inspect = "#<#{self.class} #{@mode.inspect}>"
      end

      class << self
        # Install `mode` for one example — nil installs nothing.
        #
        # Installing the mode already installed keeps the table, so a second
        # helper ADDS a stand-in for its graph rather than clearing the
        # first's — and a graphql_context set before a helper survives it. A
        # contradicting mode is refused by claim_mode! before it gets here;
        # the hook that installs the example's mode runs after reset!, with
        # nothing to keep.
        def install(mode)
          return if installed? && @mode == mode

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

        # Whether this example's stand-ins are already built — which is what
        # makes a config setting they were built FROM too late to change.
        def built? = !(@clients.nil? || @clients.empty?)

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
        #
        # `mode` is how a helper under a :wire tag asks for the client its own
        # name means rather than the one :wire would have picked.
        def standin(graph, mode = @mode)
          @clients[graph&.name] ||= client_for(mode, graph)
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
            # fabricated data. Once per router, not once per graph: two
            # graphs naming one supergraph share it, and resetting again when
            # the second's first module resolved wiped what the first had
            # already accumulated, mid-example.
            router.reset! unless @clients&.value?(router)
            router
          when :wire
            # what sits behind the wire is decided the way the other tags
            # already decide it, per graph — the most faithful thing that
            # graph has, in the order the other tags rank them
            client_for(wire_mode(config, graph), graph)
          end
        end

        # What :wire serves for `graph`: its router when it is in a composed
        # supergraph, its live schema class when it has one, else a fake of
        # its schema — which is what an app that is a pure client of someone
        # else's API has, and the only mode it could be.
        #
        # The one candidate the other modes have and :wire doesn't is
        # GraphWeaver.client's own schema: reading it introspects the very
        # endpoint :wire is about to stub, so it is a refusal here rather than
        # a request into a stub that doesn't exist yet.
        def wire_mode(config, graph)
          return :router if config.supergraph?(graph)
          return :in_process if config.schema_class?(graph)
          return :fake if config.schema || graph&.named_schema?

          raise GraphWeaver::Error, ":wire serves your schema at the endpoint your client posts " \
            "to, and #{graph&.name ? "graph #{graph.name.inspect}" : "this app"} has none to " \
            "serve — no live GraphQL::Schema class, no composed supergraph, and no type " \
            "information (nothing at #{GraphWeaver.schema_path}, and " \
            "GraphWeaver::Testing.config.schema is unset). Your client's own schema can't stand " \
            "in here: reading it introspects the endpoint :wire has stubbed. Commit a dump " \
            "(rake graph_weaver:schema:refresh URL=…), or tag the example graphql: :live."
        end

        # The graph a mode builds for when no module named one: this app's
        # only graph. With several the honest answer varies per module, so
        # there is no app-wide one and each module resolves its own.
        def app_graph
          graphs = GraphWeaver.graphs
          graphs.first if graphs.one?
        end

        # What GraphWeaver.client holds while a mode is installed, or nil for
        # the modes that leave the app's own there (:live, and :wire, which
        # serves at each client's endpoint instead).
        #
        # One graph has one answer, so the app slot holds the same stand-in
        # its modules resolve. With several there is none — and leaving the
        # app's real client in the slot let a stray GraphWeaver.client.execute
        # reach the production endpoint from an example whose tag promised no
        # request, so the slot refuses by name instead.
        def app_client
          return if @mode.nil? || @mode == :live || @mode == :wire

          graph = app_graph
          graph ? standin(graph) : NoAppClient.new(@mode)
        end

        # The graphs a helper stands in for: the one `graph:` names, else the
        # ones `schema` names, else this app's only graph. A helper that
        # reaches no module is the silent pass this slot exists to stop, so
        # nothing to reach is a refusal — and `advice` is what THIS helper
        # does once it knows which graph.
        #
        # `graph:` leads because a graph's name is its identity everywhere
        # else in the gem, and it is the only spelling that reaches every
        # graph: `schema` is matched by object identity, which a graph whose
        # schema is a dump has nothing to match with.
        def targets!(helper, schema, advice, graph: nil)
          return [graph!(helper, graph)] if graph

          named = named_graphs(schema)
          return named if named.any?

          graphs = GraphWeaver.graphs
          return graphs if graphs.one?

          raise GraphWeaver::Error, "#{helper} stands in for the modules of one graph, and " \
            "#{schema ? "#{schema} names none of this app's graphs" : "this app has #{graphs.size}"} " \
            "(#{declared_names}) — say which: #{helper}(graph: #{graphs.first.name.inspect}). #{advice}"
        end

        private

        # The graph `graph:` names. Its name, not its schema: that is what
        # `rake graph_weaver:graphs` prints, what codegen bakes into a
        # module's GRAPH, and the one handle a dump-backed graph has.
        def graph!(helper, name)
          found = GraphWeaver.graphs.find { |graph| graph.name == name }
          return found if found

          near = Util.did_you_mean(GraphWeaver.graphs.map { |graph| graph.name.to_s }, name.to_s)
          raise GraphWeaver::Error, "#{helper}(graph: #{name.inspect}) names none of this app's " \
            "graphs (#{declared_names})#{" — did you mean #{near.to_sym.inspect}?" if near}"
        end

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

          # Two doors produce a module, so the fix has two spellings: a file
          # gets its GRAPH back by being regenerated, and a GraphWeaver.parse
          # module — which generates no file, so regenerating cannot reach it
          # — is told where it is parsed.
          raise GraphWeaver::Error, "#{mod} doesn't say which of this app's graphs " \
            "(#{declared_names}) it was generated from, so #{@mode.inspect} has nothing to run " \
            "it against — regenerate it (rake graph_weaver:generate), or, if it came from " \
            "GraphWeaver.parse, say which there (graph: #{graphs.first.name.inspect})."
        end
      end
    end
  end
end
