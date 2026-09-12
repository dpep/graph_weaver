# typed: true
# frozen_string_literal: true

# One schema and everything generation needs to know about it: where its
# queries live, where its Ruby goes, which client its modules call, what its
# custom scalars and enums mean, and the namespace that keeps its constants
# off another graph's.
#
# An app has at least one. The top-level settings (GraphWeaver.schema_path,
# queries_paths, generated_paths, types_module) describe it, so a single-schema
# app never says the word "graph" — and a second schema is a second graph
# rather than a second copy of the recipe.

module GraphWeaver
  class Graph
    # nil for the default graph — the one the settings describe, which has
    # nothing to be called because there is nothing to tell it apart from.
    attr_reader :name

    # The registrations this graph generates with. A declared graph gets a copy
    # of the top-level ones plus whatever its block added, taken as it is
    # declared — so a top-level register_scalar belongs above the declarations
    # it should reach. The default graph holds the top-level registry itself.
    attr_reader :registry

    # Each of these falls back to the matching top-level setting, so a graph
    # says only what differs. output is one directory (a graph writes to one
    # place); generated_paths stays the list of places to READ from.
    def initialize(name: nil, schema: nil, queries: nil, output: nil, client: nil,
      namespace: nil, types_module: nil, registry: nil)
      @name = name
      @schema = schema
      @queries = queries
      @output = output
      @client = client
      @namespace = namespace
      @types_module = types_module
      @registry = registry || GraphWeaver::Codegen.registry
    end

    def queries = @queries || GraphWeaver.queries_paths
    def output = @output || GraphWeaver.generated_paths.first
    def client = @client

    # Every constant this graph generates lives under `namespace:` — the query
    # modules and the shared types module alike. Two schemas that each have a
    # person.graphql, or that each hoist an enum, otherwise fight over one
    # constant; this is the one knob that settles both.
    def namespace = @namespace

    def types_module
      @types_module || (namespace ? "#{namespace}::#{GraphWeaver.types_module}" : GraphWeaver.types_module)
    end

    # The graphql-ruby schema, however it was named: a class, a Client, a path
    # to a dump, SDL, or a callable returning one. Resolved each time rather
    # than memoized — in dev the class object is replaced on reload, as
    # Internal::Util.live_schema notes, and a callable is how an initializer
    # names a class Zeitwerk hasn't loaded yet.
    def schema
      return GraphWeaver::Internal::Util.locate_schema! unless @schema

      GraphWeaver::Internal::Util.schema_for(named_source)
    end

    # Whether this graph names its own schema. The default graph doesn't — it
    # is whatever dump is at schema_path — which is what lets check_queries
    # re-introspect that one and leave a named schema alone.
    def named_schema? = !@schema.nil?

    # The dump this graph's schema was named by, when it was named by a file —
    # what a validation error's subgraph branding is read off. nil for a live
    # class, a Client, or inline SDL.
    def dump_path
      return GraphWeaver::SchemaLoader.locate_path unless @schema

      source = named_source
      path = source.respond_to?(:to_path) ? source.to_path : source
      path if path.is_a?(String) && File.exist?(path)
    end

    # The composed supergraph this graph plans against, or nil — the dump it
    # names (for the default graph, the conventional one) when that dump
    # carries the @join__* routing table. A graph whose schema is an API
    # schema, or a live class, is in no supergraph of its own.
    #
    # One rule, asked by everything that needs one: the federation rake tasks
    # report per graph off this, and Testing::Config resolves :router's
    # supergraph through it.
    def supergraph
      path = dump_path
      path if path && GraphWeaver::Internal::Util.composed?(path)
    end

    # The graphql-ruby schema class this graph runs in-process, or nil. The
    # default graph's is the app client's (Internal::Util.live_schema).
    def live_schema
      return GraphWeaver::Internal::Util.live_schema unless @schema

      source = named_source
      source if source.is_a?(Class) && source <= GraphQL::Schema
    end

    # What `schema:` was given, with a callable called. A Proc is how an
    # initializer names an autoloaded class; calling it here rather than at
    # declaration is the whole point of allowing one.
    def named_source = @schema.respond_to?(:call) ? @schema.call : @schema
    private :named_source

    # The module `path` generates, and the file it lands in. The namespace is
    # the only thing a graph adds to the naming rule; the rest is the file name,
    # as it is everywhere else.
    def generated_names(path, source)
      module_name, filename = GraphWeaver::Internal::Util.generated_names(path, source)
      [namespace ? "#{namespace}::#{module_name}" : module_name, filename]
    end

    # How a message names this graph: " in graph :billing", or nothing at all
    # for the default one, so a single-schema app's errors are unchanged.
    def described = name ? " in graph #{name.inspect}" : ""
  end

  module Internal
    # What a `GraphWeaver.graph` block is evaluated against: it collects the
    # settings, runs the registrations, and refuses everything else — a typo
    # is a mistake worth a message, not a call that vanishes.
    #
    # A separate object rather than the Graph itself, so a block can't reach a
    # Graph's internals and a Graph stays a plain value. An app writes the
    # block and never names this.
    class GraphBuilder
      # Everything a graph can say, in the order the docs teach it. `schema "x"`
      # sets and bare `schema` reads back — there is no `schema =` form, because
      # instance_eval would make that a local variable that silently does nothing.
      SETTINGS = %i[schema queries output client namespace types_module].freeze
      # The same three calls an app already writes at the top level, scoped here
      # to this graph alone.
      REGISTRATIONS = %i[register_scalar register_enum extend_type].freeze
      # These three end up spelled in generated source, so each takes the
      # constant or its name and stores the name.
      CONSTANT_SETTINGS = %i[client namespace types_module].freeze
      private_constant :CONSTANT_SETTINGS

      attr_reader :settings, :registry

      # The Graph a block describes.
      def self.build(name, &block)
        builder = new(name)
        builder.instance_eval(&block)
        GraphWeaver::Graph.new(name:, registry: builder.registry, **builder.settings)
      rescue NameError => e
        # Ruby raises on the argument before the registration is ever called, so
        # the block is the only place that can say why — and in Rails this is
        # the commonest way to meet it. NoMethodError is a NameError too, and
        # means something else entirely.
        raise if e.is_a?(NoMethodError)

        raise e.class, "#{e.message} — a graph block runs where it is written, so a registration " \
          "in it stands where a top-level one does. #{GraphWeaver::Codegen::AUTOLOAD_HINT} " \
          "Declare graph #{name.inspect} from one.", e.backtrace
      end

      def initialize(name)
        @name = name
        @settings = {}
        # the top-level registrations, copied as the graph is declared, with the
        # block's own added on top
        @registry = GraphWeaver::Codegen.registry.dup
      end

      SETTINGS.each do |setting|
        define_method(setting) do |*value|
          return @settings[setting] if value.empty?
          raise ArgumentError, "#{setting} takes one value, got #{value.size}" if value.size > 1

          @settings[setting] = GraphBuilder.constant_name(setting, value.first)
        end
      end

      REGISTRATIONS.each do |registration|
        define_method(registration) do |*args, **kwargs, &block|
          @registry.public_send(registration, *args, **kwargs, &block)
        end
      end

      def method_missing(name, *, **, &) = raise(ArgumentError, refusal(name))

      # Nothing reaches method_missing but a mistake, so the honest answer for
      # every name it would catch is false.
      def respond_to_missing?(name, _private = false) = false

      # A Module where a constant's name goes says the same thing, and is what
      # `client Billing::CLIENT` reads like. Anything else passes through:
      # a schema is a path, SDL, a class, a Client, or a callable.
      # On the singleton so the define_method setters above can reach it — srb
      # reads a define_method block's self as the class.
      def self.constant_name(setting, value)
        return value unless CONSTANT_SETTINGS.include?(setting) && value.is_a?(Module)

        value.name || raise(ArgumentError, "#{setting} needs a constant — generated source has " \
          "to spell it — and #{value.inspect} is anonymous")
      end

      def refusal(name)
        takes = SETTINGS + REGISTRATIONS
        near = GraphWeaver::Internal::Util.did_you_mean(takes.map(&:to_s), name.to_s)
        "#{name} isn't something a graph block takes#{near ? " (did you mean #{near}?)" : ""} — " \
          "graph #{@name.inspect} takes #{takes.join(", ")}"
      end
      private :refusal
    end
  end
end
