# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "codegen"

module GraphWeaver
  # Anything that holds a schema parses against it. That's a Client, an
  # InProcess wrapper, a FakeClient, and the test Router — each of which
  # already has the two things parsing needs, a schema to check the query
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
      GraphWeaver.parse(schema: T.unsafe(self).schema, query:, name:, client: parse_client)
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
      Dir[File.join(dir || GraphWeaver.queries_path, GraphWeaver::Codegen::DOCUMENT_GLOB)].sort.map do |path|
        name = GraphWeaver.module_name(path, File.read(path))
        if namespace.const_defined?(name, false)
          # the constant moves, its instances don't — a struct built before the
          # reload keeps failing is_a? against the new module, silently
          GraphWeaver.log(:info) do
            "replacing #{name} — objects built from the previous module stay instances of it"
          end
          namespace.send(:remove_const, name)
        end
        GraphWeaver.log(:info) { "loaded #{name} from #{path}" }
        namespace.const_set(name, parse(path))
      end
    end

    private

    # What a parsed module executes through: this object, which holds the
    # schema and runs queries. Client is the one that overrides it — its own
    # #execute is the one-shot parse-and-run, not the client contract, so it
    # bakes the transport it wraps.
    def parse_client = self
  end
end
