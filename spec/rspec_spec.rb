# typed: ignore — schema classes and parsed query modules are invisible to srb
# frozen_string_literal: true

require "graph_weaver/rspec"
require_relative "generated/person_query"

# A live schema whose resolver reads the context — the whole reason
# :in_process exists.
module DraftsDemo
  DRAFTS = [
    { id: "d1", owner: "alice" },
    { id: "d2", owner: "alice" },
    { id: "d3", owner: "bob" },
  ].freeze

  class DraftType < GraphQL::Schema::Object
    graphql_name "Draft"

    field :id, ID, null: false
    field :owner, String, null: false
  end

  class QueryType < GraphQL::Schema::Object
    graphql_name "Query"

    field :drafts, [DraftType], null: false

    def drafts
      DRAFTS.select { |draft| draft[:owner] == context[:current_user] }
    end
  end

  class Schema < GraphQL::Schema
    query QueryType
  end

  # what an app's generated code looks like: no client baked in, so it runs
  # against whichever one the tag installed
  QUERY = GraphWeaver.parse(schema: Schema, query: "query { drafts { id owner } }", name: "DraftsQuery")
end

# The rspec integration end to end: real tags, real hooks, real metadata
# inheritance. Everything here is zero-config on purpose — a suite should
# tag an example and go.
describe "graph_weaver/rspec" do
  # config and GraphWeaver.client are global; an around hook is the only
  # place that runs OUTSIDE the before hooks the integration installs
  around do |example|
    prior_client = GraphWeaver.client
    GraphWeaver::Testing.reset!
    example.run
  ensure
    GraphWeaver.client = prior_client
    GraphWeaver.schema_path = nil
    GraphWeaver::Testing.reset!
  end

  # the shape of a real app: production talks to a server, and the schema
  # it knows is a dump
  def app_client!(schema)
    GraphWeaver.client = GraphWeaver.new(schema.to_definition)
  end

  # a generated module the way a checked-in file is, GRAPH and all — which
  # is the only thing that says which graph a module belongs to
  def module_for(graph_name, schema, query, name)
    source = GraphWeaver::Codegen.new(schema:, query:, name:, graph_name:).generate
    Module.new.tap { |container| container.module_eval(source, "(spec)", 1) }.const_get(name)
  end

  describe "graphql: :fake" do
    around do |example|
      app_client!(DraftsDemo::Schema)
      example.run
    end

    it "fabricates data from the client's own schema", graphql: :fake do
      expect(GraphWeaver.client).to be_a GraphWeaver::Testing::FakeClient
      expect(DraftsDemo::QUERY.execute!.drafts.first&.owner).to be_a String
    end

    it "runs no resolvers — graphql_context has nothing to receive it", graphql: :fake do
      expect { graphql_context(current_user: "alice") }
        .to raise_error(GraphWeaver::Error, /needs resolvers.*:in_process.*graphql_fake\(overrides:/m)
    end

    # the second test anyone writes: fabricated data is fine until the
    # example is ABOUT the data. The tag builds the client in a
    # config.before(:each), which rspec runs ahead of any group hook, so
    # options had nowhere to go — this is where they go.
    describe "pinning what the example is about" do
      it "takes overrides for this example", graphql: :fake do
        graphql_fake(overrides: { "Draft.owner" => "ada", "Query.drafts" => [{}, {}] })

        drafts = DraftsDemo::QUERY.execute!.drafts
        expect(drafts.size).to eq 2
        expect(drafts.map(&:owner)).to eq %w[ada ada]
        expect(drafts.map(&:id)).to all(be_a(String)) # unpinned, still fabricated
      end

      # set in a before block, which is where setup belongs — and the case
      # that silently fabricated random data before
      describe "set in a before hook" do
        before { graphql_fake(overrides: { "Draft.owner" => "ada" }) }

        it "pins the owner" do
          expect(DraftsDemo::QUERY.execute!.drafts.map(&:owner).uniq).to eq %w[ada]
        end
      end

      it "hands back the client, so the request is assertable" do
        fake = graphql_fake

        DraftsDemo::QUERY.execute!
        expect(fake.requests.size).to eq 1
        expect(fake.requests.first[:query]).to include "drafts"
      end

      # PersonQuery bakes DEFAULT_CLIENT = Demo::Schema, which sits above
      # GraphWeaver.client — the tag has to stand in for that too
      it "reaches a module generated with its own client:" do
        fake = graphql_fake

        PersonQuery.execute(id: "1") # this group's fake knows no Person; the request is the proof
        expect(fake.requests.size).to eq 1
      end

      # pins lead and options follow, in one call — Ruby 3 hands every
      # braceless pair to **options, so the fake sorts them, not the parser
      it "takes pins first and options after" do
        graphql_fake("Draft.owner" => "ada", "Query.drafts" => [{}, {}], values: :literal)

        drafts = DraftsDemo::QUERY.execute!.drafts
        expect(drafts.map(&:owner)).to eq %w[ada ada]
        expect(drafts.map(&:id)).to all(match(/\A\d+\z/))
      end

      it "reads a quoted-symbol key as a pin" do
        graphql_fake("Draft.owner": "ada")

        expect(DraftsDemo::QUERY.execute!.drafts.map(&:owner).uniq).to eq %w[ada]
      end

      # rspec's --seed already drives the fake; a second seed is the one
      # that stops it reproducing the run
      it "refuses a per-example seed, naming rspec's" do
        expect { graphql_fake(seed: 1) }
          .to raise_error(GraphWeaver::Error, /seed: isn't a per-example option.*rspec --seed 1234.*config\.seed/m)
      end
    end
  end

  # the README's example, as written there
  # A tag has an answer per module even where the suite has none — each
  # module says which graph it came from. The hook derived one client for the
  # whole example, so it refused before any module was reached.
  describe "graphql: :fake, with more than one graph" do
    around do |example|
      app_client!(DraftsDemo::Schema)
      GraphWeaver.graph(:drafts) { schema DraftsDemo::Schema }
      GraphWeaver.graph(:pets) { schema Demo::Schema }
      example.run
    ensure
      GraphWeaver.reset_graphs!
    end

    it "fakes each module against its own graph's schema", graphql: :fake do
      drafts = module_for(:drafts, DraftsDemo::Schema, "query { drafts { id owner } }", "DraftsFaked")
      pets = module_for(:pets, Demo::Schema, "query { person(id: 1) { email } }", "PetsFaked")

      expect(drafts.execute!.drafts.first&.owner).to be_a String
      expect(pets.execute!.person&.email).to be_a String
      # nothing app-wide to install, so the app's own client stays in the slot
      expect(GraphWeaver.client).to be_a GraphWeaver::Client
    end

    # graphql_fake installed itself at GraphWeaver.client, which each module's
    # per-graph stand-in outranks — so a correct pin was quietly dropped and
    # the example passed on data nobody pinned
    it "pins the graph its schema names, and leaves the other alone", graphql: :fake do
      drafts = module_for(:drafts, DraftsDemo::Schema, "query { drafts { id owner } }", "DraftsPinned")
      pets = module_for(:pets, Demo::Schema, "query { person(id: 1) { name } }", "PetsUnpinned")

      fake = graphql_fake({ "Draft.owner" => "ada" }, schema: DraftsDemo::Schema)

      expect(drafts.execute!.drafts.map(&:owner).uniq).to eq %w[ada]
      expect(fake.requests.size).to eq 1
      expect(pets.execute!.person&.name).to be_a String
      expect(fake.requests.size).to eq 1 # pets ran against its own graph's fake
    end

    # the advice used to lead straight into that silent drop
    it "refuses a bare graphql_fake, naming the graphs and schema:", graphql: :fake do
      expect { graphql_fake("Draft.owner" => "ada") }
        .to raise_error(GraphWeaver::Error, /:drafts, :pets.*graphql_fake\(schema:/m)
    end

    it "refuses a schema no declared graph names", graphql: :fake do
      expect { graphql_fake(schema: RouterGraph::Reviews::Schema) }
        .to raise_error(GraphWeaver::Error, /names none of this app's graphs.*:drafts, :pets/m)
    end
  end

  # Every helper writes to the same slot a module reads, so what an example
  # says applies to the modules it runs — or refuses, naming the graphs.
  describe "the helpers, with more than one graph" do
    around do |example|
      require_relative "support/federation_router_graph"
      app_client!(DraftsDemo::Schema)
      GraphWeaver.graph(:drafts) { schema DraftsDemo::Schema }
      GraphWeaver.graph(:pets) { schema Demo::Schema }
      example.run
    ensure
      GraphWeaver.reset_graphs!
    end

    let(:drafts) do
      module_for(:drafts, DraftsDemo::Schema, "query { drafts { id owner } }", "DraftsScoped")
    end

    it "runs the resolvers of the graph graphql_in_process names", graphql: :in_process do
      graphql_in_process(DraftsDemo::Schema)
      graphql_context(current_user: "alice")

      expect(drafts.execute!.drafts.map(&:id)).to eq %w[d1 d2]
    end

    # the tag alone: no helper named a graph, and the context still has to
    # reach the stand-in each module resolves for itself
    it "reaches a stand-in the tag built, with no helper at all", graphql: :in_process do
      GraphWeaver::Testing.config.schema = DraftsDemo::Schema
      graphql_context(current_user: "alice")

      expect(drafts.execute!.drafts.map(&:id)).to eq %w[d1 d2]
    end

    it "refuses graphql_in_process with no schema, naming the graphs", graphql: :in_process do
      expect { graphql_in_process }
        .to raise_error(GraphWeaver::Error, /:drafts, :pets.*graphql_in_process\(MySchema\)/m)
    end

    # graphql_router names no schema, so there is nothing for it to say which
    # graph a fake: is for — and the tag alone already routes each module
    it "refuses graphql_router, pointing at the tag and config.router" do
      expect { graphql_router(fake: { "Draft.owner" => "ada" }) }
        .to raise_error(GraphWeaver::Error, /:drafts, :pets.*config\.router = \{ fake:/m)
    end
  end

  describe "the README's pins", graphql: :fake do
    around do |example|
      app_client!(Demo::Schema)
      example.run
    end

    it "runs" do
      person_query = GraphWeaver.parse(schema: Demo::Schema, name: "ReadmePersonQuery",
        query: "query Person($id: ID!) { person(id: $id) { name pets { name } } }")

      graphql_fake("Person.name" => "Ada", "Person.pets" => [{ "name" => "Shelby" }, {}])
      person = person_query.execute!(id: "1").person

      expect(person.name).to eq "Ada"
      expect(person.pets.first.name).to eq "Shelby"
      expect(person.pets.size).to eq 2
    end
  end

  describe "graphql: :in_process" do
    around do |example|
      app_client!(DraftsDemo::Schema)
      GraphWeaver::Testing.configure do |config|
        config.schema = DraftsDemo::Schema
        config.context = { current_user: "bob" }
      end
      example.run
    end

    it "runs the configured schema class's resolvers", graphql: :in_process do
      expect(GraphWeaver.client).to be_a GraphWeaver::InProcess
      expect(GraphWeaver.client.schema).to be DraftsDemo::Schema
      expect(DraftsDemo::QUERY.execute!.drafts.map(&:id)).to eq %w[d3]
    end

    # a federated app has no one live class, so which subgraph's resolvers
    # this example runs is the example's to say
    it "runs a schema the example names instead", graphql: :in_process do
      require_relative "support/federation_router_graph"
      subgraph = Object.const_get("RouterGraph::Reviews::Schema")

      graphql_in_process(subgraph)

      expect(GraphWeaver.client.schema).to be subgraph
      expect(GraphWeaver.client.execute("{ reviews { body } }", variables: {})
        .dig("data", "reviews").map { |review| review["body"] }).to include "Love it"
    end

    # default_mode answers for examples that said nothing, so a helper is the
    # example finally saying something — not a contradiction
    it "lets a helper override config.default_mode without a tag" do
      GraphWeaver::Testing.config.default_mode = :fake

      expect { graphql_in_process(DraftsDemo::Schema) }.not_to raise_error
      expect(GraphWeaver.client).to be_a GraphWeaver::InProcess
    ensure
      GraphWeaver::Testing.config.default_mode = :live
    end

    it "refuses a helper that contradicts the tag", graphql: :fake do
      expect { graphql_in_process(Demo::Schema) }
        .to raise_error(GraphWeaver::Error, /tagged graphql: :fake but calls graphql_in_process/)
    end

    it "allows the helper the tag already named", graphql: :fake do
      expect { graphql_fake }.not_to raise_error
    end

    it "needs no tag, and is restored after the example" do
      require_relative "support/federation_router_graph"
      graphql_in_process(Object.const_get("RouterGraph::Reviews::Schema"))

      expect(GraphWeaver.client).to be_a GraphWeaver::InProcess
    end

    # each asserts the baseline BEFORE setting its own, so whichever runs
    # second proves the context didn't leak
    %w[alice bob].each do |user|
      it "starts every example from config.context (#{user})", graphql: :in_process do
        expect(DraftsDemo::QUERY.execute!.drafts.map(&:owner).uniq).to eq %w[bob]

        graphql_context(current_user: user)
        expect(DraftsDemo::QUERY.execute!.drafts.map(&:owner).uniq).to eq [user]
      end
    end

    it "merges onto the baseline rather than replacing it", graphql: :in_process do
      graphql_context(tenant: "acme")

      expect(graphql_context).to eq({ current_user: "bob", tenant: "acme" })
    end

    # context is setup, so it belongs in a before block — the per-example
    # reset is a config-level before(:each), which rspec runs ahead of any
    # group hook, so each example re-applies this from the same baseline
    describe "set in a before block", graphql: :in_process do
      before { graphql_context(current_user: "alice") }

      %w[1 2].each do |example|
        it "applies to every example in the group (#{example})" do
          expect(DraftsDemo::QUERY.execute!.drafts.map(&:owner).uniq).to eq %w[alice]
        end
      end
    end

    it "scopes a context to a block", graphql: :in_process do
      owners = graphql_context(current_user: "alice") do
        DraftsDemo::QUERY.execute!.drafts.map(&:owner).uniq
      end

      expect(owners).to eq %w[alice]
      expect(DraftsDemo::QUERY.execute!.drafts.map(&:owner).uniq).to eq %w[bob]
    end
  end

  # the tag on the group, which is most of the point: metadata inherits, so
  # a whole feature's specs run against real resolvers
  describe "graphql: :router", graphql: :router do
    around do |example|
      # the conventional dump IS the composed supergraph here, so there is
      # nothing to configure
      GraphWeaver.schema_path = RouterGraph::SUPERGRAPH
      example.run
    end

    def username = GraphWeaver.client.execute("{ me { username } }").dig("data", "me", "username")

    it "runs the real subgraph resolvers, stitched" do
      expect(GraphWeaver.client).to be_a GraphWeaver::Testing::Router
      expect(GraphWeaver.client.execute("{ me { username reviews { body } } }").dig("data", "me"))
        .to eq({ "username" => "dpep", "reviews" => [{ "body" => "Love it" }, { "body" => "Too expensive" }] })
    end

    %w[1 2].each do |id|
      it "resets the shared router's context every example (#{id})" do
        expect(username).to eq "dpep" # the baseline, whatever ran before

        graphql_context(current_user_id: id)
        expect(username).to eq(id == "1" ? "dpep" : "ada")
      end
    end
  end

  # :router used to plan against ONE supergraph for the suite, so a module
  # from a graph that has none was posted at another graph's — and the
  # failure blamed a stale dump instead of naming the graph.
  describe "graphql: :router, with more than one graph", graphql: :router do
    around do |example|
      require_relative "support/federation_router_graph"
      GraphWeaver.graph(:storefront) { schema RouterGraph::SUPERGRAPH }
      GraphWeaver.graph(:drafts) { schema DraftsDemo::Schema }
      example.run
    ensure
      GraphWeaver.reset_graphs!
    end

    it "plans each module against the supergraph its own graph names" do
      supergraph = GraphWeaver::Internal::Util.schema_for(RouterGraph::SUPERGRAPH)
      dashboard = module_for(:storefront, supergraph, "query { me { username } }", "RoutedDashboard")

      expect(dashboard.execute!.me.username).to eq "dpep"
    end

    # graphql_context wrote to GraphWeaver.client, which a multi-graph app
    # leaves alone — so it raised NoMethodError on nil instead of reaching
    # the routers the example's modules run through
    it "reaches the router each module runs through" do
      supergraph = GraphWeaver::Internal::Util.schema_for(RouterGraph::SUPERGRAPH)
      dashboard = module_for(:storefront, supergraph, "query { me { username } }", "ScopedDashboard")

      graphql_context(current_user_id: "2")

      expect(dashboard.execute!.me.username).to eq "ada"
    end

    it "refuses a module whose graph is in no supergraph, naming the graph" do
      drafts = module_for(:drafts, DraftsDemo::Schema, "query { drafts { id owner } }", "RoutedDrafts")

      expect { drafts.execute! }.to raise_error(GraphWeaver::Error,
        /composed supergraph.*graph :drafts is in none.*graphql: :in_process/m)
    end
  end

  # The router is built once for the suite, so per-example fake data has to
  # reach it without rebuilding it — the tag alone leaves nowhere to put it.
  describe "graphql_router(fake:)" do
    before do
      require_relative "support/federation_router_graph"
      GraphWeaver::Testing.config.router = {
        supergraph: Object.const_get("RouterGraph::PARTIAL_SUPERGRAPH"),
        subgraphs: { "shipping" => :fake },
      }
    end

    def carrier = GraphWeaver.client.execute("{ shipments { carrier } }").dig("data", "shipments", 0, "carrier")

    it "pins a faked subgraph's data for this example" do
      graphql_router(fake: { "Shipment.carrier" => "UPS" })
      expect(carrier).to eq "UPS"
    end

    it "refuses a per-example seed, naming rspec's" do
      expect { graphql_router(fake: { seed: 1 }) }
        .to raise_error(GraphWeaver::Error, /seed: isn't a per-example option.*rspec --seed 1234/m)
    end

    # the fake is reached through three doors and only one of them is a
    # method signature, so the refusal has to be the fake's own
    it "refuses an option a fake doesn't take" do
      expect { graphql_router(fake: { overides: { "Shipment.carrier" => "UPS" } }) }
        .to raise_error(ArgumentError, /overides:.*did you mean overrides:/m)
    end

    it "takes suite-wide fake options from config.router" do
      GraphWeaver::Testing.config.router = GraphWeaver::Testing.config.router
        .merge(fake: { overrides: { "Shipment.carrier" => "DHL" } })
      graphql_router

      expect(carrier).to eq "DHL"
    end
  end

  describe "an untagged example" do
    it "leaves GraphWeaver.client alone by default" do
      expect(GraphWeaver.client).to be_nil
      expect { graphql_context(current_user: "alice") }
        .to raise_error(GraphWeaver::Error, /tag it graphql: :in_process/)
    end

    # the beginner's first mistake is a forgotten tag, and "set
    # GraphWeaver.client=" is advice for the wrong file
    it "names the tag when nothing installed a client" do
      expect { DraftsDemo::QUERY.execute! }
        .to raise_error(GraphWeaver::Error, /no client configured — tag the example graphql: :fake/)
    end

    context "with config.default_mode" do
      around do |example|
        app_client!(DraftsDemo::Schema)
        GraphWeaver::Testing.configure { |config| config.default_mode = :fake }
        example.run
      end

      it "runs against the default" do
        expect(GraphWeaver.client).to be_a GraphWeaver::Testing::FakeClient
      end

      # A default sweeps in every untagged example, including the one that
      # wires its own client — which is the case a default creates. Each
      # asserts the baseline BEFORE building its own, so whichever runs
      # second proves a :live example's client is restored too: it used not
      # to be, which made "tag :fake, then throw the client away" the idiom
      # for cleanup.
      %w[1 2].each do |example|
        it "steps back out with graphql: :live (#{example})", graphql: :live do
          expect(GraphWeaver.client).to be_a GraphWeaver::Client # what the group installed

          GraphWeaver.client = GraphWeaver::InProcess.new(DraftsDemo::Schema, context: { current_user: "alice" })
          expect(DraftsDemo::QUERY.execute!.drafts.map(&:id)).to eq %w[d1 d2] # no hook fighting it
        end
      end

      # :live is a mode like the others, so it is the one choice this
      # example made — a helper saying something else is one of the two
      # being a mistake
      it "refuses a helper that contradicts it", graphql: :live do
        expect { graphql_fake }
          .to raise_error(GraphWeaver::Error, /tagged graphql: :live but calls graphql_fake/)
      end
    end

    # the default default: every example has a mode, and an untagged one's
    # is :live unless the suite says otherwise
    context "with config.default_mode = :live" do
      around do |example|
        app_client!(DraftsDemo::Schema)
        GraphWeaver::Testing.configure { |config| config.default_mode = :live }
        example.run
      end

      it "leaves the app's own client in the slot" do
        expect(GraphWeaver.client).to be_a GraphWeaver::Client
        expect(GraphWeaver::Testing::RSpecIntegration.mode_for({})).to eq :live
      end
    end
  end

  describe "refusals" do
    let(:config) { GraphWeaver::Testing.config }

    it "names the modes when the tag isn't one" do
      expect { GraphWeaver::Testing::RSpecIntegration.mode_for({ graphql: :in_proces }) }
        .to raise_error(GraphWeaver::Error, /:in_proces is not a mode.*:live, :fake, :in_process, :router/m)
    end

    # the spelling this replaced, so an upgrading suite is told what to
    # write instead rather than left with a bare "not a mode"
    it "names :live when the tag is the old false" do
      expect { GraphWeaver::Testing::RSpecIntegration.mode_for({ graphql: false }) }
        .to raise_error(GraphWeaver::Error, /false is not a mode.*:live leaves GraphWeaver\.client/m)
    end

    it "says why :router needs the supergraph named, when nothing on disk is one" do
      GraphWeaver.schema_path = File.expand_path("support/federation/package.json", __dir__)

      expect { GraphWeaver::Internal::TestClients.client_for(:router) }
        .to raise_error(GraphWeaver::Error, /@join__\* routing table stripped out.*package\.json.*config\.router/m)
    end

    it "says what it looked for when no schema resolves at all" do
      expect { GraphWeaver::Internal::TestClients.client_for(:fake) }
        .to raise_error(GraphWeaver::Error, /GraphWeaver\.client isn't set.*config\.schema is unset/m)
    end

    # the client talks to a server, so there's no live class behind it
    it "says to name the schema when :in_process has no live class" do
      app_client!(DraftsDemo::Schema)

      expect { GraphWeaver::Internal::TestClients.client_for(:in_process) }
        .to raise_error(GraphWeaver::Error, /graphql_in_process\(MySchema\).*graphql: :router/m)
    end

    # config.context is the baseline the example's clients are built with, and
    # they are built before any group hook runs — so one set from inside an
    # example silently never arrived at a resolver. Every example has a mode,
    # so this refuses in all of them; an around hook is outside, and allowed.
    it "refuses config.context set inside an example, naming graphql_context" do
      expect { config.context = { current_user: "alice" } }
        .to raise_error(GraphWeaver::Error, /graphql_context.*Testing\.configure/m)
    end

    it "refuses a router context that the per-example reset would overwrite" do
      expect { config.router = { supergraph: RouterGraph::SUPERGRAPH, context: { current_user_id: "2" } } }
        .to raise_error(ArgumentError, /config\.context/)
    end
  end
end
