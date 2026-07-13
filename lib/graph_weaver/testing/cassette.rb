# typed: true
# frozen_string_literal: true

require "fileutils"
require "graphql"
require "yaml"

module GraphWeaver
  module Testing
    # Raised by Replayer when a request has no recording.
    class MissingRecording < GraphWeaver::Error
      def initialize(path:, query:)
        super(<<~MSG.strip)
          no recording for this request in #{path} — re-record it
          (Recorder / Cassette.use with a live client, or delete
          the cassette to start over). Query:
          #{query.strip[0, 200]}
        MSG
      end
    end

    # Capture/replay above the transport (no HTTP interception): a
    # cassette is a YAML file of {query, variables, response} entries,
    # keyed on the normalized query + variables.
    #
    #      # record against a real client, replay when the file exists:
    #      client = GraphWeaver::Testing::Cassette.use("github", client: real)
    #
    # Cassettes hold real responses — anonymize before committing:
    #
    #      Cassette.new("spec/cassettes/github.yml").anonymize!(schema:)
    #
    # keeps every shape (list lengths, null positions, enums, __typename,
    # id relationships via a consistent mapping) while replacing values
    # with fakes, semantically matched where field names allow.
    class Cassette
      attr_reader :path

      def initialize(path)
        @path = Testing.cassette_path(path)
        @entries = File.exist?(@path) ? YAML.safe_load_file(@path, aliases: true) : []
      end

      def exist? = File.exist?(@path)
      def size = @entries.size

      # Replay when recorded, record when not (VCR's once mode).
      # client: is required to record; omit it to replay-or-raise.
      # With Testing.config.record on (or GRAPHWEAVER_RECORD=1), always
      # records — the "just re-record everything" switch.
      def self.use(path, client: nil)
        cassette = new(path)
        if Testing.config.record && client
          Recorder.new(client, cassette)
        elsif cassette.exist?
          Replayer.new(cassette)
        elsif client
          Recorder.new(client, cassette)
        else
          raise MissingRecording.new(path: cassette.path, query: "(no client to record with)")
        end
      end

      def lookup(query, variables)
        wanted = self.class.key(query, variables)
      @entries.find { |entry| entry["key"] == wanted }
      end

      def record(query, variables, response)
        entry = {
          "key" => self.class.key(query, variables),
          "query" => query,
          "variables" => variables,
          "response" => response,
        }
        @entries.reject! { |existing| existing["key"] == entry["key"] }
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

      def self.key(query, variables)
        { "query" => query.gsub(/\s+/, " ").strip, "variables" => variables || {} }
      end

      private

      def save
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, YAML.dump(@entries))
      end
    end

    # Tees requests through a live client and records every response.
    # With Testing.config.anonymize (or anonymize: true), responses are
    # anonymized as they're recorded — and the anonymized version is what
    # the caller sees too, so assertions written now hold on replay.
    class Recorder
      def initialize(client, cassette, anonymize: nil)
        @client = client
        @cassette = cassette.is_a?(Cassette) ? cassette : Cassette.new(cassette)

        config = Testing.config
        if anonymize.nil? ? config.anonymize : anonymize
          unless config.schema
            raise ArgumentError, "anonymizing recordings needs GraphWeaver::Testing.config.schema"
          end

          @anonymizer = Anonymizer.new(schema: config.schema, seed: config.seed)
        end
      end

      def execute(query, variables: {})
        response = @client.execute(query, variables:).to_h
        if @anonymizer && (data = response["data"])
          response = response.merge("data" => @anonymizer.anonymize(query, data))
        end

        @cassette.record(query, variables, response)
        response
      end
    end

    # Serves recorded responses; raises MissingRecording on unknown
    # requests rather than silently faking.
    class Replayer
      def initialize(cassette)
        @cassette = cassette.is_a?(Cassette) ? cassette : Cassette.new(cassette)
      end

      def execute(query, variables: {})
        entry = @cassette.lookup(query, variables)
        raise MissingRecording.new(path: @cassette.path, query:) unless entry

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
        type_value(@schema.get_field(parent_type.graphql_name, node.name).type, node, value)
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
