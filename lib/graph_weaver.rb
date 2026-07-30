require "graphql"
require "sorbet-runtime"

require_relative "graph_weaver/logging"
require_relative "graph_weaver/errors"
require_relative "graph_weaver/hints"
require_relative "graph_weaver/input_struct"
require_relative "graph_weaver/response"
require_relative "graph_weaver/inflect"
require_relative "graph_weaver/codegen"
require_relative "graph_weaver/client"
require_relative "graph_weaver/transport/http"
require_relative "graph_weaver/retry"
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

    # The app's default client — how generated modules find their server:
    #
    #      GraphWeaver.client = GraphWeaver.new(url, auth: token)
    #
    # Accepts a Client or anything satisfying the execute contract (a
    # schema class, a fake — testing's auto_fake swaps one in per
    # example). Generated modules resolve per call -> per module
    # (MyQuery.client=) -> baked constant -> here.
    attr_accessor :client

    # the default client, when one is required
    def client!
      @client or raise Error, "no client configured — set GraphWeaver.client= or pass a client"
    end

    # The transport behind a client-or-transport value: a Client resolves
    # to its own transport, anything else already speaks execute.
    # Generated modules call this on every execute, so any slot in the
    # resolution chain can hold either kind.
    def resolve_transport(target)
      target.is_a?(Client) ? target.transport! : target
    end

    # Conventional locations, factory_bot-style — LISTS, so extra
    # locations (a test-only dir, an engine's) can be appended and every
    # loader walks them all:
    #
    #      # e.g. in spec/support/graph_weaver.rb
    #      GraphWeaver.generated_paths << "spec/support/graphql/generated"
    #      GraphWeaver.queries_paths << "spec/support/graphql/queries"
    #
    # The singular accessors read the first entry (the default target
    # for generate! and the rake tasks); assigning one replaces the list.
    attr_writer :queries_paths, :generated_paths, :schema_path, :fragments_paths

    # Entries may be glob patterns — the generated default also matches
    # per-schema layouts (app/graphql/github/generated). Queries stay
    # single-schema: load_queries! parses everything against one client.
    def queries_paths = @queries_paths ||= ["app/graphql/queries"]
    def generated_paths = @generated_paths ||= ["app/graphql/generated", "app/graphql/*/generated"]

    # Reusable named fragments, defined once and available to every query —
    # each query inlines only the ones it (transitively) spreads, so the sent
    # query stays self-contained.
    def fragments_paths = @fragments_paths ||= ["app/graphql/fragments"]

    def queries_path = queries_paths.first
    def generated_path = generated_paths.first
    def fragments_path = fragments_paths.first

    def queries_path=(path)
      @queries_paths = path.nil? ? nil : [path]
    end

    def generated_path=(path)
      @generated_paths = path.nil? ? nil : [path]
    end

    def schema_path = @schema_path || "app/graphql/schema.json"

    # The shared-inputs / shared-unions module names: set them globally, pass
    # inputs_module:/unions_module: per generate!, or let them derive from the
    # output path — the directory above generated/ names the schema in
    # multi-schema layouts (app/graphql/github/generated => GithubInputs /
    # GithubUnions); the conventional layout (and anything unrecognizable)
    # stays GraphQLInputs / GraphQLUnions.
    attr_writer :inputs_module, :unions_module

    def inputs_module(output = generated_path)
      @inputs_module || derive_module("Inputs", output)
    end

    def unions_module(output = generated_path)
      @unions_module || derive_module("Unions", output)
    end

    # Name a shared module from the output path: <Schema><suffix> in a
    # multi-schema layout, else GraphQL<suffix>.
    def derive_module(suffix, output)
      segments = File.expand_path(output.to_s).split(File::SEPARATOR)
      segments.pop if segments.last == "generated"
      parent = segments.last.to_s
      if parent.match?(/\A[a-zA-Z]\w*\z/) && !%w[graphql app lib spec support test].include?(parent)
        "#{Inflect.camelize(parent)}#{suffix}"
      else
        "GraphQL#{suffix}"
      end
    end
    private :derive_module

    # Generate every .graphql query in a directory into checked-in Ruby
    # files. Paths default to the conventions above; schema: defaults to
    # the dump at schema_path (any supported extension):
    #
    #      GraphWeaver.generate!   # queries_path -> generated_path
    #
    # person.graphql => person_query.rb defining PersonQuery. Returns the
    # written paths. Pair with a freshness spec (docs/generated_modules.md).
    def generate!(schema: nil, queries: queries_path, output: generated_path, client: nil,
      inputs_module: nil, unions_module: nil)
      schema ||= locate_schema!
      inputs_module ||= self.inputs_module(output)
      unions_module ||= self.unions_module(output)

      plan = generation_plan(queries:, schema:, client:, inputs_module:, unions_module:)
      written = plan.map do |filename, source|
        target = File.join(output, filename)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, source)
        log(:info) { "generated #{target}" }
        target
      end

      # a type dropped from the schema (or a union no longer hoisted) must not
      # linger as a stale file — inputs/ and unions.rb are wholly generated
      (shared_artifacts(output) - written).each do |orphan|
        File.delete(orphan)
        log(:info) { "pruned #{orphan}" }
      end

      written
    end

    # The wholly-generated shared-artifact files under output (inputs/*.rb and
    # unions.rb) — safe to prune when regeneration no longer produces them.
    def shared_artifacts(output)
      Dir[File.join(output, "inputs", "*.rb")] + Dir[File.join(output, "unions.rb")]
    end
    private :shared_artifacts

    # The freshness guard: raise unless every generated file matches what
    # the current schema + queries + scalar registrations would produce.
    # One line in a spec, or `rake graph_weaver:verify` in CI:
    #
    #      it "generated queries are current" do
    #        GraphWeaver.verify_generated!
    #      end
    def verify_generated!(schema: nil, queries: queries_path, output: generated_path, client: nil,
      inputs_module: nil, unions_module: nil)
      schema ||= locate_schema!
      inputs_module ||= self.inputs_module(output)
      unions_module ||= self.unions_module(output)
      plan = generation_plan(queries:, schema:, client:, inputs_module:, unions_module:)
      stale = plan.filter_map do |filename, source|
        target = File.join(output, filename)
        target unless File.exist?(target) && File.read(target) == source
      end
      # strays: a shared-artifact file the current schema + queries no longer produce
      stale += shared_artifacts(output) - plan.map { |f, _| File.join(output, f) }

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
    def load_generated!(path = nil)
      paths = path ? [path] : generated_paths
      files = paths.flat_map { |dir| Dir[File.join(dir, "**/*.rb")].sort }.uniq
      files.each { |file| require File.expand_path(file) }
      log(:info) { "loaded #{files.size} generated module(s) from #{paths.join(", ")}" }
      files
    end

    # the conventional schema dump, required
    def locate_schema!
      SchemaLoader.locate or raise Error,
        "no schema dump at #{schema_path} (.json/.graphql/.gql) — pass schema:, or cache one: GraphWeaver.new(url, cache: true).schema"
    end
    private :locate_schema!

    # (filename, source) per artifact. Every variable type is emitted once into
    # inputs.rb, and each named shared fragment spread as a whole-union field
    # once into unions.rb, with query modules aliasing what they use — the
    # difference between hundreds of duplicated bool_exp structs (or the same
    # union re-typed per query) and one copy per schema. (Single-query parse
    # inlines both — there's no cross-query set to share against.)
    def generation_plan(queries:, schema:, client:, inputs_module: self.inputs_module,
      unions_module: self.unions_module, fragments: fragments_paths)
      used = { inputs: [], enums: [], mapped: [] }
      used_unions = []
      shared = Codegen.load_fragments(fragments)

      plan = Dir[File.join(queries, "*.graphql")].sort.map do |path|
        base = File.basename(path, ".graphql")
        source = File.read(path)
        codegen = Codegen.new(
          schema:,
          query: Codegen.inline_fragments(source, shared),
          module_name: "#{Inflect.camelize(base)}Query",
          client:,
          inputs_namespace: inputs_module,
          unions_namespace: unions_module,
          hoistable_unions: Codegen.shared_fragment_spreads(source, shared),
        )
        out = codegen.generate
        codegen.variable_type_names.each { |kind, names| used[kind] |= names }
        used_unions |= codegen.used_union_names
        ["#{base}_query.rb", out]
      end

      if inputs_module && used.values.any?(&:any?)
        inputs = Codegen.generate_inputs(
          schema:, module_name: inputs_module,
          input_types: used[:inputs], enum_types: used[:enums] + used[:mapped],
        )
        plan = inputs.to_a + plan
      end

      if unions_module && used_unions.any?
        unions = Codegen.generate_unions(
          schema:, module_name: unions_module, fragments: shared, names: used_unions,
        )
        plan = unions.to_a + plan
      end

      plan
    end
    private :generation_plan

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

    # Whether generated modules/structs emit `extend T::Sig` (so `sig`
    # resolves standalone). Default (nil) auto-detects: an app that globally
    # injects T::Sig (`class Module; include T::Sig`) makes the per-struct
    # extend redundant — rubocop's Sorbet/RedundantExtendTSig flags it — so
    # generation skips it. Force with true/false. Resolved at generation time.
    #
    #      GraphWeaver.extend_t_sig = false   # never emit (rely on a global include)
    attr_writer :extend_t_sig

    # The resolved boolean codegen uses: the explicit setting, else emit
    # unless T::Sig is globally injected into Module.
    def extend_t_sig?
      @extend_t_sig.nil? ? !global_tsig? : @extend_t_sig
    end

    # Whether the host app has globally injected T::Sig into every module
    # (`class Module; include T::Sig`) — extracted so it's stubbable in tests.
    def global_tsig? = Module.include?(T::Sig)

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
    #
    # Pass a `Type.field` coordinate instead of a scalar name to override just
    # that one field — so the same scalar can deserialize as different Ruby
    # types across fields (a `Date` for `User.birthday`, a `Time` elsewhere):
    #
    #      GraphWeaver.register_scalar("User.birthday", Date)
    #
    # A field-level override wins over the scalar-name registration. Same
    # signature either way. Call before generating.
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
    # GraphQL type — derived values live as methods next to the honest wire
    # data, on the struct at runtime (fakes/cassettes included):
    #
    #      GraphWeaver.extend_type("Pet", PetHelpers)
    #
    # A helper that reads a wire field is checked by srb tc in the module's
    # own scope, not the struct's, so the field won't resolve — write it
    # # typed: false or reach it via T.unsafe(self). Or build the mixin inline
    # with a block (module_eval'd into an auto-named module — invisible to srb):
    #
    #      GraphWeaver.extend_type("Pet") do
    #        def display_name = "#{name} the pet"
    #      end
    #
    # Additive (repeated and client-scoped registrations stack). Global;
    # client.extend_type scopes to one client.
    def extend_type(graphql_name, *mixins, requires: nil, &block)
      Codegen.extend_type(graphql_name, *mixins, requires:, &block)
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
    # override, client: to bake the module's default client/transport.
    def parse(schema:, query:, name: nil, client: nil, scalars: nil, enums: nil, types: nil,
      fragments: fragments_paths)
      if query.end_with?(".graphql", ".gql")
        name ||= "#{Inflect.camelize(File.basename(query, ".*"))}Query"
        query = File.read(query)
      end
      query = Codegen.inline_fragments(query, Codegen.load_fragments(fragments))

      Codegen.parse(schema:, query:, module_name: name, client:, scalars:, enums:, types:)
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
    # generated module (nothing reserved). execute returns the
    # Response envelope, execute! the typed result, raising QueryError on
    # top-level errors.
    def execute(source, query, **variables)
      client = source.is_a?(Client) ? source : Client.new(source)
      client.execute(query, **variables)
    end

    # execute + data! — the typed result, or a raised QueryError. See execute.
    def execute!(source, query, **variables)
      execute(source, query, **variables).data!
    end
  end
end
