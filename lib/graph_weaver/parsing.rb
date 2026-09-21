# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "codegen"
require_relative "internal"

module GraphWeaver
  # Anything that holds a schema parses and checks against it. That's a
  # Client, an InProcess wrapper, a FakeClient, and the test Router — each of
  # which already has the two things parsing needs, a schema to check the query
  # against and a client for the module to run on:
  #
  #      DashboardQuery = router.parse("query { me { username } }")
  #
  # so the long form (`GraphWeaver.parse(schema: router.schema, client:
  # router, query: ...)`) was only ever spelling out what the object knew.
  #
  # It is a convenience on top of the client contract, not part of it — the
  # client slot stays duck-typed, and a bare graphql-ruby schema class fills
  # it without including this.
  module Parsing
    # Parse a query (a .graphql path or raw string) into a typed module bound
    # to this schema, with this as the module's default client — the module
    # came from here, so it runs against here (a client passed to #execute
    # still wins, e.g. a fake). Same as GraphWeaver.parse(schema:, client:).
    def parse(query, name: nil)
      # #schema is the mixin's one requirement of its includer, and a module
      # has no way to declare that short of an abstract interface
      GraphWeaver.parse(schema: T.unsafe(self).schema, query:, name:, client: self)
    end

    # Does this query validate? The string form of GraphWeaver.check_queries,
    # answering with the same JSON-ready hashes — `message`, `line`, `column`,
    # plus `subgraphs` where a supergraph brands them — so an empty array means
    # it validates:
    #
    #      client.check_query("query { viewer { login } }")   # => []
    #      client.check_query("query { viewer { lgoin } }")
    #      # => [{ "message" => "Field 'lgoin' doesn't exist on type 'User'",
    #      #      "line" => 1, "column" => 17 }]
    #
    # Checked against this object's own schema — what `execute` would run
    # against — so a url client introspects on first use as it always does, and
    # nothing re-introspects the way check_queries defaults to. That is why it
    # lives here: inside an example `GraphWeaver.client` is a fake, an InProcess
    # or the test router, and each of those holds the schema the question is
    # about. An unparseable source is an entry like any other; nothing here
    # raises for a bad query. Shared fragments are inlined from fragments: the
    # same way every other door inlines them.
    def check_query(source, fragments: GraphWeaver.fragments_paths)
      # a dump-backed Client can brand each error with the subgraph it is
      # about; nothing else in the slot has a file behind its schema
      holder = T.unsafe(self)
      dump = holder.schema_source if holder.respond_to?(:schema_source)
      GraphWeaver::Internal::QueryCheck.errors(
        holder.schema, source, GraphWeaver::Codegen.load_fragments(fragments),
        GraphWeaver::Internal::QueryCheck.routing_table_for(dump),
      )
    end

    # Parse every query in a directory (subdirectories included) into typed
    # modules, named like generation would name them — the no-build-step
    # analog of generate! + load_generated!:
    #
    #      github.load_queries!                        # queries/person.graphql => ::PersonQuery
    #      github.load_queries!(namespace: Github)     # => Github::PersonQuery
    #                                                  # a mutation file => ::AdoptMutation
    #
    # Reloadable (constants are replaced), so it suits consoles and dev.
    # Returns the modules.
    def load_queries!(dir = nil, namespace: Object)
      GraphWeaver::Internal::Util.query_files(dir || GraphWeaver.queries_paths).map do |path|
        name = GraphWeaver::Internal::Util.module_name(path, File.read(path))
        if namespace.const_defined?(name, false)
          # the constant moves, its instances don't — a struct built before the
          # reload keeps failing is_a? against the new module, silently
          GraphWeaver::Internal::Log.log(:info) do
            "replacing #{name} — objects built from the previous module stay instances of it"
          end
          namespace.send(:remove_const, name)
        end
        GraphWeaver::Internal::Log.log(:info) { "loaded #{name} from #{GraphWeaver::Internal::Util.relative(path)}" }
        namespace.const_set(name, parse(path))
      end
    end
  end
end
