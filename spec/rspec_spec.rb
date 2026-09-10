# typed: ignore — schema classes and parsed query modules are invisible to srb
# frozen_string_literal: true

require "graph_weaver/rspec"

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
      GraphWeaver::Testing.config.default_mode = nil
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
      # second proves an opted-out example's client is restored too: it
      # used not to be, which made "tag :fake, then throw the client away"
      # the idiom for cleanup.
      %w[1 2].each do |example|
        it "opts out with graphql: false (#{example})", graphql: false do
          expect(GraphWeaver.client).to be_a GraphWeaver::Client # what the group installed

          GraphWeaver.client = GraphWeaver::InProcess.new(DraftsDemo::Schema, context: { current_user: "alice" })
          expect(DraftsDemo::QUERY.execute!.drafts.map(&:id)).to eq %w[d1 d2] # no hook fighting it
        end
      end
    end
  end

  describe "refusals" do
    let(:config) { GraphWeaver::Testing.config }

    it "names the modes when the tag isn't one" do
      expect { GraphWeaver::Testing::RSpecIntegration.mode_for({ graphql: :in_proces }) }
        .to raise_error(GraphWeaver::Error, /:in_proces is not a mode.*:fake, :in_process, :router.*false to opt out/m)
    end

    it "says why :router needs the supergraph named, when nothing on disk is one" do
      GraphWeaver.schema_path = File.expand_path("support/federation/package.json", __dir__)

      expect { GraphWeaver::Testing::RSpecIntegration.client_for(:router, config) }
        .to raise_error(GraphWeaver::Error, /@join__\* routing table stripped out.*package\.json.*config\.router/m)
    end

    it "says what it looked for when no schema resolves at all" do
      expect { GraphWeaver::Testing::RSpecIntegration.client_for(:fake, config) }
        .to raise_error(GraphWeaver::Error, /GraphWeaver\.client isn't set.*config\.schema is unset/m)
    end

    # the client talks to a server, so there's no live class behind it
    it "says to name the schema when :in_process has no live class" do
      app_client!(DraftsDemo::Schema)

      expect { GraphWeaver::Testing::RSpecIntegration.client_for(:in_process, config) }
        .to raise_error(GraphWeaver::Error, /graphql_in_process\(MySchema\).*graphql: :router/m)
    end

    it "refuses a router context that the per-example reset would overwrite" do
      expect { config.router = { supergraph: RouterGraph::SUPERGRAPH, context: { current_user_id: "2" } } }
        .to raise_error(ArgumentError, /config\.context/)
    end
  end
end
