# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "internal"
require_relative "internal/test_clients"

module GraphWeaver
  # Called by generated code — not semver'd for direct use.
  #
  # Runtime for generated query modules: the client plumbing, which is the
  # one part of a generated module that carries no per-query type
  # information — every module's copy was identical. `extend
  # GraphWeaver::QueryModule` supplies `client`/`client=`; execute and
  # from_response stay generated, since their sigs are the query's types and
  # those are the point.
  #
  # Resolution order, per the docs: per call → per module (`MyQuery.client =`)
  # → a test mode's stand-in (Internal::TestClients) → the client the
  # module's graph names → `GraphWeaver.client`.
  module QueryModule
    extend T::Sig

    sig { params(client: T.untyped).void }
    attr_writer :client

    # the default client (a GraphWeaver::Client or any transport) for
    # execute: per-module override, else the graph's, else the app one
    sig { returns(T.untyped) }
    def client
      @client || default_client
    end

    private

    # The one call a generated `execute` makes: resolve the client, run this
    # module's own operation, hand the raw response back for from_response to
    # wrap. Here rather than emitted, so what has to BRACKET a request — the
    # graph label today — costs nothing in every generated file, and one
    # reading of it covers every module in the app.
    #
    # The constants come off the module rather than the caller: a generated
    # `execute` already knows them, but reading them here is what makes this
    # the whole of the call instead of three arguments' worth of it.
    sig { params(variables: T::Hash[String, T.untyped], client: T.untyped).returns(T.untyped) }
    def dispatch(variables, client:)
      # A value with no JSON form is a bug in the call, not in the client that
      # would have carried it — so it is refused here, where every mode passes,
      # rather than in the transport, which :in_process and :fake never reach.
      # (A transport asks the same question of a raw query string, which never
      # comes through here.)
      GraphWeaver::Internal::Wire.check_variables!(variables)

      mod = T.unsafe(self)
      # the graph codegen baked in, never one inferred from the client — a
      # wrong label on a request is worse than no label
      GraphWeaver::Internal::Log.with_graph(graph_name) do
        client_for(client).execute(mod.const_get(:QUERY), variables:,
          operation_name: mod.const_get(:OPERATION_NAME))
      end
    end

    # The client one execute runs through: the per-call `client:`, else the
    # module's, else the app default. Checked here so a wrong one names the
    # contract and the module, rather than surfacing as a NoMethodError from
    # inside the call — and put through Client.instrumented, the one place a
    # bare schema class gets the seam it has no way to carry itself.
    sig { params(override: T.untyped).returns(T.untyped) }
    def client_for(override)
      target = GraphWeaver::Client.instrumented(override || client)
      return target if target.respond_to?(:execute)

      # Kernel.raise: this module is extended into another, so sorbet can't
      # see that its host is an Object
      Kernel.raise GraphWeaver::Error,
        "#{self}: client must respond to #execute(query, variables:), got #{target.class}"
    end

    # A module knows which graph it belongs to, and the graph knows how to
    # reach it: the client that graph names, else the app default. Read at
    # call time, so renaming the constant a graph names is an initializer
    # edit rather than a regeneration of every module.
    #
    # A test mode stands in ahead of it: the graph's client is exactly what a
    # `graphql:` tag means to replace, so a tagged example reaches a module
    # whose graph names a client like every other one.
    sig { returns(T.untyped) }
    def default_client
      stand_in = GraphWeaver::Internal::TestClients.for(T.unsafe(self))
      return stand_in if stand_in

      GraphWeaver::Internal::Util.graph_named(graph_name)&.client || GraphWeaver.client!
    end

    # The graph codegen baked in, by name — nil for a module generated before
    # graphs existed, or by a GraphWeaver.parse that named none.
    sig { returns(T.untyped) }
    def graph_name
      mod = T.unsafe(self)
      mod.const_defined?(:GRAPH, false) ? mod.const_get(:GRAPH) : nil
    end
  end
end
