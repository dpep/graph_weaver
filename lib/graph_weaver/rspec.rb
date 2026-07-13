# typed: true
# frozen_string_literal: true

require_relative "testing"

# RSpec integration — require from your spec helper instead of
# "graph_weaver/testing":
#
#      require "graph_weaver/rspec"
#
# That one line is the whole setup in a conventional app: the schema
# auto-locates from the committed dump (GraphWeaver.schema_path) and
# auto_fake defaults on, so every example runs against a schema-correct
# fake. Configure to override:
#
#      GraphWeaver::Testing.configure do |config|
#        config.schema = MySchema     # instead of the located dump
#        config.auto_fake = false     # opt out of per-example fakes
#      end
#
# What it wires up:
#   - seed: defaults to rspec's --seed, so `rspec --seed 1234` reproduces
#     fake data along with test order
#   - auto_fake: when on (and a schema resolves), each example gets a
#     fresh seeded FakeClient installed as GraphWeaver.client —
#     generated modules run in test mode with zero per-test setup. The
#     prior client is restored after each example.
#
# note: modules generated with a baked-in client: constant don't consult
# GraphWeaver.client — generate without client: to make them fakeable.
module GraphWeaver
  module Testing
    module RSpecIntegration
      def self.install(rspec_config)
        rspec_config.before(:suite) do
          config = GraphWeaver::Testing.config
          config.seed ||= RSpec.configuration.seed
        end

        rspec_config.before(:each) do
          config = GraphWeaver::Testing.config
          next unless config.auto_fake && config.schema

          @__graph_weaver_prior_client = GraphWeaver.client
          GraphWeaver.client = FakeClient.new(schema: config.schema)
        end

        rspec_config.after(:each) do
          config = GraphWeaver::Testing.config
          next unless config.auto_fake && config.schema

          GraphWeaver.client = @__graph_weaver_prior_client
        end
      end
    end
  end
end

RSpec.configure { |config| GraphWeaver::Testing::RSpecIntegration.install(config) } if defined?(RSpec)
