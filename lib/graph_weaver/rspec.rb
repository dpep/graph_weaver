# typed: true
# frozen_string_literal: true

require_relative "testing"

# RSpec integration — require from your spec helper instead of
# "graph_weaver/testing":
#
#      require "graph_weaver/rspec"
#
# Then say what an example runs against with one tag, on the example or on
# the group it belongs to (rspec metadata inherits, so a whole describe
# block can run against real resolvers):
#
#      it "renders the empty state", graphql: :fake do        … end
#      it "authorizes drafts",       graphql: :in_process do  … end
#      describe "checkout",          graphql: :router do      … end
#
#      :fake        fabricated, schema-correct data; no resolvers run
#      :in_process  your resolvers, one live schema class, in-process
#      :router      your resolvers, across a federated graph
#
# `rspec --tag graphql:router` runs one mode's examples.
#
# **Nothing needs configuring.** Each mode derives what it runs against,
# and refuses — naming what it looked for — rather than guessing:
#
#   - the schema is GraphWeaver::Testing.config.schema if you set one, else
#     the committed dump at GraphWeaver.schema_path, else the schema of
#     GraphWeaver.client.
#   - :in_process finds the live schema *class* — the one the client
#     already runs in-process, else the loaded class defining everything
#     that schema declares (Testing::LiveSchema).
#   - :router plans against the composed supergraph: the dump, when that's
#     what it is, else config.router = { supergraph: … }. Subgraphs are
#     derived from what each loaded schema defines (Testing::Subgraphs).
#
# What it wires up:
#   - seed: defaults to rspec's --seed, so `rspec --seed 1234` reproduces
#     fake data along with test order
#   - a client per example, from the tag (or config.default_mode for an
#     untagged one; nil, the default, leaves GraphWeaver.client alone).
#     The prior client is restored afterwards.
#   - graphql_context — the GraphQL context resolvers see, merged onto
#     config.context and reset between examples.
#
# The router is built once for the suite (parsing a supergraph per example
# would be real time) and installed for each.
#
# note: modules generated with a baked-in client: constant don't consult
# GraphWeaver.client — generate without client: to make them fakeable.
module GraphWeaver
  module Testing
    module RSpecIntegration
      # the one metadata key — namespaced, because an app's own :fake or
      # :router tag must never silently change which client an example runs
      # against
      TAG = :graphql

      def self.install(rspec_config)
        rspec_config.include(Helpers)

        rspec_config.before(:suite) do
          config = GraphWeaver::Testing.config
          config.seed ||= RSpec.configuration.seed
        end

        rspec_config.before(:each) do
          metadata = RSpec.current_example&.metadata || {}
          mode = GraphWeaver::Testing::RSpecIntegration.mode_for(metadata)
          next unless mode

          @__graph_weaver_mode = mode
          @__graph_weaver_prior_client = GraphWeaver.client
          GraphWeaver.client = GraphWeaver::Testing::RSpecIntegration.client_for(mode)
        end

        rspec_config.after(:each) do
          next unless defined?(@__graph_weaver_prior_client)

          GraphWeaver.client = @__graph_weaver_prior_client
          remove_instance_variable(:@__graph_weaver_prior_client)
          remove_instance_variable(:@__graph_weaver_mode)
        end
      end

      # the mode this example's metadata selects, or the configured default
      def self.mode_for(metadata, config = GraphWeaver::Testing.config)
        tagged = metadata[TAG]
        return config.default_mode if tagged.nil?

        mode = tagged.to_s.to_sym
        return mode if CLIENT_MODES.include?(mode)

        raise GraphWeaver::Error, "#{TAG}: #{tagged.inspect} is not a mode — " \
          "#{CLIENT_MODES.map(&:inspect).join(", ")}"
      end

      # the client an example in this mode runs against
      def self.client_for(mode, config = GraphWeaver::Testing.config)
        case mode
        when :fake
          FakeClient.new(schema: config.reference_schema!)
        when :in_process
          GraphWeaver::InProcess.new(config.live_schema, context: config.context)
        when :router
          router = config.built_router
          router.context = config.context
          router
        end
      end

      # graphql_context's target: the client the hook installed, and what
      # setting a context on it means.
      module Helpers
        # The GraphQL context this example's resolvers see — merged onto
        # config.context, and reset before the next example runs:
        #
        #      graphql_context(current_user: alice)
        #      graphql_context(admin: true) { … }   # only inside the block
        #      graphql_context                      # read it back
        def graphql_context(values = nil, &block)
          mode = defined?(@__graph_weaver_mode) ? @__graph_weaver_mode : nil
          baseline = GraphWeaver::Testing::RSpecIntegration.context!(mode)
          return baseline unless values

          merged = baseline.merge(values)
          GraphWeaver::Testing::RSpecIntegration.set_context(mode, merged)
          return merged unless block

          begin
            block.call
          ensure
            GraphWeaver::Testing::RSpecIntegration.set_context(mode, baseline)
          end
        end
      end

      # A fake has no resolvers to hand a context to, so silently ignoring
      # one would leave an example asserting on data nothing scoped.
      def self.context!(mode)
        case mode
        when :in_process, :router then GraphWeaver.client.context
        when :fake
          raise GraphWeaver::Error, "graphql_context needs resolvers to receive it, and a " \
            "#{TAG}: :fake example runs against fabricated data — tag it #{TAG}: :in_process or " \
            "#{TAG}: :router (or pin values with GraphWeaver::Testing.config.overrides)"
        else
          raise GraphWeaver::Error, "graphql_context needs an example running against your " \
            "resolvers — tag it #{TAG}: :in_process or #{TAG}: :router"
        end
      end

      def self.set_context(mode, values)
        client = GraphWeaver.client
        # the router is built once for the suite, so it takes a new context
        # rather than being rebuilt; an InProcess is two ivars, so it isn't
        # worth making mutable for this
        case mode
        when :router then client.context = values
        when :in_process then GraphWeaver.client = GraphWeaver::InProcess.new(client.schema, context: values)
        end
      end
    end
  end
end

RSpec.configure { |config| GraphWeaver::Testing::RSpecIntegration.install(config) } if defined?(RSpec)
