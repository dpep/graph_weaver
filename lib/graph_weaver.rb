require "graphql"
require "sorbet-runtime"

require_relative "graph_weaver/logging"
require_relative "graph_weaver/errors"
require_relative "graph_weaver/hints"
require_relative "graph_weaver/response"
require_relative "graph_weaver/inflect"
require_relative "graph_weaver/codegen"
require_relative "graph_weaver/client"
require_relative "graph_weaver/transport/http"
require_relative "graph_weaver/retry_executor"
require_relative "graph_weaver/schema_loader"
require_relative "graph_weaver/version"
require_relative "graph_weaver/railtie" if defined?(::Rails::Railtie)

# opt-in extras:
#      require "graph_weaver/transport/faraday"        # Faraday transport
#      require "graph_weaver/directive_defaults_patch" # fix graphql-ruby
#        dropping directive argument defaults when loading SDL (needed for
#        Apollo supergraph SDL until rmosolgo/graphql-ruby#5659 ships)
module GraphWeaver
  class << self
    # A client for one GraphQL server — transport, schema, and scoped
    # scalars in one object (see Client):
    #
    #      github = GraphWeaver.new("https://api.github.com/graphql", auth: token, cache: true)
    #      RepoQuery = github.parse("queries/repo.graphql")
    #
    # The first argument is a url or any schema source (a live schema
    # class, or a path/SDL/introspection dump).
    def new(source, **options, &middleware)
      Client.new(source, **options, &middleware)
    end

    # The app's default client — the blessed way to wire generated
    # modules to a server:
    #
    #      GraphWeaver.client = GraphWeaver.new(url, auth: token)
    #
    # Generated modules resolve their transport per call -> per module ->
    # baked constant -> GraphWeaver.executor= -> the default client.
    attr_accessor :client

    # The low-level knob under client=: assign a bare executor (a fake, a
    # custom transport) and it wins over the default client — which is
    # how testing's auto_fake swaps in per example. Generated modules
    # fall back to this method.
    attr_writer :executor

    def executor
      @executor || @client&.own_executor or
        raise Error, "no executor configured — set GraphWeaver.client= (or executor=), or pass executor:"
    end

    # is an explicit executor= override set? (the default client doesn't
    # count: a client resolving its own transport must not see another
    # client through the global)
    def executor?
      !@executor.nil?
    end

    # Conventional locations, factory_bot-style: used as defaults by
    # generate!, verify_generated!, load_generated!, and the rake tasks;
    # override the accessors or pass paths.
    attr_writer :queries_path, :generated_path, :schema_path

    def queries_path = @queries_path || "app/graphql/queries"
    def generated_path = @generated_path || "app/graphql/generated"
    def schema_path = @schema_path || "app/graphql/schema.json"

    # Generate every .graphql query in a directory into checked-in Ruby
    # files. Paths default to the conventions above; schema: defaults to
    # the dump at schema_path (any supported extension):
    #
    #      GraphWeaver.generate!   # queries_path -> generated_path
    #
    # person.graphql => person_query.rb defining PersonQuery. Returns the
    # written paths. Pair with a freshness spec (docs/generated_modules.md).
    def generate!(schema: nil, queries: queries_path, output: generated_path, executor: nil)
      schema ||= locate_schema!
      require "fileutils"
      FileUtils.mkdir_p(output)

      each_query(queries, schema:, executor:).map do |base, source|
        target = File.join(output, "#{base}_query.rb")
        File.write(target, source)
        log(:info) { "generated #{target}" }
        target
      end
    end

    # The freshness guard: raise unless every generated file matches what
    # the current schema + queries + scalar registrations would produce.
    # One line in a spec, or `rake graph_weaver:verify` in CI:
    #
    #      it "generated queries are current" do
    #        GraphWeaver.verify_generated!
    #      end
    def verify_generated!(schema: nil, queries: queries_path, output: generated_path, executor: nil)
      schema ||= locate_schema!
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
    #      GraphWeaver.load_generated!
    #
    # In Rails, prefer this over autoloading: Zeitwerk would expect
    # Generated::PersonQuery from generated/person_query.rb, and
    # generated code only changes on regeneration anyway (restart, like
    # a schema migration).
    def load_generated!(path = generated_path)
      files = Dir[File.join(path, "**/*.rb")].sort
      files.each { |file| require File.expand_path(file) }
      log(:info) { "loaded #{files.size} generated module(s) from #{path}" }
      files
    end

    # the conventional schema dump, required
    def locate_schema!
      SchemaLoader.locate or raise Error,
        "no schema dump at #{schema_path} (.json/.graphql/.gql) — pass schema:, or cache one: GraphWeaver.new(url, cache: true).schema"
    end
    private :locate_schema!

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
    #      GraphWeaver.auto_coerce = true
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
    #      GraphWeaver.register_scalar("Money", Money, requires: "bigdecimal")
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
    def register_scalar(graphql_name, type, cast: nil, serialize: nil, requires: nil, coerce: nil)
      Codegen.register_scalar(graphql_name, type, cast:, serialize:, requires:, coerce:)
    end

    # Map a GraphQL enum onto an app-owned T::Enum, so generated code
    # speaks YOUR enum — casting wire values in, serializing members out:
    #
    #      GraphWeaver.register_enum("Species", PetKind)
    #
    # The mapping is inferred by name ("CAT" <-> PetKind::Cat); map: pins
    # renames, fallback: absorbs unknown wire values on cast (inputs stay
    # strict), requires: names files the generated code should require.
    # Generation fails naming any schema value that doesn't resolve —
    # exhaustiveness checked ahead of runtime. Global; client.register_enum
    # scopes to one client.
    def register_enum(graphql_name, type, map: nil, fallback: nil, requires: nil)
      Codegen.register_enum(graphql_name, type, map:, fallback:, requires:)
    end

    # Bulk, inference-only form: register_enums("Species" => PetKind, ...)
    def register_enums(mappings)
      Codegen.register_enums(mappings)
    end

    # Include app-owned helper modules into every struct generated from a
    # GraphQL type — derived values live as methods next to the honest
    # wire data, and srb tc checks them against each query's selection:
    #
    #      GraphWeaver.register_type("Pet", PetHelpers)
    #
    # Or build the mixin inline with a block (module_eval'd into an
    # auto-named module — quick, but invisible to srb tc):
    #
    #      GraphWeaver.register_type("Pet") do
    #        def display_name = "#{name} the pet"
    #      end
    #
    # Additive (repeated and client-scoped registrations stack). Global;
    # client.register_type scopes to one client.
    def register_type(graphql_name, *mixins, requires: nil, &block)
      Codegen.register_type(graphql_name, *mixins, requires:, &block)
    end

    # Restore the built-in scalars, dropping every custom registration —
    # the clean slate to reach for between tests or to undo overrides.
    # (Coercible built-ins are auto_coerce's job, not a reset flavor.)
    def reset_scalars!
      Codegen.reset_scalars!
    end

    # Empty the scalar registry entirely, built-ins included (see
    # reset_scalars! to restore the defaults).
    def clear_scalars!
      Codegen.clear_scalars!
    end

    # Parse a query into a typed query module:
    #
    #      PersonQuery = GraphWeaver.parse(schema:, query: "queries/person.graphql")
    #
    # query is a .graphql/.gql path (module name derived from the file
    # name) or a raw query string (name derived from the operation name,
    # falling back to "Query" for anonymous operations — collisions are
    # impossible since each parse gets its own container). Pass name: to
    # override, executor: to set the module's transport.
    def parse(schema:, query:, name: nil, executor: nil, scalars: nil, enums: nil, types: nil)
      if query.end_with?(".graphql", ".gql")
        name ||= "#{Inflect.camelize(File.basename(query, ".*"))}Query"
        query = File.read(query)
      end

      Codegen.parse(schema:, query:, module_name: name, executor:, scalars:, enums:, types:)
    end

    # One-shot dynamic execution — a throwaway client, no build step:
    #
    #      GraphWeaver.execute(schema, "query($id: ID!) { ... }", id: "1")   # => Response
    #      GraphWeaver.execute!(url, "query { viewer { login } }")           # => Result (or raise)
    #
    # The first argument is a url or schema source, exactly as
    # GraphWeaver.new; this is Client#execute on a client you don't keep.
    # (A url source introspects the schema on every call — keep a client
    # for more than one query.) Variables are plain kwargs, as on a
    # generated module ("executor" is reserved). execute returns the
    # Response envelope, execute! the typed result, raising QueryError on
    # top-level errors.
    def execute(source, query, executor: nil, **variables)
      Client.new(source, executor:).execute(query, **variables)
    end

    # execute + data! — the typed result, or a raised QueryError. See execute.
    def execute!(source, query, executor: nil, **variables)
      execute(source, query, executor:, **variables).data!
    end
  end
end
