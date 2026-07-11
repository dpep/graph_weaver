require "graphql"
require "sorbet-runtime"

require_relative "graph_weaver/errors"
require_relative "graph_weaver/response"
require_relative "graph_weaver/inflect"
require_relative "graph_weaver/codegen"
require_relative "graph_weaver/http_executor"
require_relative "graph_weaver/retry_executor"
require_relative "graph_weaver/schema_loader"
require_relative "graph_weaver/version"

# opt-in extras:
#   require "graph_weaver/faraday_executor"        # Faraday transport
#   require "graph_weaver/directive_defaults_patch" # fix graphql-ruby
#     dropping directive argument defaults when loading SDL (needed for
#     Apollo supergraph SDL until rmosolgo/graphql-ruby#5659 ships)
module GraphWeaver
  class << self
    # global default transport; generated modules fall back to this
    # (override per module with MyQuery.executor=, or per call with
    # execute(executor:))
    attr_writer :executor

    def executor
      @executor or raise Error, "no executor configured — set GraphWeaver.executor= or pass executor:"
    end

    # One-shot setup: build the best transport for a url, wrap it with
    # retries, and wire it in as the global executor. Most apps need
    # exactly one line:
    #
    #   GraphWeaver.connect("https://api.example.com/graphql", auth: ENV["API_TOKEN"])
    #
    # auth: is a token — "Bearer" is assumed unless the string carries
    # its own scheme ("Basic dXNlcjpwYXNz..."); headers: covers anything
    # else (API keys etc). retries: is off by default — pass true for a
    # RetryExecutor with defaults, or a Hash of RetryExecutor options to
    # tune. A block customizes the Faraday connection (faraday only).
    # Returns the executor it wired in.
    #
    # Transport pick: Faraday when the app already loads it (its
    # middleware/proxy/timeout ecosystem comes along), the built-in
    # zero-dependency executor otherwise. Detection is `defined?(Faraday)`
    # — deliberately NOT a require: faraday rides along transitively in
    # most bundles (stripe, octokit, ...), and try-requiring would switch
    # transports on apps that never chose it. With faraday under
    # `require: false`, load it before calling connect — or construct
    # FaradayExecutor / HttpExecutor / RetryExecutor directly and assign
    # GraphWeaver.executor= yourself; connect is convenience, not the
    # only door.
    def connect(url, auth: nil, headers: {}, retries: false, &middleware)
      headers = headers.dup
      if auth
        headers["Authorization"] ||= auth.include?(" ") ? auth : "Bearer #{auth}"
      end

      transport = build_transport(url, headers:, &middleware)
      self.executor = case retries
      when true then RetryExecutor.new(transport)
      when false, nil then transport
      else RetryExecutor.new(transport, **retries)
      end
    end

    def build_transport(url, headers:, &middleware)
      if defined?(::Faraday)
        require_relative "graph_weaver/faraday_executor"
        FaradayExecutor.new(url, headers:, &middleware)
      elsif middleware
        raise ArgumentError, "middleware blocks require the faraday gem"
      else
        HttpExecutor.new(url, headers:)
      end
    end
    private :build_transport

    # Conventional locations, factory_bot-style: used as defaults by
    # generate!, verify_generated!, load_generated!, and the rake tasks;
    # override the accessors or pass paths.
    attr_writer :queries_path, :generated_path, :schema_path

    def queries_path = @queries_path || "app/graphql/queries"
    def generated_path = @generated_path || "app/graphql/generated"
    def schema_path = @schema_path || "app/graphql/schema.json"

    # Generate every .graphql query in a directory into checked-in Ruby
    # files. Paths default to the conventions above; nothing scans or
    # loads implicitly:
    #
    #   GraphWeaver.generate!(schema:)   # queries_path -> generated_path
    #
    # person.graphql => person_query.rb defining PersonQuery. Returns the
    # written paths. Pair with a freshness spec (docs/generated_modules.md).
    def generate!(schema:, queries: queries_path, output: generated_path, executor: nil)
      require "fileutils"
      FileUtils.mkdir_p(output)

      each_query(queries, schema:, executor:).map do |base, source|
        target = File.join(output, "#{base}_query.rb")
        File.write(target, source)
        target
      end
    end

    # The freshness guard: raise unless every generated file matches what
    # the current schema + queries + scalar registrations would produce.
    # One line in a spec, or `rake graph_weaver:verify` in CI:
    #
    #   it "generated queries are current" do
    #     GraphWeaver.verify_generated!(schema:)
    #   end
    def verify_generated!(schema:, queries: queries_path, output: generated_path, executor: nil)
      stale = each_query(queries, schema:, executor:).filter_map do |base, source|
        target = File.join(output, "#{base}_query.rb")
        target unless File.exist?(target) && File.read(target) == source
      end

      unless stale.empty?
        raise Error, "stale generated queries — regenerate (rake graph_weaver:generate): #{stale.join(", ")}"
      end

      true
    end

    # Load the generated modules — one line in an initializer or spec
    # helper (loading happens only when you call this; skip it and
    # require files yourself if you'd rather):
    #
    #   GraphWeaver.load_generated!
    #
    # In Rails, prefer this over autoloading: Zeitwerk would expect
    # Generated::PersonQuery from generated/person_query.rb, and
    # generated code only changes on regeneration anyway (restart, like
    # a schema migration).
    def load_generated!(path = generated_path)
      Dir[File.join(path, "**/*.rb")].sort.each { |file| require File.expand_path(file) }
    end

    # (base, generated_source) per .graphql file in a directory
    def each_query(queries, schema:, executor:)
      Dir[File.join(queries, "*.graphql")].sort.map do |path|
        base = File.basename(path, ".graphql")
        source = Codegen.generate(
          schema:,
          query: File.read(path),
          module_name: "#{Inflect.camelize(base)}Query",
          executor:,
        )
        [base, source]
      end
    end
    private :each_query

    # Default input coercion for scalars that don't say coerce: themselves,
    # resolved lazily at generation time (so set it any time before you
    # generate — no reset_scalars! ordering dance):
    #
    #   GraphWeaver.auto_coerce = true
    #
    # Convertible built-ins take their conversion (Int accepts 5/"5"),
    # and any scalar with a full cast/serialize pair (Date, your Money)
    # accepts its raw wire form. An explicit coerce: true/false/Symbol on
    # a registration always wins.
    attr_accessor :auto_coerce

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
    def register_scalar(graphql_name, type:, cast: nil, serialize: nil, requires: nil, coerce: nil)
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
    #   GraphWeaver.execute(schema:, query:, variables: { id: "1" })   # => Response
    #   GraphWeaver.execute!(schema:, query:, variables: { id: "1" })  # => Result (or raise)
    #
    # Mirrors a generated module: execute returns the Response envelope,
    # execute! returns the typed result directly and raises QueryError on
    # top-level errors. Transport precedence: executor: param, then
    # GraphWeaver.executor, then in-process execution against schema.
    # Variable keys may be graphql-cased strings or ruby symbols.
    def execute(schema:, query:, variables: {}, executor: nil)
      executor ||= @executor || schema
      mod = parse(schema:, query:, executor:)
      kwargs = variables.to_h { |key, value| [Inflect.underscore(key.to_s).to_sym, value] }
      mod.execute(**kwargs)
    end

    # execute + data! — the typed result, or a raised QueryError. See execute.
    def execute!(schema:, query:, variables: {}, executor: nil)
      execute(schema:, query:, variables:, executor:).data!
    end
  end
end
