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
#      :live        your app's own client, exactly as it is — the default,
#                   and how one example steps back out of a suite-wide
#                   config.default_mode
#      :fake        fabricated, schema-correct data; no resolvers run
#      :in_process  your resolvers, one live schema class, in-process
#      :router      your resolvers, across a federated graph
#      :wire        your resolvers, served at your client's endpoint, so
#                   the transport you ship runs
#
# `rspec --tag graphql:router` runs one mode's examples.
#
# `GraphWeaver.client` is snapshotted before every example and restored
# after — whatever its mode, and whatever the example did to it. So
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
#   - :router plans against the composed supergraph: config.router =
#     { supergraph: … }, else the schema a declared graph names when that's
#     what it is, else the dump when that's what it is. Subgraphs are
#     derived from what each loaded schema defines; one nothing here serves
#     is absent, and only a query that reaches its fields is refused.
#   - :wire serves whichever of those two a graph is — the router when
#     there's a composed supergraph, the live schema class otherwise — at
#     the endpoint that graph's own client posts to, one per declared graph
#     plus GraphWeaver.client's, leaving every client in place so the real
#     transport runs. Needs webmock (`require "webmock/rspec"`), which hooks
#     Net::HTTP, Faraday and HTTPX.
#
# What it wires up:
#   - seed: defaults to rspec's --seed, so `rspec --seed 1234` reproduces
#     fake data along with test order
#   - a client per example, from the tag (or config.default_mode for an
#     untagged one; :live, the default, leaves GraphWeaver.client alone),
#     and GraphWeaver.client restored afterwards either way — so a client
#     an example builds for itself is cleaned up like a tagged one.
#   - graphql_context — the GraphQL context resolvers see, merged onto
#     config.context and reset between examples.
#
# The router is built once for the suite (parsing a supergraph per example
# would be real time) and installed for each.
#
# A module generated with a baked-in client: is covered too — the mode
# stands in for that constant (Internal::TestClients).
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
          # :wire is the one mode that does NOT take the client slot — every
          # client staying where it is is the whole point, so what the tag
          # builds is served at each of their endpoints instead
          @__graph_weaver_served = nil
          @__graph_weaver_stubs = nil
          if @__graph_weaver_mode == :wire
            @__graph_weaver_stubs = GraphWeaver::Testing::RSpecIntegration.serve!
            @__graph_weaver_served = @__graph_weaver_stubs.map(&:last)
          elsif (client = GraphWeaver::Internal::TestClients.app_client(@__graph_weaver_mode))
            # :live builds none — the app's own client is what it runs
            # against — and neither does an app whose several graphs each
            # answer for themselves
            GraphWeaver.client = client
          end
          GraphWeaver::Internal::TestClients.install(@__graph_weaver_mode)
        end

        rspec_config.after(:each) do
          # first, so a refused tag still tears the mode down
          GraphWeaver::Internal::TestClients.reset!
          next unless defined?(@__graph_weaver_prior_client)

          if defined?(@__graph_weaver_stubs) && @__graph_weaver_stubs
            @__graph_weaver_stubs.each do |stub, _client|
              GraphWeaver::Testing::RSpecIntegration.unserve!(stub)
            end
          end
          remove_instance_variable(:@__graph_weaver_stubs) if defined?(@__graph_weaver_stubs)
          remove_instance_variable(:@__graph_weaver_served) if defined?(@__graph_weaver_served)
          GraphWeaver.client = @__graph_weaver_prior_client
          remove_instance_variable(:@__graph_weaver_prior_client)
          # a refused tag raises before the mode is ever set, and its message
          # is the one thing that says what to fix — a NameError out of the
          # cleanup would report a second failure on top of it
          remove_instance_variable(:@__graph_weaver_mode) if defined?(@__graph_weaver_mode)
        end
      end

      # the mode this example's metadata selects, or the configured default.
      # Every example has exactly one — an untagged one's is config.default_mode,
      # which is :live unless the suite set another.
      def self.mode_for(metadata, config = GraphWeaver::Testing.config)
        tagged = metadata[TAG]
        return config.default_mode if tagged.nil?

        mode = tagged.to_s.to_sym
        return mode if CLIENT_MODES.include?(mode)

        raise GraphWeaver::Error, "#{TAG}: #{tagged.inspect} is not a mode — " \
          "#{CLIENT_MODES.map(&:inspect).join(", ")}. :live leaves GraphWeaver.client exactly " \
          "as it is, which is how one example steps back out of config.default_mode."
      end

      # Serve each graph's resolvers at the endpoint its own client posts to,
      # so every module an example can reach crosses a real wire — not just
      # the ones posting to GraphWeaver.client. Returns [stub, client] pairs;
      # {unserve!} takes a stub back down after the example, and nothing else
      # about the suite's WebMock setup is touched.
      def self.serve!
        webmock!
        wire_targets.map do |url, graph|
          client = GraphWeaver::Internal::TestClients.client_for(:wire, graph)
          stub = WebMock::API.stub_request(:post, url)
          # to_rack returns the stub's response list, not the stub, so the
          # handle unserve! needs is the one stub_request handed back
          stub.to_rack(GraphWeaver::Testing::Endpoint.new(client))
          [stub, client]
        end
      end

      # Take one stub back down. Only ours — a suite's other stubs, and
      # whether it allows net connections, are its own business.
      def self.unserve!(stub) = WebMock::API.remove_request_stub(stub)

      # Every endpoint an example's modules can post to, each with the graph
      # whose resolvers belong behind it: one per declared graph baking a
      # client of its own, then GraphWeaver.client's for the modules baking
      # none. Distinct by endpoint, graphs first — two clients on one url get
      # one server, as they would in production.
      def self.wire_targets
        bound = GraphWeaver.graphs.filter_map do |graph|
          client = baked_client(graph)
          [endpoint!(client, graph), graph] if client
        end
        app = [endpoint!(GraphWeaver.client), GraphWeaver::Internal::TestClients.app_graph]
        (bound << app).uniq(&:first)
      end

      # The client a graph's generated modules call. `client:` holds a
      # constant or its name — codegen writes it into source — so a name is
      # resolved here the way the generated DEFAULT_CLIENT lambda resolves it.
      def self.baked_client(graph)
        named = graph.client
        return named unless named.is_a?(String)

        Object.const_get(named)
      rescue NameError
        raise GraphWeaver::Error, "#{TAG}: graph #{graph.name.inspect} bakes client: " \
          "#{named.inspect} into its modules and nothing defines that constant, so :wire can't " \
          "find the endpoint they post to."
      end

      # The endpoint a client posts to: a transport, a Retry around one, or a
      # Client that built one. `graph` says whose client it is, when it isn't
      # the app's own.
      def self.endpoint!(client = GraphWeaver.client, graph = nil)
        target = (client.transport if client.respond_to?(:transport)) || client
        url = target.url if target.respond_to?(:url)
        return url if url

        raise GraphWeaver::Error, "#{TAG}: :wire runs your own transport against your resolvers, " \
          "so it needs the endpoint that transport posts to — and #{whose_client(client, graph)}. " \
          "There is nothing to serve. Point the client at a url " \
          "(GraphWeaver.new(\"https://api.example.com/graphql\")), or tag the example " \
          "#{TAG}: :in_process or #{TAG}: :router — they run above the wire."
      end

      # which client posts to nothing — the app's, or one graph's
      def self.whose_client(client, graph)
        return "GraphWeaver.client isn't set" unless client
        return "GraphWeaver.client is #{client.class}, which posts to none" unless graph&.name

        "graph #{graph.name.inspect} bakes client: #{client.class}, which posts to none"
      end

      def self.webmock!
        unless defined?(WebMock)
          raise GraphWeaver::Error, "#{TAG}: :wire serves your resolvers over HTTP, which needs " \
            "webmock — it hooks Net::HTTP, Faraday and HTTPX, so your own transport runs unchanged. " \
            "Add it to the Gemfile (group :test) and `require \"webmock/rspec\"` in your spec helper."
        end
        unless webmock_enabled?
          raise GraphWeaver::Error, "#{TAG}: :wire stubs your endpoints with webmock, which is " \
            "loaded but not enabled — nothing is hooked, so this example's requests would leave " \
            "the suite for the real endpoint. `require \"webmock/rspec\"` in your spec helper " \
            "(Bundler.require only loads it), or WebMock.enable! for the suite."
        end

        require "rack" # WebMock's to_rack builds a Rack env but doesn't depend on rack
      rescue LoadError
        raise GraphWeaver::Error, "#{TAG}: :wire needs rack — webmock's to_rack builds a Rack " \
          "env with it, but doesn't depend on it. Add it to the Gemfile (group :test)."
      end

      # WebMock has no "am I enabled" of its own, so the signal is the swap it
      # makes: enable! puts its own subclass in Net::HTTP, disable! puts the
      # original back. Requiring it only registers the adapters.
      def self.webmock_enabled?
        return true unless defined?(WebMock::HttpLibAdapters::NetHttpAdapter::OriginalNetHTTP)

        !WebMock::HttpLibAdapters::NetHttpAdapter::OriginalNetHTTP.equal?(Net::HTTP)
      end

      private_class_method :wire_targets, :baked_client, :whose_client, :webmock!, :webmock_enabled?

      # Included into every example group, so graphql_context is there
      # whether or not this example took a client from the hook.
      #
      # One helper per mode that has a per-example argument, named for that
      # mode: graphql_<mode> is `graphql: <mode>` with something passed.
      # :live and :wire have none, so they are the tag alone.
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
          # the same two defaults the tag builds with (Internal::TestClients)
          graph = GraphWeaver::Internal::TestClients.app_graph
          options[:schema] ||= GraphWeaver::Testing.config.reference_schema!(graph)
          options[:registry] ||= graph&.registry
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
          router = GraphWeaver::Internal::TestClients.client_for(:router)
          router.fake = fake if fake
          GraphWeaver.client = router
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
              "graphql_#{mode} — drop one. A tag and a helper are two spellings of one choice, so " \
              "keep the helper when you need to pass it something."
          end

          @__graph_weaver_mode = mode
          # the hook installed the default before this helper spoke; a
          # module bound to its own client resolves through what is claimed
          GraphWeaver::Internal::TestClients.install(mode)
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
          # under :wire the resolvers run behind the endpoints, so the context
          # is on what's served there rather than on GraphWeaver.client — one
          # per graph, and the context is the example's, not a graph's
          served = (@__graph_weaver_served if defined?(@__graph_weaver_served))
          clients = served || [GraphWeaver.client]
          baseline = GraphWeaver::Testing::RSpecIntegration.context!(mode, clients.first)
          return baseline unless values

          merged = baseline.merge(values)
          GraphWeaver::Testing::RSpecIntegration.set_context(mode, merged, clients)
          return merged unless block

          begin
            block.call
          ensure
            GraphWeaver::Testing::RSpecIntegration.set_context(mode, baseline, clients)
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
      # new context in place. :wire serves one client per graph, so it hands
      # over the list.
      def self.set_context(mode, values, clients = [GraphWeaver.client])
        return unless %i[in_process router wire].include?(mode)

        clients.each { |client| client.context = values }
      end
    end
  end
end

RSpec.configure { |config| GraphWeaver::Testing::RSpecIntegration.install(config) } if defined?(RSpec)
