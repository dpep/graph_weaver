# typed: true
# frozen_string_literal: true

require_relative "testing"

# RSpec integration — require from your spec helper instead of
# "graph_weaver/testing":
#
#      require "graph_weaver/rspec"
#
# Then opt in to a per-example client (explicit on purpose — silently
# swapping every example onto something else is too surprising to be a
# default). Either fabricate data from the schema:
#
#      GraphWeaver::Testing.configure do |config|
#        config.auto_fake = true      # every example runs against a fake
#        # config.schema = MySchema   # optional: the committed dump auto-locates
#      end
#
# …or, if your app is a client of a **federated** graph, run every example
# against your real subgraph resolvers:
#
#      GraphWeaver::Testing.configure do |config|
#        config.router = { supergraph: Rails.root.join("supergraph.graphql") }
#        # subgraphs: is optional — derived from what each loaded schema defines
#      end
#
# What it wires up:
#   - seed: defaults to rspec's --seed, so `rspec --seed 1234` reproduces
#     fake data along with test order
#   - auto_fake: when on (and a schema resolves), each example gets a
#     fresh seeded FakeClient installed as GraphWeaver.client —
#     generated modules run in test mode with zero per-test setup.
#   - router: the Router is built once for the suite (parsing a supergraph
#     per example would be real time) and installed for each. Its #context
#     is reset from the configured one each time, so an example that runs as
#     a different user — `GraphWeaver.client.context = { current_user: user }`
#     — doesn't leak into the next.
#
# Either way the prior client is restored after each example, and the two
# are mutually exclusive (configure refuses both).
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
          client = GraphWeaver::Testing::RSpecIntegration.client_for(GraphWeaver::Testing.config)
          next unless client

          @__graph_weaver_prior_client = GraphWeaver.client
          GraphWeaver.client = client
        end

        rspec_config.after(:each) do
          next unless defined?(@__graph_weaver_prior_client)

          GraphWeaver.client = @__graph_weaver_prior_client
          remove_instance_variable(:@__graph_weaver_prior_client)
        end
      end

      # the client this example runs against, or nil to leave it alone
      def self.client_for(config)
        if config.router
          router = config.built_router
          router.context = config.router[:context] || {}
          router
        elsif config.auto_fake && config.schema
          FakeClient.new
        end
      end
    end
  end
end

RSpec.configure { |config| GraphWeaver::Testing::RSpecIntegration.install(config) } if defined?(RSpec)
