# typed: true
# frozen_string_literal: true

require "graphql"

require_relative "inflect"

module GraphWeaver
  # Not API. Anything under GraphWeaver::Internal is the gem talking to
  # itself and may change or vanish in any release — it is the home for a
  # helper that would otherwise have to go public just because a second file
  # needs it. bin/public-surface skips this namespace, so moving something
  # here is how you take it off the locked public surface.
  #
  # Not private_constant: most of this gem defines its classes compactly
  # (`class GraphWeaver::Codegen`), which puts GraphWeaver outside their
  # lexical scope, so a private constant would be unreachable from exactly
  # the files that need it. The name and the surface lock carry the rule.
  module Internal
    # Odds and ends several files share. Each is here because more than one
    # caller needs it, not because it belongs together with the others.
    module Util
      class << self
        # Replace a file's contents in one step. The schema dump and a
        # cassette are artifacts people commit, and File.write truncates
        # before it writes — so an interrupted run, or a second writer (a
        # rake task beside a running app, two Puma workers), can leave a
        # half-written file that no longer parses. A rename is atomic on
        # POSIX: a reader sees the old file or the new one, never a prefix.
        def atomic_write(path, content)
          tmp = File.join(File.dirname(path),
            ".#{File.basename(path)}.#{Process.pid}.#{Thread.current.object_id}.tmp")
          File.write(tmp, content)
          File.rename(tmp, path)
        ensure
          File.unlink(tmp) if tmp && File.exist?(tmp)
        end

        # The closest entry in `dictionary` to `term` — a "did you mean"
        # suggestion, or nil (also nil when did_you_mean isn't loadable). One
        # home for the guard used by codegen validation, alias resolution,
        # and the runtime prop hints.
        def did_you_mean(dictionary, term)
          return unless defined?(DidYouMean::SpellChecker)

          DidYouMean::SpellChecker.new(dictionary: dictionary).correct(term).first
        end

        # The module a .graphql file generates, and the basename of the file
        # it generates into: the camelized file name plus the operation's own
        # word.
        #
        #      person.graphql          => PersonQuery       (person_query.rb)
        #      save_list_entry.graphql => SaveListEntryMutation
        #                                 (save_list_entry_mutation.rb)
        #
        # Every naming site goes through here — generate!, parse(path), and
        # load_queries! — so the constant a file produces is the same one
        # whichever door you came in by, and the file it lands in matches it.
        def generated_names(path, source)
          base = File.basename(path, ".*")
          suffix = operation_suffix(source)
          ["#{Inflect.camelize(base)}#{suffix}", "#{base}_#{suffix.downcase}.rb"]
        end

        # just the module name — see generated_names
        def module_name(path, source) = generated_names(path, source).first

        # Every query document under these directories, sorted — the files
        # generate!, verify_generated!, check_queries and load_queries! read.
        def query_files(paths = GraphWeaver.queries_paths)
          Array(paths).flat_map { |dir| Dir[File.join(dir, Codegen::DOCUMENT_GLOB)].sort }
        end

        # The graphql-ruby schema class the app default executes against,
        # when it runs in-process — a Client wrapping one, or the class in
        # the slot bare. nil for every network client. Not memoized: in dev
        # the class object is replaced on reload.
        def live_schema
          # through #transport, not #schema: a url client's #schema
          # introspects, so asking it would answer over the network
          client = GraphWeaver.client
          target = client.is_a?(Client) ? client.transport : client
          target = target.schema if target.is_a?(InProcess)
          target if target.is_a?(Class) && target <= GraphQL::Schema
        end

        private

        # "Mutation" for a mutation document, "Query" for everything else.
        def operation_suffix(source)
          operation = GraphQL.parse(source).definitions
            .grep(GraphQL::Language::Nodes::OperationDefinition).first
          (operation&.operation_type == "mutation") ? "Mutation" : "Query"
        rescue GraphQL::ParseError
          "Query" # unparseable: codegen brands the real error a moment later
        end
      end
    end

    # What every client slot wants to know about a request before it goes
    # out: what the document itself says, and how the log refers to it.
    # Lived on Transport, which users subclass — the worst place for it.
    module Wire
      # The name of the document's FIRST operation, nil when anonymous. Only
      # the fallback for a raw query string handed straight to a transport —
      # generated modules pass their OPERATION_NAME, parsed properly.
      OPERATION_NAME_PATTERN = /\A\s*(?:query|mutation|subscription)\s+([A-Za-z_]\w*)/
      private_constant :OPERATION_NAME_PATTERN

      # Whether this document's operation writes — what Retry asks before
      # repeating a request. Line-anchored rather than parsed: it runs on
      # every request, and the only way to be wrong (a field literally named
      # `mutation` opening a line) errs toward not retrying.
      MUTATION_PATTERN = /^[ \t]*mutation\b/
      private_constant :MUTATION_PATTERN

      REQUEST_MUTEX = Mutex.new
      private_constant :REQUEST_MUTEX

      # keep debug readable: a 100-line introspection query would drown the
      # log — the INFO introspection line already carries the timing
      LOG_QUERY_LIMIT = 600
      private_constant :LOG_QUERY_LIMIT

      class << self
        def operation_name(query) = query[OPERATION_NAME_PATTERN, 1]

        def mutation?(query) = MUTATION_PATTERN.match?(query)

        # "[req 3 FilteredPokemon]" — a per-process request id plus the
        # operation name, when there is one
        def log_tag(operation_name = nil)
          id = REQUEST_MUTEX.synchronize { @request_count = (@request_count || 0) + 1 }
          "[req #{id}#{" #{operation_name}" if operation_name}]"
        end

        def truncate_for_log(query)
          return query if query.length <= LOG_QUERY_LIMIT

          "#{query[0, LOG_QUERY_LIMIT]}... (truncated, #{query.bytesize} bytes total)"
        end
      end
    end
  end
end
