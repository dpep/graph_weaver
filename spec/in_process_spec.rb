require "logger"
require "stringio"

# a schema whose resolvers need the request: one reads context, one blows up
module InProcessDemo
  class QueryType < GraphQL::Schema::Object
    graphql_name "Query"

    field :me, String

    def me = context[:current_user]

    field :boom, String

    def boom = raise("kaboom")
  end

  class Schema < GraphQL::Schema
    query QueryType
  end
end

describe GraphWeaver::InProcess do
  let(:context) { { current_user: "dpep" } }
  let(:client) { described_class.new(InProcessDemo::Schema, context:) }

  it "hands its context to resolvers" do
    expect(client.execute("query { me }").to_h.dig("data", "me")).to eq "dpep"
  end

  it "runs the operation the caller names out of a multi-operation document" do
    document = "query Me { me }\nquery Boom { boom }"

    expect(client.execute(document, operation_name: "Me").to_h.dig("data", "me")).to eq "dpep"
    # decisive: unasked, the document's first operation would have run
    expect { client.execute(document, operation_name: "Boom") }
      .to raise_error(GraphWeaver::ServerError, /kaboom/)
  end

  it "brands a resolver raise, keeping the original as #cause" do
    expect { client.execute("query { boom }") }
      .to raise_error(GraphWeaver::ServerError, /kaboom/) { |e|
        expect(e.status).to eq 500
        expect(e.cause).to be_a RuntimeError
        expect(e.cause.backtrace.join).to include("in_process_spec.rb")
      }
  end

  it "logs the query and its timing, like a network transport" do
    io = StringIO.new
    GraphWeaver.logger = Logger.new(io, level: Logger::DEBUG)

    client.execute("query Me { me }")

    expect(io.string).to include("in-process InProcessDemo::Schema")
    expect(io.string).to include("query Me { me }")
    expect(io.string).to match(/\[req \d+ Me\].*completed \(\d+ms\)/)
  ensure
    GraphWeaver.logger = nil
  end

  it "never leaks the context through inspect/to_s" do
    secretive = described_class.new(InProcessDemo::Schema, context: { token: "s3cret" })

    expect(secretive.inspect).not_to include("s3cret")
    expect(secretive.to_s).not_to include("s3cret")
  end

  it "rejects something that isn't a schema" do
    expect { described_class.new("not a schema") }.to raise_error(ArgumentError, /schema/)
  end

  # the duck-typed client slot has no base class: wrapping is an upgrade,
  # never a requirement
  it "leaves a bare schema class working in the client slot" do
    expect(InProcessDemo::Schema.execute("query { me }").to_h.dig("data", "me")).to be_nil
  end

  describe "through GraphWeaver.new" do
    it "wraps a schema class and passes context: to its resolvers" do
      weaver = GraphWeaver.new(InProcessDemo::Schema, context:)

      expect(weaver.transport).to be_a described_class
      expect(weaver.run!("query { me }").me).to eq "dpep"
    end

    it "wraps even without a context, for the logging and branded errors" do
      expect(GraphWeaver.new(InProcessDemo::Schema).transport).to be_a described_class
    end

    it "refuses a context nothing would read" do
      expect { GraphWeaver.new("http://example.test/graphql", context:) }
        .to raise_error(ArgumentError, /context:/)
      expect { GraphWeaver.new(InProcessDemo::Schema, transport: Demo::Schema, context:) }
        .to raise_error(ArgumentError, /context:/)
    end
  end
end
