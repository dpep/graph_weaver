# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

module GraphWeaver
  # Runtime for generated query modules: the client plumbing, which is the
  # one part of a generated module that carries no per-query type
  # information — every module's copy was identical. `extend
  # GraphWeaver::QueryModule` supplies `client`/`client=`; execute and
  # from_response stay generated, since their sigs are the query's types and
  # those are the point.
  #
  # Resolution order, per the docs: per call → per module (`MyQuery.client =`)
  # → the module's baked DEFAULT_CLIENT → `GraphWeaver.client`.
  module QueryModule
    extend T::Sig

    sig { params(client: T.untyped).void }
    attr_writer :client

    # the default client (a GraphWeaver::Client or any transport) for
    # execute: per-module override, else the baked default, else the app one
    sig { returns(T.untyped) }
    def client
      @client || default_client
    end

    private

    # Codegen's `client:` constant, emitted as a DEFAULT_CLIENT lambda so the
    # constant it names is resolved on first use rather than at load — a
    # generated file may load before the initializer that builds the client.
    sig { returns(T.untyped) }
    def default_client
      mod = T.unsafe(self)
      mod.const_defined?(:DEFAULT_CLIENT, false) ? mod.const_get(:DEFAULT_CLIENT).call : GraphWeaver.client!
    end
  end
end
