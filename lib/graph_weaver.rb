require "graphql"
require "sorbet-runtime"

require_relative "graph_weaver/inflect"
require_relative "graph_weaver/codegen"
require_relative "graph_weaver/http_executor"
require_relative "graph_weaver/schema_loader"
require_relative "graph_weaver/version"

# opt-in extras:
#   require "graph_weaver/faraday_executor"        # Faraday transport
#   require "graph_weaver/directive_defaults_patch" # fix graphql-ruby
#     dropping directive argument defaults when loading SDL (needed for
#     Apollo supergraph SDL until rmosolgo/graphql-ruby#5659 ships)
module GraphWeaver
  class Error < StandardError; end

  class << self
    # global default transport; generated modules fall back to this
    # (override per module with MyQuery.executor=, or per call with
    # execute(executor:))
    attr_writer :executor

    def executor
      @executor or raise Error, "no executor configured — set GraphWeaver.executor= or pass executor:"
    end

    # Teach the generator how a GraphQL custom scalar deserializes into a
    # rich Ruby object (and serializes back onto the wire when used as a
    # variable):
    #
    #   GraphWeaver.register_scalar("Money", type: Money, requires: "bigdecimal")
    #
    # A field typed `Money` then generates `const :price, T.nilable(Money)`
    # and casts with `Money.parse(...)` in from_h. Pass a real class as
    # type: and cast:/serialize: are inferred from it — .parse/#to_s, or
    # .load/.dump — by probing the deserialize side (see ScalarType::CODECS).
    # Override with a Symbol method name (safest — no string to misspell), a
    # Proc(expr) => code string, or :itself to force pass-through. requires:
    # (a String or Array) names files the generated code needs — validated,
    # and actually required to confirm it resolves when type: is a real class.
    # coerce: true makes a variable of this scalar accept the value OR its
    # raw input (e.g. "12.00"), running the latter through the cast before
    # serializing — it raises on bad input, so some safety survives. Built-in
    # scalars are pre-registered the same way, so this also overrides them.
    # Call before generating.
    def register_scalar(graphql_name, type:, cast: nil, serialize: nil, requires: nil, coerce: false)
      Codegen.register_scalar(graphql_name, type:, cast:, serialize:, requires:, coerce:)
    end

    # Restore the built-in scalars, dropping every custom registration —
    # the clean slate to reach for between tests or to undo overrides. Pass
    # coerce: true to reload the built-ins with input coercion enabled
    # (Float accepts 5/"5", etc.), then register your own scalars on top.
    def reset_scalars!(coerce: false)
      Codegen.reset_scalars!(coerce:)
    end

    # Empty the scalar registry entirely, built-ins included (see
    # reset_scalars! to restore the defaults).
    def clear_scalars!
      Codegen.clear_scalars!
    end

    # Parse a query into a typed query module:
    #
    #   PersonQuery = GraphWeaver.parse(schema:, query: "queries/person.graphql")
    #
    # query is a .graphql/.gql path (module name derived from the file
    # name) or a raw query string (name derived from the operation name,
    # falling back to "Query" for anonymous operations — collisions are
    # impossible since each parse gets its own container). Pass name: to
    # override, executor: to set the module's transport.
    def parse(schema:, query:, name: nil, executor: nil)
      if query.end_with?(".graphql", ".gql")
        name ||= "#{Inflect.camelize(File.basename(query, ".*"))}Query"
        query = File.read(query)
      end

      Codegen.parse(schema:, query:, module_name: name, executor:)
    end

    # One-shot dynamic execution — no module handling, no build step:
    #
    #   GraphWeaver.execute(schema:, query:, variables: { id: "1" })
    #
    # Transport precedence: executor: param, then GraphWeaver.executor,
    # then in-process execution against schema. Variable keys may be
    # graphql-cased strings or ruby symbols.
    def execute(schema:, query:, variables: {}, executor: nil)
      executor ||= @executor || schema
      mod = parse(schema:, query:, executor:)
      kwargs = variables.to_h { |key, value| [Inflect.underscore(key.to_s).to_sym, value] }
      mod.execute(**kwargs)
    end
  end
end
