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
  SUPERGRAPH = File.expand_path("support/federation/supergraph.graphql", __dir__)

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
      GraphWeaver.schema_path = SUPERGRAPH
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
        .to raise_error(GraphWeaver::Error, /config\.schema = MySchema.*graphql: :router/m)
    end

    it "refuses a router context that the per-example reset would overwrite" do
      expect { config.router = { supergraph: SUPERGRAPH, context: { current_user_id: "2" } } }
        .to raise_error(ArgumentError, /config\.context/)
    end
  end
end
