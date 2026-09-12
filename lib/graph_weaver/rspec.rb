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
#      :wire        your resolvers, served at your client's endpoint so
#                   your real transport runs
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
#     derived from what each loaded schema defines; one nothing here serves
#     is absent, and only a query that reaches its fields is refused.
#   - :wire serves whichever of those two the graph is — the router when
#     there's a composed supergraph, the live schema class otherwise — at
#     the endpoint GraphWeaver.client posts to, and leaves that client in
#     place. It needs webmock (`require "webmock/rspec"`), which hooks
#     Net::HTTP, Faraday and HTTPX.
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
          # :wire is the one mode that does NOT take the client slot — the
          # app's own client staying in it is the whole point, so what the
          # tag builds is served at that client's endpoint instead
          @__graph_weaver_served = nil
          @__graph_weaver_stub = nil
          if @__graph_weaver_mode == :wire
            @__graph_weaver_served = GraphWeaver::Testing::RSpecIntegration.client_for(:wire)
            @__graph_weaver_stub = GraphWeaver::Testing::RSpecIntegration.serve!(@__graph_weaver_served)
          elsif @__graph_weaver_mode
            GraphWeaver.client = GraphWeaver::Testing::RSpecIntegration.client_for(@__graph_weaver_mode)
          end
        end

        rspec_config.after(:each) do
          next unless defined?(@__graph_weaver_prior_client)

          if defined?(@__graph_weaver_stub) && @__graph_weaver_stub
            GraphWeaver::Testing::RSpecIntegration.unserve!(@__graph_weaver_stub)
          end
          remove_instance_variable(:@__graph_weaver_stub) if defined?(@__graph_weaver_stub)
          remove_instance_variable(:@__graph_weaver_served) if defined?(@__graph_weaver_served)
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
        when :wire
          # what sits behind the wire is decided the way the other tags
          # already decide it — the router when there's a composed
          # supergraph, the live schema class otherwise
          client_for(config.supergraph? ? :router : :in_process, config)
        end
      end

      # Serve `client` at the endpoint GraphWeaver.client posts to, so the
      # app's own transport runs against it. Returns the WebMock stub, which
      # {unserve!} removes after the example — nothing else about the
      # suite's WebMock setup is touched.
      def self.serve!(client)
        unless defined?(WebMock)
          raise GraphWeaver::Error, "#{TAG}: :wire serves your resolvers over HTTP, which needs " \
            "webmock — it hooks Net::HTTP, Faraday and HTTPX, so your own transport runs unchanged. " \
            "Add it to the Gemfile (group :test) and `require \"webmock/rspec\"` in your spec helper."
        end

        begin
          require "rack" # WebMock's to_rack builds a Rack env but doesn't depend on rack
        rescue LoadError
          raise GraphWeaver::Error, "#{TAG}: :wire needs rack — webmock's to_rack builds a Rack " \
            "env with it, but doesn't depend on it. Add it to the Gemfile (group :test)."
        end

        stub = WebMock::API.stub_request(:post, endpoint!)
        # to_rack returns the stub's response list, not the stub, so the
        # handle unserve! needs is the one stub_request handed back
        stub.to_rack(GraphWeaver::Testing::Endpoint.new(client))
        stub
      end

      # Take one stub back down. Only ours — a suite's other stubs, and
      # whether it allows net connections, are its own business.
      def self.unserve!(stub) = WebMock::API.remove_request_stub(stub)

      # The endpoint the app's own client posts to: a transport, a Retry
      # around one, or a Client that built one.
      def self.endpoint!(client = GraphWeaver.client)
        target = (client.transport if client.respond_to?(:transport)) || client
        url = target.url if target.respond_to?(:url)
        return url if url

        raise GraphWeaver::Error, "#{TAG}: :wire runs your own transport against your resolvers, " \
          "so it needs the endpoint that transport posts to — and " \
          "#{client ? "GraphWeaver.client is #{client.class}, which posts to none" : "GraphWeaver.client isn't set"}. " \
          "There is nothing to serve. Point the client at a url " \
          "(GraphWeaver.new(\"https://api.example.com/graphql\")), or tag the example " \
          "#{TAG}: :in_process or #{TAG}: :router — they run above the wire."
      end

      # included into every example group, so graphql_context is there
      # whether or not this example took a client from the hook
      module Helpers
        # The fake this example runs against, built here rather than by the
        # tag — which is how it takes pins and options. `graphql: :fake` is
        # exactly this call with none:
        #
        #      it "shows the two paid orders" do
        #        graphql_fake("Reader.name" => "Ada",
        #                     "Reader.orders" => [{ "status" => "PAID" }, {}])
        #        expect(DashboardQuery.execute!.reader.orders.size).to eq 2
        #      end
        #
        # Pins lead, options follow: `graphql_fake("Money" => "12.00",
        # values: :literal)`. Options are lowercase words, so a key with a
        # dot or a leading capital is a pin wherever it is written.
        #
        # Returns the client, for the assertions that are about the request:
        #
        #      fake = graphql_fake
        #      2.times { Dashboard.load }
        #      expect(fake.requests.size).to eq 1
        #
        # Installed as GraphWeaver.client and restored after the example,
        # like a tagged one — so the tag is optional here, not required.
        def graphql_fake(pins = {}, **options)
          claim_mode!(:fake)
          refuse_seed!(options)
          options[:schema] ||= GraphWeaver::Testing.config.reference_schema!
          GraphWeaver.client = GraphWeaver::Testing::FakeClient.new(pins, **options)
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
        # subgraphs it fakes fabricate — the pins and options graphql_fake
        # takes, in one hash:
        #
        #      it "shows the carrier" do
        #        graphql_router(fake: { "Shipment.carrier" => "UPS" })
        #        …
        #      end
        #
        # The router itself is built once for the suite — parsing a
        # supergraph per example is real time — so this installs that one and
        # tells it where this example starts.
        def graphql_router(fake: nil)
          claim_mode!(:router)
          refuse_seed!(fake) if fake
          router = GraphWeaver::Testing::RSpecIntegration.client_for(:router)
          router.fake = fake if fake
          GraphWeaver.client = router
        end

        # Run this example against your own transport: the resolvers
        # `graphql: :router` or `graphql: :in_process` would run — whichever
        # this graph is — served at the endpoint GraphWeaver.client posts
        # to, with that client left exactly where it is. So the request is
        # serialized, posted through your middleware, and deserialized by
        # `from_h` over the server's own bytes.
        #
        #      it "sends the caller tag", graphql: :wire do
        #        DashboardQuery.execute!
        #        expect(WebMock).to have_requested(:post, endpoint)
        #          .with(headers: { "X-Caller" => "web" })
        #      end
        #
        # `graphql: :wire` is exactly this call with no argument; `fake:` is
        # graphql_router's, for the subgraphs the router fakes. Returns what
        # sits behind the wire, and the stub is removed after the example.
        def graphql_wire(fake: nil)
          claim_mode!(:wire)
          refuse_seed!(fake) if fake
          served = (@__graph_weaver_served ||= GraphWeaver::Testing::RSpecIntegration.client_for(:wire))
          if fake
            unless served.respond_to?(:fake=)
              Kernel.raise GraphWeaver::Error, "fake: says how the router's faked subgraphs " \
                "fabricate, and #{TAG}: :wire is serving #{served.schema} in process — it has no " \
                "subgraphs. Pin the data in the resolvers, or fake the whole response with " \
                "#{TAG}: :fake."
            end

            served.fake = fake
          end
          # the tag already stubbed this example's endpoint with the same
          # client, so there is at most one stub either way
          @__graph_weaver_stub ||= GraphWeaver::Testing::RSpecIntegration.serve!(served)
          served
        end

        # A tag and a helper are two spellings of one choice, so they can
        # agree (`graphql: :fake` plus `graphql_fake(overrides:)` is the
        # documented way to pass options) but must not contradict: one of the
        # two is then a mistake, and silently letting the later one win hides
        # which.
        private def claim_mode!(mode)
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

        # rspec's own --seed already drives the fake (config.seed takes it
        # at suite start), so a per-example seed: is a second answer to one
        # question — and the one that stops `rspec --seed` reproducing the run.
        private def refuse_seed!(options)
          return unless options.to_h.key?(:seed) || options.to_h.key?("seed")

          Kernel.raise GraphWeaver::Error, "seed: isn't a per-example option — `rspec --seed 1234` " \
            "reproduces the fabricated data along with the test order. For a suite that isn't " \
            "rspec, set GraphWeaver::Testing.config.seed."
        end

        # The GraphQL context this example's resolvers see — merged onto
        # config.context, and reset before the next example runs:
        #
        #      graphql_context(current_user: alice)
        #      graphql_context(admin: true) { … }   # only inside the block
        #      graphql_context                      # read it back
        def graphql_context(values = nil, &block)
          mode = defined?(@__graph_weaver_mode) ? @__graph_weaver_mode : nil
          # under :wire the resolvers run behind the endpoint, so the context
          # is on what's served there rather than on GraphWeaver.client
          client = (@__graph_weaver_served if defined?(@__graph_weaver_served)) || GraphWeaver.client
          baseline = GraphWeaver::Testing::RSpecIntegration.context!(mode, client)
          return baseline unless values

          merged = baseline.merge(values)
          GraphWeaver::Testing::RSpecIntegration.set_context(mode, merged, client)
          return merged unless block

          begin
            block.call
          ensure
            GraphWeaver::Testing::RSpecIntegration.set_context(mode, baseline, client)
          end
        end
      end

      # A fake has no resolvers to hand a context to, so silently ignoring
      # one would leave an example asserting on data nothing scoped.
      def self.context!(mode, client = GraphWeaver.client)
        case mode
        when :in_process, :router, :wire
          # a context: proc is answered from the request's headers, so
          # there is no baseline here to merge onto
          Internal::Util.context!(client.context)
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

      # The router is built once for the suite and an in-process client is
      # rebuilt every example, so neither is replaced here — both take the
      # new context in place.
      def self.set_context(mode, values, client = GraphWeaver.client)
        client.context = values if %i[in_process router wire].include?(mode)
      end
    end
  end
end

RSpec.configure { |config| GraphWeaver::Testing::RSpecIntegration.install(config) } if defined?(RSpec)
