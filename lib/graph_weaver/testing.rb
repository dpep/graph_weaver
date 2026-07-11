# typed: true
# frozen_string_literal: true

require_relative "../graph_weaver"

# faker is optional — semantic values (name/email/url...) when present,
# type-based values when not
begin
  require "faker"
rescue LoadError
  # fall back to type-based generation
end

# Opt-in test tooling: require "graph_weaver/testing" from your spec
# helper (never from production code). Configure once, initializer-style:
#
#   GraphWeaver::Testing.configure do |config|
#     config.seed = 42                          # reproducible fakes
#     config.semantics = true                   # faker-backed field matching
#     config.overrides = { "Person.name" => "Daniel" }
#     config.list_size = 2..4
#     config.null_chance = 0.1                  # nullable fields go nil sometimes
#   end
module GraphWeaver
  module Testing
    class Config
      attr_accessor :overrides, :seed, :list_size, :null_chance
      attr_writer :semantics

      def initialize
        @overrides = {}
        @seed = nil
        @list_size = 1..3
        @null_chance = 0.0
        @semantics = nil # auto: on when faker is loaded
      end

      def semantics
        @semantics.nil? ? !defined?(::Faker).nil? : @semantics
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
    end
  end
end

require_relative "testing/fake_executor"
