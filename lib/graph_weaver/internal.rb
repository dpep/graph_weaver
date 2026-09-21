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
    # The wire value the member register_enum fallback: true adds to a
    # generated enum serializes to. The GraphQL spec reserves a leading `__`,
    # so no schema can declare a value that collides with it.
    ENUM_FALLBACK_WIRE = "__other__"

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

        # how many entries a message names before it says "and N more"
        SAMPLE = 5
        private_constant :SAMPLE

        # A list a message names inline, held to a readable length — a wall
        # of schema coordinates says less than the first few and a count.
        def sample(list)
          return list.join(", ") if list.size <= SAMPLE

          "#{list.first(SAMPLE).join(", ")} and #{list.size - SAMPLE} more"
        end

        # The module a .graphql file generates, and the basename of the file
        # it generates into: the camelized file name plus the operation's own
        # word. Every run of non-alphanumerics in the name is a word boundary,
        # and a trailing extension naming the document's own operation kind is
        # dropped rather than doubled.
        #
        #      person.graphql          => PersonQuery       (person_query.rb)
        #      save_list_entry.graphql => SaveListEntryMutation
        #                                 (save_list_entry_mutation.rb)
        #      get-hello.graphql       => GetHelloQuery     (get_hello_query.rb)
        #      hello.query.graphql     => HelloQuery        (hello_query.rb)
        #
        # Every naming site goes through here — generate!, parse(path), and
        # load_queries! — so the constant a file produces is the same one
        # whichever door you came in by, and the file it lands in matches it.
        def generated_names(path, source)
          kind = operation_kind(source)
          base = strip_kind_extension(File.basename(path, ".*"), kind, path)
          stem = base.gsub(/[^A-Za-z0-9]+/, "_")
          suffix = (kind == "mutation") ? "Mutation" : "Query"
          name = Inflect.camelize(stem)
          # all punctuation camelizes to nothing, which would leave the suffix
          # standing alone as the whole name — keep the base so it stays refusable
          name = base if name.empty?
          ["#{name}#{suffix}", "#{stem}_#{suffix.downcase}.rb"]
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

        # The declared graph `name` names, or nil — how a generated module
        # finds the graph whose client it runs against, and whose schema a
        # test mode fabricates from.
        #
        # One graph in an app is the answer whatever a module calls it: a
        # module generated before its graph was named, or by an older release,
        # still belongs to the only graph there is. With several, guessing
        # would send one schema's query to another's endpoint.
        def graph_named(name)
          graphs = GraphWeaver.graphs
          return graphs.first if graphs.one?

          graphs.find { |graph| graph.name == name }
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

        # The graphql-ruby schema class a client executes against, when it
        # runs in-process — a Client wrapping one, or the class in the slot
        # bare. nil for every network client. Defaults to the app's own, and
        # a graph passes its client. Not memoized: in dev the class object is
        # replaced on reload.
        def live_schema(client = GraphWeaver.client)
          # through #transport, not #schema: a url client's #schema
          # introspects, so asking it would answer over the network
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

        # The document's operation kind — "query", "mutation" or
        # "subscription" — or nil when it holds no operation or won't parse.
        # The one source of truth for the word a module name ends in AND for
        # the file-name extension that word makes redundant.
        def operation_kind(source)
          operation = GraphQL.parse(source).definitions
            .grep(GraphQL::Language::Nodes::OperationDefinition).first
          operation && (operation.operation_type || "query") # `{ hello }` is shorthand for a query
        rescue GraphQL::ParseError
          nil # unparseable: codegen brands the real error a moment later
        end

        # GraphQL's operation kinds, as a file name spells them. Apollo, Relay
        # and GitLab's frontend all name a query file for its operation, so
        # `blob_content.query.graphql` says in the extension exactly what the
        # module's own suffix says — drop it rather than emit BlobContentQueryQuery.
        # `_query` inside a snake_case name is a word OF the name, not this, so
        # nothing that generates today is renamed.
        OPERATION_EXTENSION = /\.(query|mutation|subscription)\z/i
        private_constant :OPERATION_EXTENSION

        def strip_kind_extension(base, kind, path)
          declared = base[OPERATION_EXTENSION, 1]&.downcase
          stem = declared && base[0...-(declared.length + 1)]
          return base if stem.nil? || stem.empty?
          return stem if kind.nil? || kind == declared

          raise GraphWeaver::Error, "#{relative(path)}: the file name ends .#{declared}, but the " \
            "document defines a #{kind} — rename it #{stem}.#{kind}#{File.extname(path)} " \
            "or drop the .#{declared}"
        end
      end
    end

    # One query, checked against one schema. Both doors onto it —
    # GraphWeaver.check_queries (every file on disk) and Client#check_query
    # (a string) — report the same hashes and brand subgraphs the same way,
    # because the implementation lives here rather than once each.
    module QueryCheck
      class << self
        # A query's schema-validation errors as JSON-ready hashes, with the
        # source position graphql-ruby reports. Unparseable counts as an error
        # too — it doesn't validate either, and inline_fragments (which parses
        # first) has already branded it with its position.
        def errors(schema, source, shared, table = nil)
          # path omitted: check_queries keys its report by file, so branding the
          # message with it too would just print the path twice
          schema.validate(Codegen.inline_fragments(source, shared)).map do |error|
            detail = error.to_h
            location = detail["locations"]&.first || {}
            subgraphs = table ? attribute(table, detail["extensions"]) : []
            entry = {
              "message" => subgraphs.empty? ? error.message : "#{error.message} (#{subgraphs.join(", ")})",
              "line" => location["line"],
              "column" => location["column"],
            }
            subgraphs.empty? ? entry : entry.merge("subgraphs" => subgraphs)
          end
        rescue GraphWeaver::QueryValidationError => e
          # an unparseable query: codegen folds the position (and the file) into
          # the message, and this report keeps them separate — same splitter the
          # rendered error uses, so the two can't drift apart
          e.errors.map do |detail|
            _path, _position, message = GraphWeaver::QueryValidationError.split(detail)
            detail.transform_keys(&:to_s).merge("message" => message)
          end
        end

        # The routing table behind a dump path, when the dump is a composed
        # supergraph: it says who resolves what, so a validation error can name
        # the subgraph whose code to look at. nil for anything else — a plain
        # schema, a url client, a live class are all unaffected.
        def routing_table_for(path)
          path = path.to_path if path.respond_to?(:to_path)
          return unless path&.end_with?(".graphql", ".gql")

          sdl = File.read(path)
          SchemaLoader.routing_table(sdl) if SchemaLoader.federation_sdl?(sdl)
        end

        private

        # Which subgraphs a validation error is about, on a federated schema:
        # "Field 'weight' doesn't exist on type 'Product'" is much less useful
        # than the same line plus "(products)" — whose code to look at, whose
        # team to talk to. graphql-ruby reports the coordinate structurally, so
        # this is a lookup rather than message parsing. Both halves of the
        # coordinate are required: an argument error reports typeName "Field"
        # (the AST node kind, not a type), and looking that up would attribute
        # confidently and wrongly.
        def attribute(table, extensions)
          return [] unless extensions

          type_name, field_name = extensions.values_at("typeName", "fieldName")
          return [] unless type_name && field_name

          table.responsible(type_name, field_name)
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
      SUBSCRIPTION_PATTERN = /^[ \t]*subscription\b/
      private_constant :MUTATION_PATTERN, :SUBSCRIPTION_PATTERN

      REQUEST_MUTEX = Mutex.new
      private_constant :REQUEST_MUTEX

      # keep debug readable: a 100-line introspection query would drown the
      # log — the INFO introspection line already carries the timing
      LOG_QUERY_LIMIT = 600
      private_constant :LOG_QUERY_LIMIT

      class << self
        def operation_name(query) = query[OPERATION_NAME_PATTERN, 1]

        def mutation?(query) = MUTATION_PATTERN.match?(query)

        # What this document runs, for the instrumentation payload — :query
        # for the shorthand `{ ... }` document too, which is what it is.
        # Built on mutation? rather than beside it, so an APM's write-failure
        # rate and the decision not to retry can't come to disagree.
        def kind(query)
          return :mutation if mutation?(query)

          SUBSCRIPTION_PATTERN.match?(query) ? :subscription : :query
        end

        # one error in the shape a GraphQL response carries them
        def graphql_error(message, code)
          { "message" => message, "extensions" => { "code" => code } }
        end

        # "[req 4123-3 FilteredPokemon]" — the pid, this process's own
        # request count, and the operation name when there is one.
        #
        # Both halves, because a Puma cluster forks: the counter is inherited
        # with everything else, so without the reset every worker continues
        # the master's sequence, and without the pid two workers' "[req 3]"
        # are two unrelated requests in one aggregated log.
        def log_tag(operation_name = nil)
          pid = Process.pid
          id = REQUEST_MUTEX.synchronize do
            @request_pid, @request_count = pid, 0 unless @request_pid == pid
            @request_count += 1
          end
          "[req #{pid}-#{id}#{" #{operation_name}" if operation_name}]"
        end

        def truncate_for_log(query)
          return query if query.length <= LOG_QUERY_LIMIT

          "#{query[0, LOG_QUERY_LIMIT]}... (truncated, #{query.bytesize} bytes total)"
        end
      end
    end
  end
end
