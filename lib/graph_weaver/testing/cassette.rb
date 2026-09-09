# typed: true
# frozen_string_literal: true

require "fileutils"
require "graphql"
require "yaml"

module GraphWeaver
  module Testing
    # Raised by Replayer when a request has no recording. The query
    # usually matches and the variables don't, so the variables lead and
    # the recorded ones for the same query come next — the diff you'd
    # otherwise do by eye against the YAML.
    class MissingRecording < GraphWeaver::Error
      # how many recorded variable sets to print before summarizing
      SHOWN = 5

      def initialize(path:, query:, variables:, recorded:, size:)
        super([
          "no recording for this request in #{path}",
          "  variables: #{Cassette.normalize_variables(variables).inspect}",
          "  #{self.class.recorded_summary(recorded, size)}",
          "  query: #{Cassette.summarize(query)}",
          "re-record it (GRAPHWEAVER_RECORD=1 with a client:), or delete the cassette to start over.",
        ].join("\n"))
      end

      def self.recorded_summary(recorded, size)
        return "no entry recorded for this query (#{size} in the cassette)" if recorded.empty?

        more = recorded.size > SHOWN ? " (+#{recorded.size - SHOWN} more)" : ""
        "#{recorded.size} #{(recorded.size == 1) ? "entry" : "entries"} recorded for this query, " \
          "with variables #{recorded.first(SHOWN).map(&:inspect).join(", ")}#{more}"
      end
    end

    class << self
      # The cassette-backed client: replays spec/cassettes/<name>.yml when
      # it exists, records it through client: when it doesn't (VCR's once
      # mode). Record mode (GRAPHWEAVER_RECORD=1 / config.record) always
      # records, so it needs a client: too.
      #
      #      client = GraphWeaver::Testing.cassette("github", client: live)
      #      result = RepoQuery.execute!(client:, owner: "dpep")
      #
      def cassette(name, client: nil)
        file = Cassette.new(name)

        if client && (config.record || !file.exist?)
          Recorder.new(client, file)
        elsif config.record
          # record mode without a client would quietly serve the stale
          # recording — the one thing "re-record everything" didn't ask for
          raise GraphWeaver::Error, "record mode is on but no `client:` was given for #{file.path} " \
            "— pass a live `client:` to re-record it, or turn record mode off " \
            "(GRAPHWEAVER_RECORD / Testing.config.record)."
        elsif file.exist?
          Replayer.new(file)
        else
          # a first run, not a missing recording: there is no request yet
          raise GraphWeaver::Error, "#{file.path} doesn't exist and no `client:` was given to " \
            "record with — pass `client:` on the first run, or commit the cassette."
        end
      end
    end

    # The cassette file itself: a YAML list of {query, variables, response}
    # entries. Testing.cassette wraps one in a record/replay client; this is
    # the file object behind it — and what the anonymize rake task rewrites.
    class Cassette
      # What replaying one cassette through the current generated modules
      # found. `checked` is how many recordings a module claimed: a run that
      # claimed none proved nothing, which is a different answer from "all
      # good" — the same distinction `federation:diff` draws.
      Check = Struct.new(:path, :checked, :skipped, :stale, keyword_init: true) do
        def ok? = stale.empty?

        def report
          counted = ["#{checked} checked"]
          counted << "#{skipped} not sent by any query module" if skipped.positive?

          ["#{path}: #{stale.size} stale (#{counted.join(", ")})"] +
            stale.flat_map do |entry|
              ["  #{entry.module_name} #{entry.variables.inspect}", "    #{entry.message}"]
            end
        end
      end

      # One recording the generated structs can no longer read.
      Stale = Struct.new(:module_name, :variables, :message, keyword_init: true)

      # Shapes that are a credential whatever the field around them is
      # called. Anonymization can't cover everything a cassette holds — the
      # variables ARE the replay key, so they're written verbatim — so the
      # bytes that reach disk get one look before anyone commits them.
      # Deliberately narrow: a false alarm costs a glance, while a password
      # like "hunter2" has no shape at all, so a quiet run is not a clean
      # bill of health.
      CREDENTIAL_SHAPES = {
        "a JWT" => /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\./,
        "an AWS access key" => /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
        "a GitHub token" => /\b(?:gh[opusr]|github_pat)_[A-Za-z0-9_]{20,}/,
        "a Slack token" => /\bxox[baprs]-[A-Za-z0-9-]{10,}/,
        "a Stripe key" => /\bsk_(?:live|test)_[A-Za-z0-9]{10,}/,
        "a private key" => /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
        "an Authorization header" => /\bBearer\s+\S{16,}/,
      }.freeze

      attr_reader :path

      def initialize(path)
        @path = Testing.cassette_path(path)
        @entries = File.exist?(@path) ? YAML.safe_load_file(@path, aliases: true) : []
        @flagged = []
        # record is read-modify-write; two threads recording through one
        # cassette (a parallel spec run) would each save a snapshot missing
        # the other's entry — atomic_write keeps the file whole, not complete
        @lock = Mutex.new
      end

      def exist? = File.exist?(@path)
      def size = @entries.size

      def lookup(query, variables, operation_name = nil)
        wanted = self.class.key(query, variables, operation_name)
        @entries.find { |entry| self.class.entry_key(entry) == wanted }
      end

      # every variables hash recorded for this query — what a miss needs
      # to show, since the variables are what usually differ
      def variants(query, operation_name = nil)
        normalized = self.class.normalize_query(query)
        @entries.select do |entry|
          self.class.normalize_query(entry["query"]) == normalized && entry["operationName"] == operation_name
        end.map { |entry| entry["variables"] || {} }
      end

      def record(query, variables, response, operation_name = nil)
        entry = { "query" => query }
        entry["operationName"] = operation_name if operation_name
        entry["variables"] = self.class.normalize_variables(variables)
        entry["response"] = response

        wanted = self.class.key(query, variables, operation_name)
        @lock.synchronize do
          @entries.reject! { |existing| self.class.entry_key(existing) == wanted }
          @entries << entry
          save
        end
      end

      # Replay every recording through `modules` — the generated query
      # modules — and report the ones that no longer cast.
      #
      # A cassette is the one artifact here recorded from a *foreign* server,
      # and nothing else notices when that server's answers drift out of the
      # shape the structs were generated for: `verify`, `queries:check` and
      # `schema:diff` all ask about the local side. Without this the drift
      # surfaces mid-spec as a `TypeError` naming a struct and a sorbet
      # frame, with nothing pointing at the stale file.
      #
      # Matching is on the query text, which is the module that sent it — a
      # recording no module sends is skipped rather than guessed at.
      def check(modules)
        index = modules.to_h { |mod| [self.class.normalize_query(mod.const_get(:QUERY)), mod] }
        checked = 0
        stale = @entries.filter_map do |entry|
          mod = index[self.class.normalize_query(entry["query"])] or next
          checked += 1

          begin
            mod.from_response(entry["response"])
            nil
          rescue GraphWeaver::Error => e
            Stale.new(module_name: mod.name, variables: entry["variables"] || {}, message: e.message)
          end
        end

        Check.new(path: @path, checked:, skipped: @entries.size - checked, stale:)
      end

      # Replace recorded response values with fakes, preserving structure.
      # Walks each entry's query against the schema (like FakeClient,
      # but transforming what's there instead of generating from scratch).
      def anonymize!(schema:, seed: nil, mode: nil)
        anonymizer = Anonymizer.new(schema:, seed:, mode:)
        @entries.each do |entry|
          entry["response"] = anonymizer.anonymize(entry["query"], entry["response"]) if entry["response"]
        end
        save
        self
      end

      # The request's identity, exactly as the server sees it. operationName
      # is part of that: it picks the operation the document runs, so two
      # requests with identical text but different names are different
      # requests. Derived, never stored — the file holds the request once,
      # so a hand-edited entry can't disagree with what replay matches on.
      def self.key(query, variables, operation_name = nil)
        key = { "query" => normalize_query(query), "variables" => normalize_variables(variables) }
        key["operationName"] = operation_name if operation_name
        key
      end

      def self.entry_key(entry)
        key(entry["query"], entry["variables"], entry["operationName"])
      end

      def self.normalize_query(query) = query.gsub(/\s+/, " ").strip

      # one readable line: an error naming a 60-line query is a wall, not a hint
      def self.summarize(query, limit: 160)
        normalized = normalize_query(query)
        (normalized.length > limit) ? "#{normalized[0, limit]}…" : normalized
      end

      # JSON round-trip so symbol keys become strings — otherwise YAML.dump
      # writes Ruby symbols the safe loader rejects on the next run, and lookup
      # keys stay stable across processes
      def self.normalize_variables(variables)
        JSON.parse(JSON.generate(variables || {}))
      end

      private

      def save
        yaml = YAML.dump(@entries)
        FileUtils.mkdir_p(File.dirname(@path))
        GraphWeaver.atomic_write(@path, yaml)
        flag_credentials(yaml)
      end

      # Once per shape per cassette: a recording run saves after every
      # request, and one line is a warning where forty is noise. On stderr
      # rather than GraphWeaver.logger — the logger is silent by default,
      # and this has to reach whoever is about to commit the file.
      def flag_credentials(yaml)
        found = CREDENTIAL_SHAPES.reject { |name, _| @flagged.include?(name) }
          .select { |_, pattern| pattern.match?(yaml) }.keys
        return if found.empty?

        @flagged.concat(found)
        warn "graph_weaver: #{@path} contains #{found.join(", ")} — a cassette is committed as " \
          "written, so review this one first. Testing.config.anonymize scrubs the response; the " \
          "query and variables are the replay key and are recorded verbatim."
      end
    end

    # Tees requests through a live client and records every response.
    # With Testing.config.anonymize, responses are anonymized as they're
    # recorded — and the anonymized version is what the caller sees too,
    # so assertions written now hold on replay.
    class Recorder
      def initialize(client, cassette)
        @client = client
        @cassette = cassette.is_a?(Cassette) ? cassette : Cassette.new(cassette)

        config = Testing.config
        if config.anonymize
          unless config.schema
            raise ArgumentError, "anonymizing recordings needs GraphWeaver::Testing.config.schema"
          end

          @anonymizer = Anonymizer.new(schema: config.schema, seed: config.seed)
        end
      end

      def execute(query, variables: {}, operation_name: nil)
        response = @client.execute(query, variables:, operation_name:).to_h
        response = @anonymizer.anonymize(query, response) if @anonymizer

        @cassette.record(query, variables, response, operation_name)
        response
      end
    end

    # Serves recorded responses; raises MissingRecording on unknown
    # requests rather than silently faking.
    class Replayer
      def initialize(cassette)
        @cassette = cassette.is_a?(Cassette) ? cassette : Cassette.new(cassette)
      end

      def execute(query, variables: {}, operation_name: nil)
        entry = @cassette.lookup(query, variables, operation_name)
        unless entry
          raise MissingRecording.new(path: @cassette.path, query:, variables:,
            recorded: @cassette.variants(query, operation_name), size: @cassette.size)
        end

        entry["response"]
      end
    end

    # Rewrites a recorded response through the Values engine: same shape,
    # fake values. Enums, booleans, __typename, and null positions are
    # preserved; ids map consistently so relationships survive.
    class Anonymizer
      include GraphWeaver::Selection

      # Keys under `errors`/`extensions` whose value describes the request
      # rather than carrying data: `path` and `locations` point into the
      # document, and `code` is the errors-world enum — call sites branch on
      # it exactly as they branch on an enum in `data`, which is preserved
      # for the same reason.
      VERBATIM_KEYS = %w[path locations code].freeze

      def initialize(schema:, seed: nil, mode: nil)
        @schema = schema
        @values = Values.new(seed:, mode:)
      end

      # The whole response, not just `data`: an error message routinely
      # quotes the input that caused it, and `extensions` is whatever the
      # server felt like attaching. One rule — `data` is walked against the
      # schema, everything else by shape.
      def anonymize(query, response)
        response.to_h do |key, value|
          [key, (key == "data") ? data_value(query, value) : untyped_value(key, value)]
        end
      end

      private

      def data_value(query, data)
        return if data.nil?

        operation = load_operation(query)
        object_value(operation_root_type(operation), operation.selections, data)
      end

      # No schema stands behind errors or extensions, so shape is all there
      # is to preserve: keys, nesting, list lengths, nulls and booleans
      # survive; every string and number is replaced.
      def untyped_value(key, value)
        return value if VERBATIM_KEYS.include?(key)

        case value
        when Hash then value.to_h { |name, nested| [name, untyped_value(name, nested)] }
        when Array then value.map { |element| untyped_value(key, element) }
        when String then @values.scalar("String", key)
        when Integer then @values.scalar("Int", key)
        when Float then @values.scalar("Float", key)
        else value
        end
      end

      # Anonymization walks recorded data, not a live dispatch. When the query
      # narrows an abstract type without selecting __typename (`named { name
      # ... on Pet { species } }`), the recorded data has no type tag, so the
      # strict applies? would drop the `... on Pet` fields. Treat any concrete
      # member condition as applying; object_value's `data.key?(key)` guard
      # discards fields the actual member's response didn't carry.
      def applies?(condition, type)
        return true if super

        member = @schema.get_type(condition)
        !!member && @schema.possible_types(type).include?(member)
      end

      def object_value(type, selections, data)
        return data if data.nil?

        # abstract types anonymize as the member the response says it was
        if (typename = data["__typename"]) && type.graphql_name != typename
          type = @schema.get_type(typename) || type
        end

        result = {}
        # gather (not each_field) so a key selected twice — `a { x } a { y }` —
        # keeps the MERGED shape codegen's struct expects, not last-writer-wins
        gather(type, selections).each do |key, nodes|
          next unless data.key?(key)

          node = nodes.first
          result[key] = if node.name == "__typename"
            data[key]
          else
            field_value(type, node.name, nodes.flat_map(&:selections), data[key])
          end
        end

        result
      end

      def field_value(parent_type, name, selections, value)
        # a field from a `... on Member` fragment lives on the member, not the
        # abstract type we're walking (no __typename to narrow by), so fall back
        # to whichever possible type declares it
        field = @schema.get_field(parent_type.graphql_name, name) ||
          @schema.possible_types(parent_type).filter_map { |t| @schema.get_field(t.graphql_name, name) }.first
        type_value(field.type, name, selections, value, "#{parent_type.graphql_name}.#{name}")
      end

      def type_value(type, name, selections, value, coordinate = nil)
        return if value.nil? # preserve null positions

        case type.kind.name
        when "NON_NULL"
          type_value(type.of_type, name, selections, value, coordinate)
        when "LIST"
          value.map { |element| type_value(type.of_type, name, selections, element, coordinate) }
        when "SCALAR"
          scalar_value(type.graphql_name, name, value, coordinate)
        when "ENUM"
          value # enums aren't PII; preserving them keeps semantics
        when "OBJECT", "UNION", "INTERFACE"
          object_value(type, selections, value)
        else
          value
        end
      end

      def scalar_value(type_name, field_name, value, coordinate = nil)
        case type_name
        when "ID" then @values.mapped_id(value)
        when "Boolean" then value # not PII; preserves branching behavior
        else @values.scalar(type_name, field_name, coordinate)
        end
      end
    end
  end
end
