# typed: true
# frozen_string_literal: true

module GraphWeaver
  module Internal
    # The client a generated module runs against while a test mode is
    # installed — the slot `graphql: :fake` and its siblings fill.
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
    # billing's shapes, not the other schema's.
    #
    # Test-time only. Nothing installs a mode in production, where #for is an
    # ivar read that returns nil.
    module TestClients
      class << self
        # Install `mode` for one example — nil installs nothing.
        def install(mode)
          @mode = mode
          @clients = {}
        end

        # Back to no mode: every module resolves its own client again.
        def reset!
          @mode = nil
          @clients = nil
        end

        # The stand-in for `mod`, or nil when there is nothing to stand in for.
        def for(mod)
          return unless @mode
          # neither takes the client slot: :live is the app's own clients,
          # untouched, and :wire serves the resolvers at the endpoint each
          # client already posts to — the transport you ship, running
          # unchanged, is the whole point
          return if @mode == :live || @mode == :wire
          # One graph, or a suite that named one schema, has a single answer
          # and the rspec hook has already put it in the app slot. Reading it
          # back rather than building a second one is what keeps
          # graphql_fake's return value the object the modules run against.
          return GraphWeaver.client if one_answer?

          graph = graph_for!(mod)
          @clients[graph.name] ||= build(graph)
        end

        private

        def one_answer? = GraphWeaver.graphs.one? || !GraphWeaver::Testing.config.explicit_schema.nil?

        # The graph `mod` was generated from, by the name codegen baked in.
        # An app with several graphs and a module that names none was
        # generated before its graph was declared, or by an older release —
        # and guessing would fake one schema's shapes at another's module.
        def graph_for!(mod)
          name = mod.const_defined?(:GRAPH, false) ? mod.const_get(:GRAPH) : nil
          found = GraphWeaver.graphs.find { |graph| graph.name == name }
          return found if found

          declared = GraphWeaver.graphs.map { |graph| graph.name.inspect }.join(", ")
          raise GraphWeaver::Error, "#{mod} doesn't say which of this app's graphs (#{declared}) " \
            "it was generated from, so #{@mode.inspect} has nothing to run it against — " \
            "regenerate (rake graph_weaver:generate)."
        end

        def build(graph)
          case @mode
          when :fake
            GraphWeaver::Testing::FakeClient.new(schema: graph.schema)
          when :in_process
            GraphWeaver::InProcess.new(live_schema!(graph), context: GraphWeaver::Testing.config.context)
          when :router
            # one composed supergraph, built once for the suite — so this is
            # the very router the hook installed, faked subgraphs and all
            GraphWeaver::Testing.config.built_router
          end
        end

        def live_schema!(graph)
          graph.live_schema || raise(GraphWeaver::Error, ":in_process runs your resolvers, so it " \
            "needs the live GraphQL::Schema class — and graph #{graph.name.inspect} names " \
            "#{graph.named_schema? ? "type information, not a class" : "no schema of its own"}. " \
            "Declare it with the class: GraphWeaver.graph(#{graph.name.inspect}, " \
            "schema: -> { MySchema }, …).")
        end
      end
    end
  end
end
