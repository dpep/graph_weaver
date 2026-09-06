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
      #      result = RepoQuery.execute!(client, owner: "dpep")
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
      attr_reader :path

      def initialize(path)
        @path = Testing.cassette_path(path)
        @entries = File.exist?(@path) ? YAML.safe_load_file(@path, aliases: true) : []
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
        @entries.reject! { |existing| self.class.entry_key(existing) == wanted }
        @entries << entry
        save
      end

      # Replace recorded response values with fakes, preserving structure.
      # Walks each entry's query against the schema (like FakeClient,
      # but transforming what's there instead of generating from scratch).
      def anonymize!(schema:, seed: nil, mode: nil)
        anonymizer = Anonymizer.new(schema:, seed:, mode:)
        @entries.each do |entry|
          data = entry.dig("response", "data")
          entry["response"]["data"] = anonymizer.anonymize(entry["query"], data) if data
        end
        save
        self
      end

      # The request's identity, exactly as the server sees it. operationName
      # is part of that: it picks the operation the document runs, so two
      # requests with identical text but different names are different
      # requests. Omitted when anonymous, so those keys stay as they were.
      # Derived, never stored: the file holds the request once, so a
      # hand-edited entry can't disagree with what replay matches on.
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
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, YAML.dump(@entries))
      end
    end

    # Tees requests through a live client and records every response.
    # With Testing.config.anonymize, responses are anonymized as they're
    # recorded — and the anonymized version is what the caller sees too,
    # so assertions written now hold on replay.
    class Recorder
      def initialize(client, cassette)
        # the recorder speaks the transport contract (execute(q, variables:)),
        # not Client#execute(q, **variables) — unwrap like every other call site
        @client = GraphWeaver.resolve_transport(client)
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
        if @anonymizer && (data = response["data"])
          response = response.merge("data" => @anonymizer.anonymize(query, data))
        end

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

      def initialize(schema:, seed: nil, mode: nil)
        @schema = schema
        @values = Values.new(seed:, mode:)
      end

      def anonymize(query, data)
        operation = load_operation(query)

        object_value(operation_root_type(operation), operation.selections, data)
      end

      private

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
        each_field(type, selections) do |key, node|
          next unless data.key?(key)

          result[key] = if node.name == "__typename"
            data[key]
          else
            field_value(type, node, data[key])
          end
        end

        result
      end

      def field_value(parent_type, node, value)
        # a field from a `... on Member` fragment lives on the member, not the
        # abstract type we're walking (no __typename to narrow by), so fall back
        # to whichever possible type declares it
        field = @schema.get_field(parent_type.graphql_name, node.name) ||
          @schema.possible_types(parent_type).filter_map { |t| @schema.get_field(t.graphql_name, node.name) }.first
        type_value(field.type, node, value)
      end

      def type_value(type, node, value)
        return if value.nil? # preserve null positions

        case type.kind.name
        when "NON_NULL"
          type_value(type.of_type, node, value)
        when "LIST"
          value.map { |element| type_value(type.of_type, node, element) }
        when "SCALAR"
          scalar_value(type.graphql_name, node.name, value)
        when "ENUM"
          value # enums aren't PII; preserving them keeps semantics
        when "OBJECT", "UNION", "INTERFACE"
          object_value(type, node.selections, value)
        else
          value
        end
      end

      def scalar_value(type_name, field_name, value)
        case type_name
        when "ID" then @values.mapped_id(value)
        when "Boolean" then value # not PII; preserves branching behavior
        else @values.scalar(type_name, field_name)
        end
      end
    end
  end
end
