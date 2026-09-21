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
#      :wire        your schema, served at your client's endpoint, so the
#                   transport you ship runs
#
# `rspec --tag graphql:router` runs one mode's examples.
#
# `GraphWeaver.client` is snapshotted before every example and restored
# after — whatever its mode, and whatever the example did to it. So an
# untagged (:live) example, a `before` block, or a shared context is free to
# build the client it wants and have it cleaned up like a tagged one:
#
#      it "backs off" { GraphWeaver.client = GraphWeaver::Testing::Failure.throttled }
#
# **Nothing needs configuring.** Each mode derives what it runs against —
# **per graph**, since with more than one the honest answer varies — and
# refuses, naming what it looked for, rather than guessing:
#
#   - the schema is GraphWeaver::Testing.config.schema if you set one, else
#     the one that graph names, else the committed dump at
#     GraphWeaver.schema_path, else the schema of GraphWeaver.client.
#   - :in_process runs against config.schema, or the class that graph names,
#     or the one your client already uses. Only a live class has resolvers,
#     so when none is there it says so rather than hunting for one.
#   - :router plans against the composed supergraph that graph names, else
#     config.router = { supergraph: … }, else the dump when that's what it
#     is — and refuses a graph that is in none by name, rather than routing
#     it into another graph's. Subgraphs are derived from what each loaded
#     schema defines; one nothing here serves is absent, and only a query
#     that reaches its fields is refused.
#   - :wire serves what each graph IS, at the endpoint that graph's own
#     client posts to, leaving every client in place so the real transport
#     runs: its router when that graph is in a composed supergraph, its live
#     schema class when it has one, else a fake of its schema — which is what
#     an app that is a pure client of someone else's API has. Only a graph
#     with no schema at all is refused. An app whose graphs all bake a
#     `client:` needs no GraphWeaver.client at all. Needs webmock and rack
#     (`require "webmock/rspec"`); webmock hooks Net::HTTP, Faraday and HTTPX.
#
# What it wires up:
#   - seed: defaults to rspec's --seed, so `rspec --seed 1234` reproduces
#     fake data along with test order
#   - a stand-in per graph, from the tag (or config.default_mode for an
#     untagged one; :live, the default, leaves every client alone), and
#     GraphWeaver.client restored afterwards either way.
#   - graphql_context — the GraphQL context resolvers see, merged onto
#     config.context, reaching every stand-in the example runs through, and
#     reset between examples.
#
# A helper — graphql_fake, graphql_in_process, graphql_router — is the
# stand-in for the modules of the graph `graph:` names, for this app's only
# graph when it names none, and refuses when there is none it can reach. Under
# :wire it is what gets SERVED behind that graph's endpoint, rather than what
# fills the client slot — which is how a :wire example pins its data.
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
          GraphWeaver::Internal::TestClients.install(@__graph_weaver_mode)
          # :wire is the one mode that does NOT take the client slot — every
          # client staying where it is is the whole point, so what the tag
          # builds is served at each of their endpoints instead
          @__graph_weaver_stubs = nil
          if @__graph_weaver_mode == :wire
            @__graph_weaver_stubs = GraphWeaver::Testing::RSpecIntegration.serve!
          else
            # one graph, one answer — so the app's client slot holds it too,
            # the same object that graph's modules resolve; with several it
            # holds a refusal, since the real client there is a live request
            # waiting to happen. :live leaves the slot alone (app_client nil).
            app_client = GraphWeaver::Internal::TestClients.app_client
            GraphWeaver.client = app_client if app_client
          end
        end

        rspec_config.after(:each) do
          # first, so a refused tag still tears the mode down
          GraphWeaver::Internal::TestClients.reset!
          next unless defined?(@__graph_weaver_prior_client)

          if defined?(@__graph_weaver_stubs) && @__graph_weaver_stubs
            @__graph_weaver_stubs.each { |stub| GraphWeaver::Testing::RSpecIntegration.unserve!(stub) }
          end
          remove_instance_variable(:@__graph_weaver_stubs) if defined?(@__graph_weaver_stubs)
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
      # the ones posting to GraphWeaver.client. Returns the stubs; {unserve!}
      # takes one back down after the example, and nothing else about the
      # suite's WebMock setup is touched.
      def self.serve!
        webmock!
        targets, above = wire_targets
        above.each { |graph| disclose_above!(graph) }
        targets.map do |url, graph|
          # built here, so a graph with nothing to serve refuses before the
          # example runs rather than from inside its first request
          disclose!(GraphWeaver::Internal::TestClients.standin(graph), url, graph)
          stub = WebMock::API.stub_request(:post, url)
          # and read again per request: a graphql_* helper in the example body
          # runs after this hook, and a pin that never reached the served
          # endpoint would leave the example green and wrong. Through the
          # stand-in table either way, so graphql_context reaches what is
          # served here as it reaches every other mode's client.
          #
          # to_rack returns the stub's response list, not the stub, so the
          # handle unserve! needs is the one stub_request handed back
          stub.to_rack(lambda do |env|
            client = GraphWeaver::Internal::TestClients.standin(graph)
            GraphWeaver::Testing::Endpoint.new(client).call(env)
          end)
          stub
        end
      end

      # Say what went behind this endpoint. :wire is the one tag that picks
      # from three candidates, and the pick is invisible from the example —
      # an app that owns resolvers can be served a fake and pass against
      # fabricated data. So it narrates, on the logger a Rails app already
      # has (the railtie wires Rails.logger).
      #
      #      graph_weaver: :wire serving Shop::Schema (in-process) at http://…
      #
      # At warn, with the advice, when a fake stood in while this process
      # HAS a schema class and nothing named it — a warning rather than a
      # refusal because a loaded class isn't proof the app meant it here (a
      # federated suite loads every subgraph's), and because serve! runs
      # before the example body, so `graphql_fake` has no way to say "on
      # purpose" in time to be heard.
      def self.disclose!(client, url, graph)
        unnamed = unnamed_schemas(graph) if client.is_a?(GraphWeaver::Testing::FakeClient)
        if unnamed&.any?
          GraphWeaver::Internal::Log.log(:warn) do
            ":wire serving #{served(client)} at #{url} — #{unnamed.join(", ")} " \
              "#{unnamed.one? ? "is" : "are"} loaded and nothing named #{unnamed.one? ? "it" : "one"}, " \
              "so your resolvers did not run. To serve them, name it: " \
              "GraphWeaver::Testing.config.schema = #{unnamed.first}"
          end
        else
          GraphWeaver::Internal::Log.log(:info) { ":wire serving #{served(client)} at #{url}" }
        end
      end

      # Say which graph ran above the wire. Its stand-in is built when one of
      # its modules first runs, not here — a graph the example never touches
      # must not refuse it — so this names the graph rather than what is
      # behind it.
      def self.disclose_above!(graph)
        GraphWeaver::Internal::Log.log(:info) do
          ":wire has no endpoint for #{graph.name ? "graph #{graph.name.inspect}" : "this app"} — " \
            "its client posts to none, so its modules run above the wire, as #{TAG}: :in_process would"
        end
      end

      # What the stand-in IS, read off the object rather than re-deciding —
      # one answer, and it can't drift from what was built. A fake of a dump
      # has no name to give: the dump loads as an anonymous class, and
      # guessing which file it came from would be a label that can be wrong.
      def self.served(client)
        case client
        when GraphWeaver::Testing::Router then "the router"
        when GraphWeaver::InProcess then "#{client.schema.name} (in-process)"
        else client.schema.name ? "#{client.schema.name} (fake)" : "a fake"
        end
      end

      # Live schema classes this process has loaded that nothing pointed
      # :wire at. Named ones only — a dump loads as an anonymous subclass,
      # and graphql-ruby's own NullSchema is not the app's. A class some
      # graph already runs is named, just not by this graph. Sorted, because
      # Class#subclasses is in no order and a log line should be the same
      # line twice.
      def self.unnamed_schemas(graph)
        claimed = GraphWeaver.graphs.filter_map(&:live_schema)
        loaded_schemas
          .reject { |schema| claimed.include?(schema) || schema.equal?(graph&.live_schema) }
          .sort_by(&:name)
      end

      # Class#subclasses is direct descendants only, so an app with its own
      # base schema class needs the walk.
      def self.loaded_schemas(root = GraphQL::Schema)
        root.subclasses.flat_map do |schema|
          named = schema.name && !schema.name.start_with?("GraphQL::") ? [schema] : []
          named + loaded_schemas(schema)
        end
      end

      # Take one stub back down. Only ours — a suite's other stubs, and
      # whether it allows net connections, are its own business.
      #
      # Deleted rather than removed: the suite may have taken it down
      # already (a group's own `after { WebMock.reset! }` runs first — rspec
      # runs after hooks innermost-first), and remove_request_stub raises on
      # a stub it can't find, piling a second failure on the example from
      # inside the cleanup.
      def self.unserve!(stub) = WebMock::StubRegistry.instance.request_stubs.delete(stub)

      # What :wire does with each graph, in two lists: the endpoints to stub,
      # each with the graph whose resolvers belong behind it, and the graphs
      # there is no endpoint for. One graph per endpoint — an app whose graphs
      # all name clients needs no app default at all.
      #
      # A graph whose client posts to no url has no wire to be served at, so
      # it runs above one instead of refusing the example — including the
      # examples that never touch it. An example where NO graph posts anywhere
      # is refused, since a :wire that serves nothing tests no transport.
      def self.wire_targets
        targets, above = GraphWeaver.graphs.map { |graph| [graph.client_url, graph] }.partition(&:first)
        refuse_shared_endpoint!(targets)
        return [targets, above.map(&:last)] if targets.any?

        # the endpoint refusal names the client that posts to none, which is
        # the thing to fix
        graph = GraphWeaver.graphs.first
        endpoint!(graph&.client || GraphWeaver.client, graph)
      end

      # One stub per url, so two graphs on one endpoint used to mean the
      # first graph's schema answering both — and the second's fields coming
      # back as "doesn't exist on type 'Query'", which blames the query.
      def self.refuse_shared_endpoint!(targets)
        url, shared = targets.group_by(&:first).find { |_, at| at.size > 1 }
        return unless shared

        names = shared.map { |_, graph| graph.name.inspect }.join(", ")
        raise GraphWeaver::Error, "#{TAG}: :wire serves one schema at each endpoint, and graphs " \
          "#{names} post to the same one (#{url}) — whichever were served there would answer the " \
          "others' queries, as fields its schema doesn't define. Give each graph a client of its " \
          "own (`client` in the graph block), or tag the example #{TAG}: :in_process or " \
          "#{TAG}: :router, which run above the wire."
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

      # which client posts to nothing — the app's, or one graph's. A schema
      # class in a client slot is named by ITS name: `client.class` is the
      # word "Class", which names nothing anyone wrote.
      def self.whose_client(client, graph)
        return "GraphWeaver.client isn't set" unless client

        named = client.is_a?(Module) ? client : client.class
        return "GraphWeaver.client is #{named}, which posts to none" unless graph&.name

        "graph #{graph.name.inspect} names client #{named}, which posts to none"
      end

      def self.webmock!
        unless defined?(WebMock)
          raise GraphWeaver::Error, "#{TAG}: :wire serves your schema over HTTP, which needs " \
            "webmock and rack — webmock hooks Net::HTTP, Faraday and HTTPX so your own transport " \
            "runs unchanged, and its to_rack builds the Rack env with rack. Add both to the " \
            "Gemfile (group :test) and `require \"webmock/rspec\"` in your spec helper."
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

      private_class_method :wire_targets, :refuse_shared_endpoint!, :whose_client,
        :webmock!, :webmock_enabled?, :disclose!, :disclose_above!, :served, :unnamed_schemas,
        :loaded_schemas

      # Included into every example group, so graphql_context is there
      # whether or not this example took a client from the hook.
      #
      # One helper per mode that has a per-example argument, named for that
      # mode: graphql_<mode> is `graphql: <mode>` with something passed.
      # :live and :wire have none, so they are the tag alone.
      #
      # **A helper called in an example is the stand-in for the modules of the
      # graph `graph:` names — for this app's only graph when it names none —
      # and it refuses, naming the graphs, when there is none it can reach.**
      # So what an example says applies to what it then runs: a helper used to
      # install itself at GraphWeaver.client, which each module's per-graph
      # stand-in outranks, and a correct pin was silently dropped.
      #
      # **The tag sets the mode for every graph no helper named**, so one
      # example runs two graphs in two modes — `graphql: :router` plus
      # `graphql_fake(graph: :countries)` routes the federated graph and fakes
      # the plain one. A helper reinstalled the example's one mode and cleared
      # the table, so whichever graph was named last decided both.
      #
      # `graph:` takes the graph's name, the same handle `rake
      # graph_weaver:graphs` prints and codegen bakes into a module. A schema
      # object still names a graph too — `graphql_in_process(Reviews::Schema)`
      # is the schema AND the graph in one word — but only a graph that runs
      # that class in-process; one whose schema is a dump has no object to be
      # matched by, and `graph:` is what reaches it.
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
        # With more than one graph, `graph:` says which one's modules this
        # fake stands in for — pins are schema-shaped, so there is no app-wide
        # answer to guess at:
        #
        #      graphql_fake(graph: :poke, "pokemon_v2_pokemon.name" => "pikachu")
        #
        # Installed for that graph and restored after the example, like a
        # tagged one — so the tag is optional here, not required.
        def graphql_fake(pins = {}, graph: nil, **options)
          refuse_seed!(options)
          graphs = targets!("graphql_fake", options[:schema],
            "A fake fabricates that graph's shapes, with its scalar registrations.", graph:)
          claim_mode!(:fake, graphs)
          # the same two defaults the tag builds with (Internal::TestClients)
          options[:schema] ||= GraphWeaver::Testing.config.reference_schema!(graphs.first)
          options[:registry] ||= graphs.first&.registry
          stand_in!(GraphWeaver::Testing::FakeClient.new(pins, **options), graphs)
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
        def graphql_in_process(schema = nil, graph: nil, **options)
          graphs = targets!("graphql_in_process", schema,
            "That graph's own schema class runs, and its resolvers stand in for its modules.",
            graph:)
          claim_mode!(:in_process, graphs)
          schema ||= GraphWeaver::Testing.config.schema_class!(graphs.first)
          options[:context] ||= GraphWeaver::Internal::TestClients.context
          stand_in!(GraphWeaver::InProcess.new(schema, **options), graphs)
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
        # A router is built once per supergraph — parsing one per example is
        # real time — so this installs that one and tells it where this
        # example starts. With more than one graph, `graph:` says whose
        # supergraph the `fake:` is for; the tag alone already routes each
        # module through its own.
        def graphql_router(fake: nil, graph: nil)
          refuse_seed!(fake) if fake
          graphs = targets!("graphql_router", nil,
            "The tag alone already routes each module through its own graph's supergraph; name a " \
            "graph only to say whose the fake: is for.", graph:)
          claim_mode!(:router, graphs)
          # :router explicitly: under a :wire tag the table would otherwise
          # hand back whatever :wire picked for this graph
          router = GraphWeaver::Internal::TestClients.standin(graphs.first, :router)
          router.fake = fake if fake
          stand_in!(router, graphs)
        end

        # A tag and a helper are two spellings of one choice WHEN the helper
        # speaks for the whole example — which, in an app with one graph, it
        # always does. They can then agree (`graphql: :fake` plus
        # `graphql_fake(overrides:)` is the documented way to pass options)
        # but must not contradict: one of the two is a mistake, and silently
        # letting the later one win hides which.
        #
        # `graphs` is what this helper stands in for, so a helper naming one
        # graph of several isn't contradicting anything — the tag is still
        # the example's mode for every graph it leaves alone.
        #
        # :wire is the exception because it is not the same question — it says
        # a stand-in is served rather than substituted, and the helper says
        # which stand-in.
        private def claim_mode!(mode, graphs)
          # :wire says WHERE a stand-in runs — served at the endpoint the
          # client posts to — not which one it is, so a helper under it names
          # what goes behind the wire and the example stays :wire
          return if wire?
          return unless graphs.size == GraphWeaver.graphs.size

          # only an explicit tag can contradict a helper. config.default_mode
          # is a fallback for examples that said nothing, so a helper is the
          # example finally saying something — not a disagreement.
          tagged = defined?(@__graph_weaver_tag) ? @__graph_weaver_tag : nil
          return unless tagged && tagged != mode

          # Kernel.raise: this module is mixed into every example group, so
          # it doesn't include Kernel for sorbet to find
          Kernel.raise GraphWeaver::Error, "this example is tagged #{TAG}: #{tagged.inspect} but calls " \
            "graphql_#{mode} — drop one. A tag and a helper are two spellings of one choice, so " \
            "keep the helper when you need to pass it something."
        end

        # The graphs this helper's client stands in for — see the rule above.
        private def targets!(helper, schema, advice, graph: nil)
          GraphWeaver::Internal::TestClients.targets!(helper, schema, advice, graph:)
        end

        # Put `client` in the slot those graphs' modules read. An app with one
        # graph has one answer, so the app slot holds it too — which is what
        # GraphWeaver.client reads back as, and what makes this helper's
        # return value the object the modules actually run against.
        private def stand_in!(client, graphs)
          GraphWeaver::Internal::TestClients.override!(client, graphs)
          # except under :wire, where this is served at the graph's endpoint
          # instead — the app's own client has to stay in the slot for the
          # transport under test to run at all
          GraphWeaver.client = client if GraphWeaver.graphs.one? && !wire?
          client
        end

        # Whether this example serves its stand-ins rather than substituting
        # them. Read off the mode, not the tag, so config.default_mode = :wire
        # behaves the same way.
        private def wire? = defined?(@__graph_weaver_mode) && @__graph_weaver_mode == :wire

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
          baseline = GraphWeaver::Testing::RSpecIntegration.context!(mode)
          return baseline unless values

          merged = baseline.merge(values)
          GraphWeaver::Internal::TestClients.context = merged
          return merged unless block

          begin
            block.call
          ensure
            GraphWeaver::Internal::TestClients.context = baseline
          end
        end
      end

      # A fake has no resolvers to hand a context to, so silently ignoring
      # one would leave an example asserting on data nothing scoped.
      def self.context!(mode)
        case mode
        when :in_process, :router
          # a context: proc is answered from the request's headers, so
          # there is no baseline here to merge onto
          Internal::Util.context!(Internal::TestClients.context)
        when :wire
          wire_context!
        when :fake
          raise GraphWeaver::Error, "graphql_context needs resolvers to receive it, and a " \
            "#{TAG}: :fake example runs against fabricated data — tag it #{TAG}: :in_process or " \
            "#{TAG}: :router (or pin the data itself: " \
            "graphql_fake(\"Person.name\" => \"Ada\"))"
        else
          raise GraphWeaver::Error, "graphql_context needs an example running against your " \
            "resolvers — tag it #{TAG}: :in_process or #{TAG}: :router"
        end
      end

      # :wire is the one mode that IS a request, so a context: proc is
      # answered — by the headers the example's own transport sends. The
      # generic refusal says to tag the example :wire, which this one already
      # is; what to change here is the header.
      def self.wire_context!
        context = Internal::TestClients.context
        return context unless context.respond_to?(:call)

        raise GraphWeaver::Error, "context: is a proc, so it is answered from the headers of each " \
          "request — which is what #{TAG}: :wire makes, and why graphql_context has nothing here " \
          "to read or merge onto. Say who this example is where the headers are, on the client's " \
          "own transport: GraphWeaver.new(url, headers: { \"X-User\" => \"2\" }) — a header value " \
          "may itself be a proc, so it can vary per request."
      end
      private_class_method :wire_context!
    end
  end
end

RSpec.configure { |config| GraphWeaver::Testing::RSpecIntegration.install(config) } if defined?(RSpec)
