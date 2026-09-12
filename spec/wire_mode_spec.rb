# typed: ignore — schema classes and parsed query modules are invisible to srb
# frozen_string_literal: true

require "bigdecimal"
require "graph_weaver/rspec"
require "graph_weaver/transport/faraday"
require "webmock"

# One schema with a custom scalar, so the wire has something to disagree
# about. The server writes Money as "12.50"; the client below is registered
# to *write* it as "$12.50", which is the spelling that must never come
# back — proof the response bytes are the server's and not a round trip
# through the client's own codecs.
module WireDemo
  ENDPOINT = "http://wire.test/graphql"

  class MoneyType < GraphQL::Schema::Scalar
    graphql_name "Money"

    def self.coerce_result(value, _ctx) = format("%.2f", value)
    def self.coerce_input(value, _ctx) = BigDecimal(value.to_s.delete("$"))
  end

  class OrderType < GraphQL::Schema::Object
    graphql_name "Order"

    field :id, ID, null: false
    field :total, MoneyType, null: false
    field :buyer, String, null: false
  end

  class QueryType < GraphQL::Schema::Object
    graphql_name "Query"

    field :order, OrderType, null: false

    def order = { id: "o1", total: BigDecimal("12.50"), buyer: context[:current_user] || "nobody" }
  end

  class Schema < GraphQL::Schema
    query QueryType
  end

  QUERY = "query Order { order { id total buyer } }"
end

# The fourth tag: your resolvers, served at the endpoint your own client
# posts to, so the transport you ship actually runs.
describe "graphql: :wire" do
  # WebMock swaps Net::HTTP process-wide and this suite also talks to real
  # local webrick servers, so it is on for this file alone
  before(:all) { WebMock.enable! }
  after(:all) { WebMock.disable! }

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
    GraphWeaver::Codegen.reset_scalars!
  end

  # every request that actually crossed the stub, with the bytes each way —
  # the request the transport wrote, and the response it read back
  let(:exchanges) { [] }

  before { WebMock.after_request { |request, response| exchanges << [request, response] } }
  after { WebMock.reset_callbacks }

  def app_client!(url = WireDemo::ENDPOINT, **options)
    GraphWeaver.client = GraphWeaver.new(url, **options)
  end

  describe "a federated graph behind the wire" do
    around do |example|
      # the conventional dump IS the composed supergraph, so :wire serves
      # the router for the same reason :router would
      GraphWeaver.schema_path = RouterGraph::SUPERGRAPH
      app_client!("http://graph.test/graphql")
      example.run
    end

    let(:query) { "query Dashboard { me { username reviews { body } } }" }

    it "answers what :router answers, over the transport", graphql: :wire do
      direct = GraphWeaver::Testing::Router.new(supergraph: RouterGraph::SUPERGRAPH).execute(query)

      expect(GraphWeaver.client.execute(query)).to eq direct
      expect(direct.dig("data", "me", "username")).to eq "dpep" # the query really ran
    end

    it "leaves the app's own client in the slot — that is the point", graphql: :wire do
      expect(GraphWeaver.client).to be_a GraphWeaver::Client
      expect(GraphWeaver.client.transport).to be_a GraphWeaver::Transport::HTTP
    end

    # the claim the docs make for webmock: it hooks underneath, so the
    # transport an app actually ships runs unchanged. The client has to exist
    # before the tag reads its endpoint, so an around hook builds it — those
    # wrap every before, the integration's included.
    %i[http faraday].each do |kind|
      context "over a #{kind} transport" do
        around do |example|
          app_client!("http://graph.test/graphql", transport: kind, retries: 2)
          example.run
        end

        it "runs it, and a Retry wrapping one", graphql: :wire do
          expect(GraphWeaver.client.transport).to be_a GraphWeaver::Retry

          expect(GraphWeaver.client.execute("{ me { username } }").dig("data", "me", "username"))
            .to eq "dpep"
          expect(exchanges.size).to eq 1
        end
      end
    end

    it "sends exactly one POST carrying query, variables and operationName", graphql: :wire do
      GraphWeaver.client.execute(query, variables: { "first" => 2 })

      expect(exchanges.size).to eq 1
      request, = exchanges.first
      expect(request.uri.to_s).to eq "http://graph.test:80/graphql"
      expect(JSON.parse(request.body)).to eq({
        "query" => query, "variables" => { "first" => 2 }, "operationName" => "Dashboard",
      })
    end

    it "removes its stub after the example, so the next one hits no server" do
      # no tag: whatever the previous example stubbed must be gone
      expect { GraphWeaver.client.execute("{ me { username } }") }
        .to raise_error(WebMock::NetConnectNotAllowedError)
    end

    # a suite that already uses WebMock owns its own stubs and its own
    # net-connect policy — the tag adds one stub and takes that one back
    it "leaves the suite's other stubs standing", graphql: :wire do
      theirs = WebMock::API.stub_request(:get, "http://elsewhere.test/ping").to_return(body: "pong")

      GraphWeaver.client.execute("{ me { username } }")

      expect(Net::HTTP.get(URI("http://elsewhere.test/ping"))).to eq "pong"
    ensure
      WebMock::API.remove_request_stub(theirs)
    end
  end

  describe "identity from the request's headers" do
    around do |example|
      GraphWeaver.schema_path = RouterGraph::SUPERGRAPH
      app_client!("http://graph.test/graphql", headers: { "X-User" => "2" })
      GraphWeaver::Testing.config.context = ->(headers) { { current_user_id: headers["X-User"] } }
      example.run
    end

    it "reaches the resolvers through the context: proc", graphql: :wire do
      expect(GraphWeaver.client.execute("{ me { username } }").dig("data", "me", "username"))
        .to eq "ada" # user 2, named by the header the app's transport sent
    end

    # the context is the request's, so graphql_context has nothing to merge onto
    it "refuses graphql_context, naming the header instead", graphql: :wire do
      expect { graphql_context(current_user_id: "1") }
        .to raise_error(GraphWeaver::Error, /context: is a proc.*header/m)
    end
  end

  describe "one schema behind the wire" do
    around do |example|
      GraphWeaver::Testing.config.schema = WireDemo::Schema
      app_client!
      example.run
    end

    # THE proof this mode is worth having: if the response were re-encoded
    # through the client's own serialize:, the round trip would agree with
    # itself and pass even where a real server disagrees.
    it "carries the server's spelling of a scalar, not the client's", graphql: :wire do
      GraphWeaver.register_scalar("Money", BigDecimal,
        cast: ->(expr) { "BigDecimal(#{expr})" },
        serialize: ->(expr) { "\"$\#{#{expr}.to_s(\"F\")}\"" },
        requires: "bigdecimal")
      order_query = GraphWeaver.parse(schema: WireDemo::Schema, query: WireDemo::QUERY)

      order = order_query.execute!.order

      _request, response = exchanges.first
      expect(response.body).to include '"total":"12.50"'
      expect(response.body).not_to include "$" # the client's spelling never made it out
      expect(order.total).to eq BigDecimal("12.50")
    end

    # the other half: a double that hid a disagreement would be worse than
    # no double at all
    it "fails through the wire, naming the field, when the cast is wrong for it", graphql: :wire do
      GraphWeaver.register_scalar("Money", Integer, cast: ->(expr) { "Integer(#{expr})" })
      order_query = GraphWeaver.parse(schema: WireDemo::Schema, query: WireDemo::QUERY)

      expect { order_query.execute! }.to raise_error(GraphWeaver::TypeError, /total/)
    end

    # graphql_context reaches the resolvers behind the endpoint, not the
    # app's client — which has none
    it "runs the schema class's real resolvers, under graphql_context", graphql: :wire do
      graphql_context(current_user: "ada")
      order_query = GraphWeaver.parse(schema: WireDemo::Schema, query: WireDemo::QUERY)

      expect(order_query.execute!.order.buyer).to eq "ada"
    end
  end

  # driven through the integration's own methods, not a tagged example: the
  # tag raises from a before hook, where an expectation can't reach it
  describe "refusals" do
    let(:integration) { GraphWeaver::Testing::RSpecIntegration }

    around do |example|
      GraphWeaver::Testing.config.schema = WireDemo::Schema
      app_client!
      example.run
    end

    it "names webmock and the line to add when it isn't loaded" do
      webmock = Object.send(:remove_const, :WebMock)

      expect { integration.serve!(integration.client_for(:wire)) }
        .to raise_error(GraphWeaver::Error, /webmock.*require "webmock\/rspec"/m)
    ensure
      Object.const_set(:WebMock, webmock)
    end

    it "names the client's class when it posts nowhere" do
      GraphWeaver.client = GraphWeaver::InProcess.new(WireDemo::Schema)

      expect { integration.endpoint! }
        .to raise_error(GraphWeaver::Error, /GraphWeaver::InProcess.*nothing to serve/m)
    end

    it "says GraphWeaver.client isn't set when it isn't" do
      GraphWeaver.client = nil

      expect { integration.endpoint! }.to raise_error(GraphWeaver::Error, /GraphWeaver\.client isn't set/)
    end

    it "names :wire among the modes" do
      expect { integration.mode_for({ graphql: :wired }) }
        .to raise_error(GraphWeaver::Error, /:fake, :in_process, :router, :wire/)
    end
  end
end
