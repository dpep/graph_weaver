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
#   GraphWeaver::Testing.configure do |config|
#     config.schema = MySchema                  # for auto_fake / cassettes
#     config.seed = 42                          # reproducible fakes
#     config.mode = :faker                      # or :literal; nil = auto
#     config.overrides = { "Person.name" => "Daniel" }
#     config.list_size = 2..4
#     config.null_chance = 0.1                  # nullable fields go nil sometimes
#     config.cassette_dir = "spec/cassettes"
#   end
#
# mode picks how values are fabricated:
#   :faker   — semantic, field-name matched (requires the faker gem)
#   :literal — plain type-derived values ("name-1", seeded numbers)
#   nil      — auto: :faker when the gem is loaded, else :literal
#
# rspec users: require "graph_weaver/rspec" instead — it hooks the suite
# (seed from rspec, optional auto-faked executor per example).
module GraphWeaver
  module Testing
    MODES = [:faker, :literal].freeze

    class Config
      attr_accessor :overrides, :seed, :list_size, :null_chance, :schema, :cassette_dir, :auto_fake
      attr_reader :mode

      def initialize
        @overrides = {}
        @seed = nil
        @list_size = 1..3
        @null_chance = 0.0
        @mode = nil # auto
        @schema = nil
        @cassette_dir = "spec/cassettes"
        @auto_fake = false
      end

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
    end
  end
end

require_relative "testing/values"
require_relative "testing/fake_executor"
require_relative "testing/cassette"
