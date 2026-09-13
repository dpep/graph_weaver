# typed: true
# frozen_string_literal: true

require "graphql"
require "json"

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

        # "a" or "an" for a word an error message is about to name.
        def article(word) = word.downcase.start_with?(/[aeiou]/) ? "an" : "a"

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

        # The one sentence about scalars nothing registered — said on the
        # logger per parse and once per run by the build, and worth saying
        # identically in both. Keyed by graph name (nil for an app with no
        # declared graphs): a registration is scoped to one graph, so merging
        # the names across several would read as "forgotten everywhere" for a
        # scalar registered for one of them and forgotten for the next.
        def untyped_scalars_report(by_graph)
          found = by_graph.reject { |_, names| names.empty? }
          return if found.empty?

          advice = "(register with GraphWeaver.register_scalar)"
          # One graph ran, so there is nothing to attribute — including when it
          # is the only one with findings is what made a forgetful graph read
          # as a forgetful app.
          if by_graph.one?
            names = found.values.first.sort
            return "#{names.size} unregistered custom scalar#{"s" unless names.one?} → T.untyped: " \
              "#{names.join(", ")} #{advice}"
          end

          ["unregistered custom scalars → T.untyped #{advice}:",
            *found.map { |graph, names| "  graph #{graph.inspect}: #{names.sort.join(", ")}" }].join("\n")
        end

        # A path setting, as a real path: relative to GraphWeaver.root, which
        # is the app root and not wherever the process was started. Every
        # filesystem access on a configured path goes through here; the
        # settings themselves keep returning what was configured, so an error
        # message stays short and graphql.config.yml stays portable.
        def resolve(path) = File.expand_path(path.to_s, GraphWeaver.root)

        # The other half of that rule: a path this gem REPORTS — returned,
        # logged, or quoted in an error — comes back in the short form the
        # settings use, so a build log reads the same on the next machine and
        # names something you can paste. A path outside the root (an absolute
        # setting) is left as it is: relative to somewhere else it names no file.
        def relative(path)
          path = path.to_s
          prefix = File.join(GraphWeaver.root, "") # trailing separator; "/" stays "/"
          path.start_with?(prefix) ? path.delete_prefix(prefix) : path
        end

        # The registrations a schema generates with: the graph that named it,
        # or the default graph's. The testing fakes ask, so a fabricated
        # scalar is the shape the module generated against that schema will
        # cast — a `Money` registered for one graph is not a `Money` for the
        # next one along. Matched on the schema class a graph runs in-process,
        # which is the only identity cheap enough to ask per fake; anything
        # else falls back to the default, which is where a single-schema app
        # has always read from.
        def registry_for(schema) = graph_for(schema)&.registry || Codegen.registry

        # The declared graph that runs `schema` in-process, or nil. Matched on
        # the schema class a graph runs, which is the only identity cheap
        # enough to ask per call — a dump would have to be re-read, and
        # re-reading it gives a different object every time. GraphWeaver.parse
        # asks too, to bake the GRAPH a generated file would have carried.
        def graph_for(schema)
          schema && GraphWeaver.graphs.find { |candidate| candidate.live_schema.equal?(schema) }
        end

        # Where generated modules are READ from: the configured patterns, plus
        # any graph writing somewhere they don't already cover. generated_paths'
        # default glob (app/graphql/*/generated) covers the conventional layout,
        # so listing a graph's output as well would name the same directory
        # twice — in the log, and in the globbing.
        #
        # FNM_PATHNAME because Dir.glob is what expands these patterns
        # everywhere else (Zeitwerk's ignore, load_generated!) and its * stops
        # at a /. Without it app/graphql/*/generated "covered"
        # app/graphql/a/b/generated, which was then neither ignored nor loaded.
        def generated_dirs
          extra = GraphWeaver.graphs.map(&:output).reject do |dir|
            GraphWeaver.generated_paths.any? do |pattern|
              File.fnmatch?(resolve(pattern), resolve(dir), File::FNM_PATHNAME)
            end
          end
          GraphWeaver.generated_paths | extra
        end

        # Every query document under these directories, sorted — the files
        # generate!, verify_generated!, check_queries and load_queries! read.
        def query_files(paths = GraphWeaver.queries_paths)
          Array(paths).flat_map { |dir| Dir[File.join(resolve(dir), Codegen::DOCUMENT_GLOB)].sort }
        end

        # Anywhere GraphWeaver takes schema:, a Client stands for its schema — so
        # the console object and the rake task point at the same thing. A path
        # (String or Pathname) or SDL loads like it does everywhere else in the
        # library; without that it reached `schema.validate` as itself and failed
        # as `undefined method 'validate' for an instance of String`.
        def schema_for(source)
          return source.schema if source.is_a?(Client)
          return SchemaLoader.load(source) if source.is_a?(String) || source.respond_to?(:to_path)

          source
        end

        # Whether this source carries the @join__* routing table, i.e. is a
        # composed supergraph rather than an API schema. The one place that
        # asks: Graph#supergraph reads it per graph, Testing::Config for the
        # app-wide fallbacks, and the federation rake tasks through both.
        #
        # Kept per source for the life of the process — parsing a supergraph
        # is milliseconds and :wire asks per example — and keyed on what the
        # file IS, since the answer is a property of its content. A supergraph
        # recomposed at a stable path (a `before` hook, chained rake tasks)
        # used to be answered from the previous composition, which routed a
        # graph into the wrong plan or refused it as being in none.
        def composed?(source)
          @composed ||= {}
          key = composed_key(source)
          return @composed[key] if @composed.key?(key)

          @composed[key] = begin
            SchemaLoader.routing_table?(source)
          rescue GraphWeaver::Error
            # a source that can't even be read is in no supergraph either —
            # and that Error is worth its warn line, where "not federated"
            # never was
            false
          end
        end

        # the conventional schema dump, required
        def locate_schema!
          SchemaLoader.locate or raise GraphWeaver::Error,
            "no schema dump at #{GraphWeaver.schema_path} (.json/.graphql/.gql) — pass schema:, " \
            "or cache one: GraphWeaver.new(url, cache: true).schema"
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

        # The context to hand resolvers. A proc is answered from a request's
        # headers (Testing::Endpoint resolves it), so off the wire there is
        # nothing to answer it with — and a Proc reaching graphql-ruby as a
        # context fails far from the line that set it.
        def context!(context)
          return context unless context.respond_to?(:call)

          raise GraphWeaver::Error, "context: is a proc, so it is answered from a request's " \
            "headers — and nothing here made a request. Tag the example graphql: :wire, which " \
            "serves your resolvers at your client's endpoint so your transport's headers reach " \
            "them; off the wire, pass the hash."
        end

        private

        # What makes a composed? answer stale. Both callers pass a path that
        # exists, so the file's identity is its stat — size as well as mtime,
        # because a coarse mtime can miss two writes in one tick. Anything
        # that isn't a path (SDL, a class) is its own key.
        def composed_key(source)
          stat = File.stat(source.to_s)
          [source.to_s, stat.mtime, stat.size]
        rescue SystemCallError
          source
        end

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

    # What makes two GraphQL requests the same request — and how one reads
    # when an error has to quote it. A cassette matches on this, so the
    # rules belong somewhere both the cassette and the error that reports a
    # miss can say, rather than on the class one of them happens to be.
    module RequestKey
      class << self
        # The request's identity, exactly as the server sees it.
        # operationName is part of that: it picks the operation the document
        # runs, so two requests with identical text but different names are
        # different requests. Derived, never stored — the file holds the
        # request once, so a hand-edited entry can't disagree with what
        # replay matches on.
        def for(query, variables, operation_name = nil)
          key = { "query" => normalize_query(query), "variables" => normalize_variables(variables) }
          key["operationName"] = operation_name if operation_name
          key
        end

        def for_entry(entry) = self.for(entry["query"], entry["variables"], entry["operationName"])

        def normalize_query(query) = query.gsub(/\s+/, " ").strip

        # JSON round-trip so symbol keys become strings — otherwise
        # YAML.dump writes Ruby symbols the safe loader rejects on the next
        # run, and lookup keys stay stable across processes
        def normalize_variables(variables) = JSON.parse(Wire.json(variables || {}))

        # one readable line: an error naming a 60-line query is a wall, not a hint
        def summarize(query, limit: 160)
          normalized = normalize_query(query)
          (normalized.length > limit) ? "#{normalized[0, limit]}…" : normalized
        end
      end
    end

    # The GraphQL wire format, either direction: what a request document
    # says about itself, how the log refers to it, and the shape a response
    # carries an error in. Lived on Transport and Router, both of which
    # users touch — the worst place for it.
    module Wire
      # JSON for the wire, or the caller's bug named under the umbrella: a
      # value with no JSON form (NaN, Infinity, binary) raised a raw JSON::
      # error from wherever it was first encoded — the transport, a cassette
      # key, a log line — so every encoder goes through here.
      def self.json(value)
        JSON.generate(value)
      rescue JSON::GeneratorError => e
        raise GraphWeaver::Error, "variables are not JSON-serializable: #{e.message}"
      end

      # The half of that discipline JSON doesn't raise for. JSON.generate
      # carries a String, a number, a boolean, null, a list and an object;
      # anything else it renders as the value's #to_s — right for a Date or
      # a Symbol, a memory address for a File, which then sits in the
      # server's database looking like it meant something. So a variable
      # whose #to_s is Ruby's debug form, or that is a stream whose bytes
      # JSON can't carry at all, is refused before the body is built.
      def self.check_variables!(variables)
        variables&.each { |name, value| check_variable!(name.to_s, value) }
      end

      def self.check_variable!(path, value)
        case value
        when Hash then value.each { |key, nested| check_variable!("#{path}.#{key}", nested) }
        when Array then value.each_with_index { |nested, i| check_variable!("#{path}[#{i}]", nested) }
        when String, Symbol, Numeric, true, false, nil then nil
        else
          raise GraphWeaver::Error, variable_refusal(path, value) if value.respond_to?(:read) ||
            value.to_s.start_with?("#<")
        end
      end
      private_class_method :check_variable!

      # A stream and an anonymous object fail the same way and need different
      # next steps: one is a feature this client doesn't have, the other is a
      # value that never said what it is.
      def self.variable_refusal(path, value)
        if value.respond_to?(:read)
          "$#{path} is a #{value.class} — graph_weaver posts application/json and doesn't implement " \
            "the GraphQL multipart request spec, so a file can't ride along; send what the server " \
            "expects as JSON, or POST the upload with your own transport"
        else
          "$#{path} is a #{value.class}, which has no JSON form — it would go on the wire as " \
            "#{value.to_s.inspect}; send a String, a number, a boolean, a list, or an object"
        end
      end
      private_class_method :variable_refusal

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

        # one error in the shape a GraphQL response carries them
        def graphql_error(message, code)
          { "message" => message, "extensions" => { "code" => code } }
        end

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
