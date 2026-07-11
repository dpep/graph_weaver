# typed: true
# frozen_string_literal: true

require "fileutils"
require "graphql"
require "yaml"

module GraphWeaver
  module Testing
    # Raised by ReplayExecutor when a request has no recording.
    class MissingRecording < GraphWeaver::Error
      def initialize(path:, query:)
        super(<<~MSG.strip)
          no recording for this request in #{path} — re-record it
          (RecordingExecutor / Cassette.use with a live executor, or delete
          the cassette to start over). Query:
          #{query.strip[0, 200]}
        MSG
      end
    end

    # Capture/replay above the transport (no HTTP interception): a
    # cassette is a YAML file of {query, variables, response} entries,
    # keyed on the normalized query + variables.
    #
    #   # record against a real executor, replay when the file exists:
    #   executor = GraphWeaver::Testing::Cassette.use("github", executor: real)
    #
    # Cassettes hold real responses — anonymize before committing:
    #
    #   Cassette.new("spec/cassettes/github.yml").anonymize!(schema:)
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

      # replay when recorded, record when not (VCR's once mode).
      # executor: is required to record; omit it to replay-or-raise.
      def self.use(path, executor: nil)
        cassette = new(path)
        if cassette.exist?
          ReplayExecutor.new(cassette)
        elsif executor
          RecordingExecutor.new(executor, cassette)
        else
          raise MissingRecording.new(path: cassette.path, query: "(no executor to record with)")
        end
      end

      def lookup(query, variables)
        @entries.find { |entry| entry["key"] == self.class.key(query, variables) }
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
      # Walks each entry's query against the schema (like FakeExecutor,
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

    # Tees requests through a live executor and records every response.
    class RecordingExecutor
      def initialize(executor, cassette)
        @executor = executor
        @cassette = cassette.is_a?(Cassette) ? cassette : Cassette.new(cassette)
      end

      def execute(query, variables: {})
        response = @executor.execute(query, variables:).to_h
        @cassette.record(query, variables, response)
        response
      end
    end

    # Serves recorded responses; raises MissingRecording on unknown
    # requests rather than silently faking.
    class ReplayExecutor
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
      def initialize(schema:, seed: nil, mode: nil)
        @schema = schema
        @values = Values.new(seed:, mode:)
      end

      def anonymize(query, data)
        doc = GraphQL.parse(query)
        @fragments = doc.definitions
          .grep(GraphQL::Language::Nodes::FragmentDefinition)
          .to_h { |fragment| [fragment.name, fragment] }

        operation = doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).first
        root_type = operation&.operation_type == "mutation" ? @schema.mutation : @schema.query

        object_value(root_type, operation.selections, data)
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

      def each_field(type, selections, &block)
        selections.each do |selection|
          case selection
          when GraphQL::Language::Nodes::Field
            yield(selection.alias || selection.name, selection)
          when GraphQL::Language::Nodes::InlineFragment
            each_field(type, selection.selections, &block) if applies?(selection.type&.name, type)
          when GraphQL::Language::Nodes::FragmentSpread
            fragment = @fragments.fetch(selection.name)
            each_field(type, fragment.selections, &block) if applies?(fragment.type.name, type)
          end
        end
      end

      def applies?(condition, type)
        return true if condition.nil? || condition == type.graphql_name

        condition_type = @schema.get_type(condition)
        return false unless condition_type

        kind = condition_type.kind.name
        (kind == "INTERFACE" || kind == "UNION") &&
          @schema.possible_types(condition_type).include?(type)
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
