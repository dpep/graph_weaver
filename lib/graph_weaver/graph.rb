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

    # Each of these falls back to the matching top-level setting, so a graph
    # says only what differs. output is one directory (a graph writes to one
    # place); generated_paths stays the list of places to READ from.
    def initialize(name: nil, schema: nil, queries: nil, output: nil, client: nil,
      namespace: nil, types_module: nil, registry: nil, &registrations)
      @name = name
      @schema = schema
      @queries = queries
      @output = output
      @client = client
      @namespace = namespace
      @types_module = types_module
      @registry = registry || GraphWeaver::Codegen::Registry.new
      # deferred: an app registers its own constants, and in Rails those don't
      # resolve while config/initializers run (Codegen::AUTOLOAD_HINT). Running
      # at generation time also keeps re-running it idempotent — the block only
      # ever fills a registry that was built for it.
      @registrations = registrations
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
    # to a dump, SDL. Resolved each time rather than memoized — in dev the
    # class object is replaced on reload, as Internal::Util.live_schema notes.
    def schema
      @schema ? GraphWeaver::Internal::Util.schema_for(@schema) : GraphWeaver::Internal::Util.locate_schema!
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

      path = @schema.respond_to?(:to_path) ? @schema.to_path : @schema
      path if path.is_a?(String) && File.exist?(path)
    end

    # The graphql-ruby schema class this graph runs in-process, or nil. The
    # default graph's is the app client's (Internal::Util.live_schema).
    def live_schema
      return GraphWeaver::Internal::Util.live_schema unless @schema

      @schema if @schema.is_a?(Class) && @schema <= GraphQL::Schema
    end

    # The module `path` generates, and the file it lands in. The namespace is
    # the only thing a graph adds to the naming rule; the rest is the file name,
    # as it is everywhere else.
    def generated_names(path, source)
      module_name, filename = GraphWeaver::Internal::Util.generated_names(path, source)
      [namespace ? "#{namespace}::#{module_name}" : module_name, filename]
    end

    # This graph's registrations, with its block applied. The block runs the
    # first time anything asks — generation, or a fake deciding what a scalar
    # looks like on the wire — rather than at declaration, so an autoloaded
    # constant has resolved by then. Idempotent: it fills a registry built for
    # it, once.
    def registry
      if @registrations
        registrations, @registrations = @registrations, nil
        @registry.instance_exec(&registrations)
      end
      @registry
    end

    # How a message names this graph: " in graph :billing", or nothing at all
    # for the default one, so a single-schema app's errors are unchanged.
    def described = name ? " in graph #{name.inspect}" : ""
  end
end
