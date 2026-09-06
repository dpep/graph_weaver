# typed: true
# frozen_string_literal: true

require_relative "../graph_weaver"

# faker is optional — semantic values (name/email/age/price/...) when
# present, type-based values when not
begin
  require "faker"
rescue LoadError
  # fall back to type-based generation
end

# Opt-in test tooling: require "graph_weaver/testing" from your spec
# helper (never from production code). Configure once, initializer-style:
#
#      GraphWeaver::Testing.configure do |config|
#        config.schema = MySchema                  # for auto_fake / cassettes
#        config.seed = 42                          # reproducible fakes
#        config.mode = :faker                      # or :literal; nil = auto
#        config.overrides = { "Person.name" => "Daniel" }
#        config.list_size = 2..4
#        config.null_chance = 0.1                  # nullable fields go nil sometimes
#        config.cassette_dir = "spec/cassettes"
#      end
#
# mode picks how values are fabricated:
#      :faker   — semantic, field-name matched (requires the faker gem)
#      :literal — plain type-derived values ("name-1", seeded numbers)
#      nil      — auto: :faker when the gem is loaded, else :literal
#
# rspec users: require "graph_weaver/rspec" instead — it hooks the suite
# (seed from rspec, optional auto-faked client per example).
module GraphWeaver
  module Testing
    MODES = [:faker, :literal].freeze

    class Config
      attr_accessor :overrides, :seed, :list_size, :null_chance, :cassette_dir, :auto_fake,
        :record, :anonymize
      attr_writer :schema
      attr_reader :mode

      def initialize
        @overrides = {}
        @seed = nil
        @list_size = 1..3
        @null_chance = 0.0
        @mode = nil # auto
        @schema = nil
        @cassette_dir = "spec/cassettes"
        # explicit opt-in: swapping every example onto a fake is too
        # surprising to be a default — a little friction beats unexpected
        # behavior (the schema still auto-locates once you opt in)
        @auto_fake = false
        # GRAPHWEAVER_RECORD=1 rspec ...  -> Testing.cassette re-records
        @record = !ENV["GRAPHWEAVER_RECORD"].to_s.empty?
        # anonymize responses as they're recorded (needs config.schema)
        @anonymize = false
      end

      # the explicitly configured schema, else the conventional dump
      # (SchemaLoader.locate at GraphWeaver.schema_path) — nil when
      # neither exists, which quietly disables auto_fake
      def schema
        @schema ||= GraphWeaver::SchemaLoader.locate
      end

      # What's been set, without falling back to the dump — so validating
      # overrides at configure time doesn't force a schema load on a suite
      # that never asks for one.
      def explicit_schema = @schema

      def mode=(mode)
        unless mode.nil? || MODES.include?(mode)
          raise ArgumentError, "mode: must be one of #{MODES.inspect} (or nil for auto), got #{mode.inspect}"
        end

        @mode = mode
      end
    end

    class << self
      def config
        @config ||= Config.new
      end

      def configure
        yield config
        # a typo'd override key pins nothing and the test still passes, so
        # catch it here — while the block that set it is still on the stack
        validate_overrides!(config.explicit_schema, config.overrides) if config.explicit_schema
        config
      end

      # Override keys name schema coordinates: "Type.field", or a bare field
      # name matching that field on any type. Anything else is a typo that
      # would silently fabricate random data instead of pinning a value.
      def validate_overrides!(schema, overrides)
        overrides.each_key { |key| validate_override_key!(schema, key.to_s) }
      end

      # back to defaults — between tests, or to undo an experiment
      def reset!
        @config = nil
      end

      # resolve a cassette name ("github") against cassette_dir; paths
      # with separators or extensions pass through
      def cassette_path(name)
        return name if name.include?("/") || name.end_with?(".yml", ".yaml")

        File.join(config.cassette_dir, "#{name}.yml")
      end

      private

      def validate_override_key!(schema, key)
        type_name, field_name = key.split(".", 2)
        # introspection fields (__typename) are real but absent from #fields
        return if (field_name || type_name).start_with?("__")

        if field_name.nil?
          known = field_names(schema)
          return if known.include?(type_name)

          bad_override!(key, "matches no field in this schema", known, type_name)
        end

        type = schema.get_type(type_name)
        unless type.respond_to?(:fields)
          bad_override!(key, "names no object type in this schema", schema.types.keys, type_name)
        end
        return if type.fields.key?(field_name)

        bad_override!(key, "is not a field of #{type_name}", type.fields.keys, field_name)
      end

      def bad_override!(key, problem, dictionary, term)
        suggestion = GraphWeaver.did_you_mean(dictionary, term)
        hint = suggestion ? " — did you mean '#{suggestion}'?" : ""
        raise GraphWeaver::Error, "override key #{key.inspect} #{problem}#{hint}"
      end

      # Every output field name in the schema — walked only when a bare key
      # asks for it.
      def field_names(schema)
        schema.types.each_value.flat_map { |type| type.respond_to?(:fields) ? type.fields.keys : [] }.uniq
      end
    end
  end
end

require_relative "testing/values"
require_relative "testing/fake_client"
require_relative "testing/failure"
require_relative "testing/cassette"
require_relative "testing/router"
require_relative "testing/coverage"
