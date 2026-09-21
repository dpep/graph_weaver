# typed: ignore — schema classes and parsed query modules are invisible to srb
# frozen_string_literal: true

require "bigdecimal"
require "logger"
require "stringio"
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

  # the same schema as type information only — what an app that is a pure
  # client of someone else's API has, with no resolvers anywhere
  SDL = Schema.to_definition

  CLIENT = GraphWeaver.new(ENDPOINT)
  # a client that posts nowhere — what :wire has nothing to serve for
  IN_PROCESS = GraphWeaver::InProcess.new(Schema)
end

# A second graph, with a schema of its own and a client of its own posting
# somewhere of its own — the endpoint nothing used to stub.
module BillingWire
  ENDPOINT = "http://billing.wire.test/graphql"

  class InvoiceType < GraphQL::Schema::Object
    graphql_name "Invoice"

    field :id, ID, null: false
    field :buyer, String, null: false
  end

  class QueryType < GraphQL::Schema::Object
    graphql_name "Query"

    field :invoice, InvoiceType, null: false

    def invoice = { id: "i1", buyer: "billing" }
  end

  class Schema < GraphQL::Schema
    query QueryType
  end

  QUERY = "query Invoice { invoice { id buyer } }"

  CLIENT = GraphWeaver.new(ENDPOINT)
end

# A third graph, federated: what sits behind ITS endpoint is the router,
# while the two above are answered by their own schema classes.
module RoutedWire
  ENDPOINT = "http://routed.wire.test/graphql"
  CLIENT = GraphWeaver.new(ENDPOINT)
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

  # One stub read off GraphWeaver.client served one endpoint, so a second
  # graph's modules posted straight past it.
  describe "several graphs, each behind its own wire" do
    around do |example|
      GraphWeaver.graph :orders do
        schema WireDemo::Schema
        client "WireDemo::CLIENT"
      end
      GraphWeaver.graph :billing do
        schema BillingWire::Schema
        client "BillingWire::CLIENT"
      end
      GraphWeaver.client = WireDemo::CLIENT
      example.run
    ensure
      GraphWeaver.reset_graphs!
    end

    it "serves each graph's own endpoint that graph's own resolvers", graphql: :wire do
      # neither names a client: parse reads the graph off the schema, and each
      # graph names its own
      orders = GraphWeaver.parse(schema: WireDemo::Schema, query: WireDemo::QUERY)
      invoices = GraphWeaver.parse(schema: BillingWire::Schema, query: BillingWire::QUERY)

      expect(orders.execute!.order.buyer).to eq "nobody"       # WireDemo's resolver
      expect(invoices.execute!.invoice.buyer).to eq "billing"  # BillingWire's

      expect(exchanges.map { |request, _| request.uri.host })
        .to contain_exactly("wire.test", "billing.wire.test")
    end

    it "takes every stub down after the example" do
      expect { WireDemo::CLIENT.execute("{ order { buyer } }") }
        .to raise_error(WebMock::NetConnectNotAllowedError)
      expect { BillingWire::CLIENT.execute("{ invoice { buyer } }") }
        .to raise_error(WebMock::NetConnectNotAllowedError)
    end

    # every module bakes its own client, so there is no app-wide endpoint to
    # serve and nothing left for GraphWeaver.client to answer
    context "with no app-default client" do
      # the tag reads the endpoints in a before hook, so the slot has to be
      # empty before that runs
      around do |example|
        GraphWeaver.client = nil
        example.run
      end

      it "serves every graph anyway", graphql: :wire do
        expect(WireDemo::CLIENT.execute(WireDemo::QUERY).dig("data", "order", "buyer")).to eq "nobody"
        expect(BillingWire::CLIENT.execute(BillingWire::QUERY).dig("data", "invoice", "buyer"))
          .to eq "billing"
      end
    end
  end

  # An app that owns resolvers AND calls someone else's API has one graph
  # posting nowhere, and reading every endpoint up front refused the whole
  # example for it — so its remote graphs could not be tested over the wire
  # at all.
  describe "one graph on a wire and one posting nowhere" do
    around do |example|
      GraphWeaver.graph :orders do
        schema WireDemo::Schema
        client "WireDemo::IN_PROCESS"
      end
      GraphWeaver.graph :billing do
        schema BillingWire::Schema
        client "BillingWire::CLIENT"
      end
      GraphWeaver.client = BillingWire::CLIENT
      example.run
    ensure
      GraphWeaver.reset_graphs!
    end

    it "serves the graph that posts somewhere and runs the other above the wire", graphql: :wire do
      orders = GraphWeaver.parse(schema: WireDemo::Schema, query: WireDemo::QUERY)
      invoices = GraphWeaver.parse(schema: BillingWire::Schema, query: BillingWire::QUERY)

      expect(orders.execute!.order.buyer).to eq "nobody"       # WireDemo's resolver, in-process
      expect(invoices.execute!.invoice.buyer).to eq "billing"  # over BillingWire's transport

      expect(exchanges.map { |request, _| request.uri.host }).to eq ["billing.wire.test"]
    end

    # the client slot holding the app's own client is the whole point of the
    # tag, and a graph served above the wire must not take it
    it "still leaves the app's own client in the slot", graphql: :wire do
      expect(GraphWeaver.client).to be BillingWire::CLIENT
    end

    it "runs it under graphql_context, as an endpoint's resolvers are", graphql: :wire do
      graphql_context(current_user: "ada")
      orders = GraphWeaver.parse(schema: WireDemo::Schema, query: WireDemo::QUERY)

      expect(orders.execute!.order.buyer).to eq "ada"
    end
  end

  # A graph :wire can serve nothing for used to refuse the whole example —
  # including the graphs it could serve, and including examples that never
  # touch it.
  describe "a graph with neither an endpoint nor a schema" do
    around do |example|
      GraphWeaver.graph(:orders) { client "WireDemo::IN_PROCESS" }
      GraphWeaver.graph :billing do
        schema BillingWire::Schema
        client "BillingWire::CLIENT"
      end
      GraphWeaver.client = BillingWire::CLIENT
      example.run
    ensure
      GraphWeaver.reset_graphs!
    end

    it "serves the graph it can", graphql: :wire do
      expect(BillingWire::CLIENT.execute(BillingWire::QUERY).dig("data", "invoice", "buyer"))
        .to eq "billing"
    end

    # and in the words of the state it is in: this graph posts nowhere, so
    # every sentence about an endpoint, a stub and a URL= refresh is false
    # for it — what it is missing is a schema
    it "refuses, naming the graph, only when that graph's module runs", graphql: :wire do
      orders = GraphWeaver.parse(schema: WireDemo::Schema, query: WireDemo::QUERY, graph: :orders)

      expect { orders.execute! }.to raise_error(GraphWeaver::Error) { |error|
        expect(error.message).to include(":wire has no endpoint for graph :orders — its client " \
          "posts to none, so its modules run above the wire")
        expect(error.message).to include("GraphWeaver.graph(:orders) { schema -> { MySchema } }")
        expect(error.message).not_to include("URL=", "the endpoint :wire has stubbed")
      }
    end
  end

  # "router or live class" was decided once for the suite, so one federated
  # graph put its router behind EVERY endpoint — a plain graph's included.
  describe "one graph federated and one not" do
    around do |example|
      GraphWeaver.graph :orders do
        schema WireDemo::Schema
        client "WireDemo::CLIENT"
      end
      GraphWeaver.graph :storefront do
        schema RouterGraph::SUPERGRAPH
        client "RoutedWire::CLIENT"
      end
      GraphWeaver.client = WireDemo::CLIENT
      example.run
    ensure
      GraphWeaver.reset_graphs!
    end

    it "serves each endpoint what its own graph is", graphql: :wire do
      expect(WireDemo::CLIENT.execute(WireDemo::QUERY).dig("data", "order", "buyer")).to eq "nobody"
      expect(RoutedWire::CLIENT.execute("{ me { username } }").dig("data", "me", "username"))
        .to eq "dpep"
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

    # the context is the request's, so graphql_context has nothing to merge
    # onto — and the advice has to be about the header, not the tag, since
    # this example is already tagged the way the generic message says to
    it "refuses graphql_context, naming the header instead", graphql: :wire do
      expect { graphql_context(current_user_id: "1") }
        .to raise_error(GraphWeaver::Error, /context: is a proc.*headers.*GraphWeaver\.new\(url, headers:/m)
    end

    it "refuses reading it back the same way", graphql: :wire do
      expect { graphql_context }
        .to raise_error(GraphWeaver::Error, /GraphWeaver\.new\(url, headers:/)
    end

    # End to end through the harness, which is where the seam has to hold:
    # rspec.rb builds an Endpoint per request over one client memoized per
    # example, so a lock on the Endpoint guarded nothing and 6 of 8 threads
    # read another thread's identity.
    it "serves each concurrent request its own identity", graphql: :wire do
      app_client!("http://graph.test/graphql",
        headers: { "X-User" => -> { Thread.current[:wire_user] } })

      served = %w[1 2 1 2 1 2 1 2].each_with_index.map do |user, i|
        Thread.new do
          Thread.current[:wire_user] = user
          ["#{user}/#{i}", GraphWeaver.client.execute("{ me { id } }").dig("data", "me", "id")]
        end
      end.map(&:value)

      expect(served.map { |sent, got| [sent, got] })
        .to all(satisfy { |sent, got| sent.start_with?("#{got}/") })
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

      expect { order_query.execute! }.to raise_error(GraphWeaver::CastError, /total/)
    end

    # graphql_context reaches the resolvers behind the endpoint, not the
    # app's client — which has none
    it "runs the schema class's real resolvers, under graphql_context", graphql: :wire do
      graphql_context(current_user: "ada")
      order_query = GraphWeaver.parse(schema: WireDemo::Schema, query: WireDemo::QUERY)

      expect(order_query.execute!.order.buyer).to eq "ada"
    end

    # the same rule for the other two helpers: under :wire a helper names
    # what is SERVED, options and all, rather than contradicting the tag
    it "serves the schema class a helper names", graphql: :wire do
      graphql_in_process(WireDemo::Schema, context: { current_user: "ada" })
      order_query = GraphWeaver.parse(schema: WireDemo::Schema, query: WireDemo::QUERY)

      expect(order_query.execute!.order.buyer).to eq "ada"
    end

    # rspec runs `after` hooks innermost-first, so a suite's own
    # `after { WebMock.reset! }` takes our stub down before this gem's hook
    # reaches it — which used to raise from inside the cleanup and pile a
    # second, unrelated failure on the example
    it "survives a suite that resets webmock itself", graphql: :wire do
      WebMock.reset!
    end
  end

  # what a faked subgraph fabricates was suite-wide under :wire, since the tag
  # took no helper — a helper here says it per example, like every other mode
  describe "a faked subgraph behind the wire" do
    around do |example|
      GraphWeaver::Testing.config.router = {
        supergraph: RouterGraph::PARTIAL_SUPERGRAPH,
        subgraphs: { "shipping" => :fake },
      }
      app_client!("http://graph.test/graphql")
      example.run
    end

    it "pins what that subgraph fabricates, for this example", graphql: :wire do
      graphql_router(fake: { "Shipment.carrier" => "UPS" })

      carrier = GraphWeaver.client.execute("{ shipments { carrier } }")
      expect(carrier.dig("data", "shipments", 0, "carrier")).to eq "UPS"
      expect(exchanges.size).to eq 1 # and through the transport, not past it
    end
  end

  # An app that is a pure client of someone else's API has a dump and no
  # resolvers anywhere — the shape :wire used to refuse, asking for a
  # GraphQL::Schema class the app has no reason to own.
  describe "a graph with no schema class of its own" do
    around do |example|
      GraphWeaver.graph(:orders) { schema WireDemo::SDL }
      app_client!
      example.run
    ensure
      GraphWeaver.reset_graphs!
    end

    let(:order_query) { GraphWeaver.parse(schema: WireDemo::SDL, query: WireDemo::QUERY) }

    it "serves a fake of that schema, over the transport", graphql: :wire do
      order = order_query.execute!.order

      expect(order.id).to be_a String # fabricated, and schema-correct
      expect(exchanges.size).to eq 1  # and it really crossed the wire
      expect(JSON.parse(exchanges.first.first.body)["query"]).to include "order { id total buyer }"
    end

    # the whole point of allowing the helper here: pins are one example's
    # question, and a suite-wide config.overrides can't answer it
    it "serves what a helper pins, not what it invented", graphql: :wire do
      graphql_fake("Order.buyer" => "ada")

      expect(order_query.execute!.order.buyer).to eq "ada"
    end

    it "leaves the app's own client in the slot — that is still the point", graphql: :wire do
      graphql_fake("Order.buyer" => "ada")

      expect(GraphWeaver.client).to be_a GraphWeaver::Client
      expect(GraphWeaver.client.transport).to be_a GraphWeaver::Transport::HTTP
    end

    # the fake answers the server's side, so its record is what the endpoint
    # was asked — the assertion that used to need a webmock callback
    it "hands back the fake it serves", graphql: :wire do
      fake = graphql_fake

      order_query.execute!

      expect(fake.requests.map { |request| request[:operation_name] }).to eq ["Order"]
    end

    it "still refuses a helper that contradicts an ordinary tag", graphql: :fake do
      expect { graphql_in_process(WireDemo::Schema) }
        .to raise_error(GraphWeaver::Error, /tagged graphql: :fake but calls graphql_in_process/)
    end
  end

  # :wire is the one tag that picks from three candidates, and the pick is
  # invisible from inside the example — an app that owns resolvers being
  # served a fake is a green run against fabricated data. So it says which,
  # on the logger a Rails app already has.
  describe "what it says it served" do
    let(:io) { StringIO.new }

    # outside the tag's own before hook, which is where the line is written
    around do |example|
      GraphWeaver.logger = Logger.new(io, level: Logger::INFO)
      example.run
    ensure
      GraphWeaver.logger = nil
    end

    context "with the live class named" do
      around do |example|
        GraphWeaver::Testing.config.schema = WireDemo::Schema
        app_client!
        example.run
      end

      # and nothing else: every GraphWeaver::Error writes a warn line as it is
      # built, so the predicates deciding what to serve used to log two
      # refusals that never happened in front of this one
      it "names it and the endpoint, at info and nothing louder", graphql: :wire do
        expect(io.string).to include(":wire serving WireDemo::Schema (in-process) at #{WireDemo::ENDPOINT}")
        expect(io.string).not_to include("WARN")
      end
    end

    # the silent green run this exists for: a url client, no config.schema,
    # and the app's own schema class sitting right there unnamed
    context "with a fake standing in while the process has a schema class" do
      around do |example|
        GraphWeaver.graph(:orders) { schema WireDemo::SDL }
        app_client!
        example.run
      ensure
        GraphWeaver.reset_graphs!
      end

      it "warns, naming a class it could have served and how to say so", graphql: :wire do
        expect(io.string).to include("WARN")
        expect(io.string).to include(":wire serving a fake at #{WireDemo::ENDPOINT}")
        expect(io.string).to match(/WireDemo::Schema.*loaded and nothing named/)
        expect(io.string).to include("your resolvers did not run")
        expect(io.string).to match(/GraphWeaver::Testing\.config\.schema = \w/)
      end
    end

    # a graph run above the wire is the other invisible pick: the example
    # asked for its transport and that transport never ran
    context "with a graph whose client posts nowhere" do
      around do |example|
        GraphWeaver.graph :orders do
          schema WireDemo::Schema
          client "WireDemo::IN_PROCESS"
        end
        GraphWeaver.graph :billing do
          schema BillingWire::Schema
          client "BillingWire::CLIENT"
        end
        GraphWeaver.client = BillingWire::CLIENT
        example.run
      ensure
        GraphWeaver.reset_graphs!
      end

      it "names that graph, and still names what each endpoint got", graphql: :wire do
        expect(io.string)
          .to include(":wire has no endpoint for graph :orders — its client posts to none")
        expect(io.string)
          .to include(":wire serving BillingWire::Schema (in-process) at #{BillingWire::ENDPOINT}")
      end
    end
  end

  # :wire has no failure injection of its own and needs none: it adds one
  # stub per endpoint, and webmock answers with the LAST stub declared for a
  # url — so an example that wants the server to fail declares its own, and
  # the transport meets a real response rather than a raise from inside the
  # stub. That is the documented recipe (docs/testing.md).
  describe "serving a failure" do
    around do |example|
      GraphWeaver::Testing.config.schema = WireDemo::Schema
      app_client!(WireDemo::ENDPOINT, retries: 2)
      example.run
    end

    it "serves a 503 the transport reads back with its headers", graphql: :wire do
      failing = WebMock::API.stub_request(:post, WireDemo::ENDPOINT)
        .to_return(status: 503, headers: { "Retry-After" => "0" }, body: "down for maintenance")

      expect { GraphWeaver.client.execute(WireDemo::QUERY) }
        .to raise_error(GraphWeaver::ServerError) { |error|
          expect(error.status).to eq 503
          expect(error.retry_after).to eq 0    # the header crossed the wire
          expect(error.throttled?).to be true
        }
      expect(exchanges.size).to eq 3           # and the real Retry ran: 1 + retries: 2
    ensure
      WebMock::API.remove_request_stub(failing)
    end

    it "serves a timeout the transport reads as a TransportError", graphql: :wire do
      failing = WebMock::API.stub_request(:post, WireDemo::ENDPOINT).to_timeout

      expect { GraphWeaver.client.execute(WireDemo::QUERY) }
        .to raise_error(GraphWeaver::TransportError, /timeout|timed out/i)
    ensure
      WebMock::API.remove_request_stub(failing)
    end

    # the tag's own stub is still the one underneath, so an example that
    # doesn't declare a failure is answered by the schema as usual
    it "leaves the served schema answering the examples that don't", graphql: :wire do
      expect(GraphWeaver.client.execute(WireDemo::QUERY).dig("data", "order", "id")).to eq "o1"
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

    # both gems up front: rack was named only by a second refusal, fired
    # after webmock's was fixed — two round trips through `bundle install`
    it "names webmock and rack, and the line to add, when webmock isn't loaded" do
      webmock = Object.send(:remove_const, :WebMock)

      expect { integration.serve! }
        .to raise_error(GraphWeaver::Error, /webmock and rack.*require "webmock\/rspec"/m)
    ensure
      Object.const_set(:WebMock, webmock)
    end

    # Bundler.require makes `defined?(WebMock)` true in every Rails app with
    # webmock in :test, while only webmock/rspec (or WebMock.enable!) installs
    # the adapters — so the old check passed and the first request left the
    # suite for the real endpoint
    it "refuses before the first request when webmock is loaded but not enabled" do
      WebMock.disable!

      expect { integration.serve! }
        .to raise_error(GraphWeaver::Error, /loaded but not enabled.*require "webmock\/rspec"/m)
    ensure
      WebMock.enable!
    end

    it "names the client's class when it posts nowhere" do
      GraphWeaver.client = GraphWeaver::InProcess.new(WireDemo::Schema)

      expect { integration.endpoint! }
        .to raise_error(GraphWeaver::Error, /GraphWeaver::InProcess.*nothing to serve/m)
    end

    # `client.class` on a schema class is the word "Class", which names
    # nothing the app wrote — and a graph naming one directly is the shape a
    # pure in-process graph has
    it "names a bare schema class by its own name, not Class" do
      GraphWeaver.graph(:orders) { schema WireDemo::Schema; client WireDemo::Schema }

      expect { integration.serve! }
        .to raise_error(GraphWeaver::Error, /graph :orders names client WireDemo::Schema, which posts to none/)
    ensure
      GraphWeaver.reset_graphs!
    end

    it "says GraphWeaver.client isn't set when it isn't" do
      GraphWeaver.client = nil

      expect { integration.endpoint! }.to raise_error(GraphWeaver::Error, /GraphWeaver\.client isn't set/)
    end

    it "names the graph whose client posts nowhere, not just the app's" do
      GraphWeaver.graph :billing do
        schema BillingWire::Schema
        client "WireDemo::IN_PROCESS"
      end

      expect { integration.serve! }
        .to raise_error(GraphWeaver::Error, /graph :billing names client GraphWeaver::InProcess.*nothing to serve/m)
    ensure
      GraphWeaver.reset_graphs!
    end

    # Zeitwerk hasn't loaded it, or it's a typo — either way a module resolving
    # the same graph's client would fail the same way
    it "names the constant a graph names when nothing defines it" do
      GraphWeaver.graph :billing do
        schema BillingWire::Schema
        client "Nope::CLIENT"
      end

      expect { integration.serve! }
        .to raise_error(GraphWeaver::Error, /the client in graph :billing names "Nope::CLIENT".*nothing defines/m)
    ensure
      GraphWeaver.reset_graphs!
    end

    # they used to be uniq'd by url, so whichever was stubbed first answered
    # both graphs' queries — and the second graph's fields came back as
    # "doesn't exist on type 'Query'", blaming the query
    it "refuses two graphs at one endpoint, naming both and the url" do
      GraphWeaver.graph(:orders) { schema WireDemo::Schema; client "WireDemo::CLIENT" }
      GraphWeaver.graph(:billing) { schema BillingWire::Schema; client "WireDemo::CLIENT" }

      expect { integration.serve! }
        .to raise_error(GraphWeaver::Error, /:orders, :billing.*#{Regexp.escape(WireDemo::ENDPOINT)}/m)
    ensure
      GraphWeaver.reset_graphs!
    end

    it "names :wire among the modes" do
      expect { integration.mode_for({ graphql: :wired }) }
        .to raise_error(GraphWeaver::Error, /:fake, :in_process, :router, :wire/)
    end
  end
end
