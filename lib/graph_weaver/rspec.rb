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
#      false        opt out — GraphWeaver.client is left exactly as it is,
#                   even under config.default_mode
#
# `rspec --tag graphql:router` runs one mode's examples.
#
# `GraphWeaver.client` is snapshotted before every example and restored
# after — tagged, untagged, opted out, whatever the example did to it. So
# an example (or a `before` block, or a shared context) is free to build
# the client it wants:
#
#      before { GraphWeaver.client = GraphWeaver::Testing::Failure.throttled }
#      it "pins the name" { graphql_fake(overrides: { "Person.name" => "Ada" }) }
#
# **Nothing needs configuring.** Each mode derives what it runs against,
# and refuses — naming what it looked for — rather than guessing:
#
#   - the schema is GraphWeaver::Testing.config.schema if you set one, else
#     the committed dump at GraphWeaver.schema_path, else the schema of
#     GraphWeaver.client.
#   - :in_process runs against config.schema, or the schema class your
#     client already uses. Only a live class has resolvers, so when
#     neither is there it says so rather than hunting for one.
#   - :router plans against the composed supergraph: the dump, when that's
#     what it is, else config.router = { supergraph: … }. Subgraphs are
#     derived from what each loaded schema defines (Testing::Subgraphs);
#     one nothing here serves is absent, and only a query that reaches its
#     fields is refused.
#
# What it wires up:
#   - seed: defaults to rspec's --seed, so `rspec --seed 1234` reproduces
#     fake data along with test order
#   - a client per example, from the tag (or config.default_mode for an
#     untagged one; nil, the default, leaves GraphWeaver.client alone),
#     and GraphWeaver.client restored afterwards either way — so a client
#     an example builds for itself is cleaned up like a tagged one.
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

        # snapshot unconditionally: what the example does to GraphWeaver.client
        # is undone whether the tag installed one or the example built its own,
        # so there is no idiom to discover and no way to leak a client forward
        rspec_config.before(:each) do
          @__graph_weaver_prior_client = GraphWeaver.client
          metadata = RSpec.current_example&.metadata || {}
          # what this example said, apart from what config.default_mode says
          # for the ones that said nothing — a helper may only contradict the
          # former
          @__graph_weaver_tag = metadata[TAG] if metadata.key?(TAG)
          @__graph_weaver_mode = GraphWeaver::Testing::RSpecIntegration.mode_for(metadata)
          if @__graph_weaver_mode
            GraphWeaver.client = GraphWeaver::Testing::RSpecIntegration.client_for(@__graph_weaver_mode)
          end
        end

        rspec_config.after(:each) do
          next unless defined?(@__graph_weaver_prior_client)

          GraphWeaver.client = @__graph_weaver_prior_client
          remove_instance_variable(:@__graph_weaver_prior_client)
          # a refused tag raises before the mode is ever set, and its message
          # is the one thing that says what to fix — a NameError out of the
          # cleanup would report a second failure on top of it
          remove_instance_variable(:@__graph_weaver_mode) if defined?(@__graph_weaver_mode)
        end
      end

      # the mode this example's metadata selects, or the configured default
      def self.mode_for(metadata, config = GraphWeaver::Testing.config)
        tagged = metadata[TAG]
        return config.default_mode if tagged.nil?
        # opt out: no client is installed, and a configured default_mode
        # doesn't sweep this example up
        return if tagged == false

        mode = tagged.to_s.to_sym
        return mode if CLIENT_MODES.include?(mode)

        raise GraphWeaver::Error, "#{TAG}: #{tagged.inspect} is not a mode — " \
          "#{CLIENT_MODES.map(&:inspect).join(", ")} (or false to opt out)"
      end

      # the client an example in this mode runs against
      def self.client_for(mode, config = GraphWeaver::Testing.config)
        case mode
        when :fake
          FakeClient.new(schema: config.reference_schema!)
        when :in_process
          GraphWeaver::InProcess.new(config.schema_class!, context: config.context)
        when :router
          router = config.built_router
          router.context = config.context
          # built once for the suite, so it has to be told where this example
          # starts — the trace, and any faked subgraph's fabricated data
          router.reset!
        end
      end

      # included into every example group, so graphql_context is there
      # whether or not this example took a client from the hook
      module Helpers
        # The fake this example runs against, built here rather than by the
        # tag — which is how it takes options. `graphql: :fake` is exactly
        # this call with none:
        #
        #      it "shows the two paid orders" do
        #        graphql_fake(overrides: { "Reader.name" => "Ada",
        #                                  "Reader.orders" => [{ "status" => "PAID" }, {}] })
        #        expect(DashboardQuery.execute!.reader.orders.size).to eq 2
        #      end
        #
        # Returns the client, for the assertions that are about the request:
        #
        #      fake = graphql_fake
        #      2.times { Dashboard.load }
        #      expect(fake.requests.size).to eq 1
        #
        # Installed as GraphWeaver.client and restored after the example,
        # like a tagged one — so the tag is optional here, not required.
        def graphql_fake(**options)
          claim_mode!(:fake)
          options[:schema] ||= GraphWeaver::Testing.config.reference_schema!
          GraphWeaver.client = GraphWeaver::Testing::FakeClient.new(**options)
        end

        # Run this example against one schema class's real resolvers.
        # `graphql: :in_process` is exactly this call with no argument, which
        # runs config.schema when that is a live class.
        #
        # Naming one is how a federated app tests a single subgraph directly,
        # which is a different question from `graphql: :router` — that plans
        # across the whole graph and stitches. Both are worth asking, and a
        # suite testing several subgraphs needs to say which per example:
        #
        #      it "hides a draft review", graphql: :in_process do
        #        graphql_in_process(Reviews::Schema)
        #        …
        #      end
        #
        # Returns the client, and is restored after the example like a tagged
        # one — so the tag is optional here.
        def graphql_in_process(schema = nil, **options)
          claim_mode!(:in_process)
          schema ||= GraphWeaver::Testing.config.schema_class!
          options[:context] ||= GraphWeaver::Testing.config.context
          GraphWeaver.client = GraphWeaver::InProcess.new(schema, **options)
        end

        # Run this example against the whole federated graph. `graphql:
        # :router` is exactly this call with no argument; `fake:` is how the
        # subgraphs it fakes fabricate, in the options graphql_fake takes:
        #
        #      it "shows the carrier" do
        #        graphql_router(fake: { overrides: { "Shipment.carrier" => "UPS" } })
        #        …
        #      end
        #
        # The router itself is built once for the suite — parsing a
        # supergraph per example is real time — so this installs that one and
        # tells it where this example starts.
        def graphql_router(fake: nil)
          claim_mode!(:router)
          router = GraphWeaver::Testing::RSpecIntegration.client_for(:router)
          router.fake = fake if fake
          GraphWeaver.client = router
        end

        # A tag and a helper are two spellings of one choice, so they can
        # agree (`graphql: :fake` plus `graphql_fake(overrides:)` is the
        # documented way to pass options) but must not contradict: one of the
        # two is then a mistake, and silently letting the later one win hides
        # which.
        def claim_mode!(mode)
          # only an explicit tag can contradict a helper. config.default_mode
          # is a fallback for examples that said nothing, so a helper is the
          # example finally saying something — not a disagreement.
          tagged = defined?(@__graph_weaver_tag) ? @__graph_weaver_tag : nil
          if tagged && tagged != mode
            # Kernel.raise: this module is mixed into every example group, so
            # it doesn't include Kernel for sorbet to find
            Kernel.raise GraphWeaver::Error, "this example is tagged #{TAG}: #{tagged.inspect} but calls " \
              "graphql_#{mode} — drop one. The tag is the helper with no arguments, so keep the " \
              "helper when you need to pass it something."
          end

          @__graph_weaver_mode = mode
        end

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
            "#{TAG}: :router (or pin the data itself: " \
            "graphql_fake(overrides: { \"Person.name\" => \"Ada\" }))"
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
