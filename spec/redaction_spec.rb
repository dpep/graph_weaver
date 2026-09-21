# typed: ignore — the hostile server is raw sockets, not a schema
require "json"
require "logger"
require "stringio"

# The redaction boundary, enumerated by CHANNEL rather than by value.
#
# "Which values are secret?" was answered well and separately five times —
# variables, InputError#value, url userinfo, url query parameters, dump
# provenance. "Which channels carry text GraphWeaver didn't author?" had never
# been asked, and three of them had no policy at all: a 500 page spliced into
# ServerError#message reached the log at warn with the request's password and
# our own Authorization header in it.
#
# So: one table, one row per channel, the row's name IS its policy. Every row
# drives the same three secrets through the same hostile exchange, and asserts
# none of them survives. A new channel with no row here is a channel with no
# policy.
module Redaction
  PASSWORD = "hunter2-PASSWORD-LEAK"    # a variable the caller sent
  BEARER = "tok_AUTHHEADER-LEAK"        # the Authorization header we sent
  URL_TOKEN = "qs_ACCESSTOKEN-LEAK"     # a credential in the endpoint itself
  OURS = [PASSWORD, BEARER, URL_TOKEN].freeze

  # a code chosen to forge a second, complete-looking line in a Rails log
  FORGED_CODE = "OK\nI, [2026-01-01T00:00:00]  INFO -- graph_weaver: GraphWeaver AdminQuery (1.0ms) ok"

  QUERY = "mutation Login($password: String) { login(password: $password) }"
end

describe "the redaction boundary, channel by channel" do
  include_context "raw http server"

  let(:io) { StringIO.new }

  around do |example|
    # debug, so a row that passes here passes at every level
    GraphWeaver.logger = Logger.new(io, level: Logger::DEBUG)
    example.run
  ensure
    GraphWeaver.logger = nil
    GraphWeaver.instrumenter = nil
  end

  # The senior's page: a framework error page that echoes the request back —
  # what Rails' own dev page does, and many proxies. It is the shape that made
  # F1 a leak rather than a theory.
  def echoing(status, extra = {})
    serving do |socket|
      head, body = raw_requests.last
      page = "<h1>#{status}</h1><pre>#{body}\n#{head[/^Authorization:.*/i]}</pre>"
      socket.write(http_response(status, page, { "Content-Type" => "text/html" }.merge(extra)))
    end
  end

  # one exchange, driven the way an app drives it: a credential in the url, a
  # bearer token on the header, a password in the variables
  def drive(url)
    client = GraphWeaver::Transport::HTTP.new("#{url}?access_token=#{Redaction::URL_TOKEN}",
      headers: { "Authorization" => "Bearer #{Redaction::BEARER}" })
    client.execute(Redaction::QUERY, variables: { "password" => Redaction::PASSWORD })
  end

  def raised(url)
    drive(url)
    raise "expected the exchange to fail"
  rescue GraphWeaver::Error => e
    e
  end

  # Each row names a channel and states its policy; the block returns
  # everything that channel said.
  def self.channel(what, policy, &said)
    describe(what) do
      it(policy) do
        spoken = Array(instance_exec(&said)).join("\n")
        Redaction::OURS.each { |secret| expect(spoken).not_to include secret }
      end
    end
  end

  channel "an exception message",
    "says status, what we judged wrong, the hint and the safe url — never the body" do
    error = raised(echoing(500))
    expect(error.message).to eq "HTTP 500 — POST #{error.url}"
    [error.message, error.to_s]
  end

  channel "the machine side of an error (#to_h)",
    "status, retry_after and the safe url; the body and the headers stay off it" do
    error = raised(echoing(500))
    expect(error.to_h.keys).to contain_exactly("error", "message", "status", "url")
    error.to_h.inspect
  end

  channel "ServerError#body",
    "holds the bytes verbatim, which is why nothing else has to quote them" do
    error = raised(echoing(500))
    expect(error.body).to include Redaction::PASSWORD # the channel that DOES carry it
    []
  end

  channel "the log, at every level",
    "narrates status, size and content type; a body is never quoted into it" do
    raised(echoing(500))
    expect(io.string).to include("bytes, text/html")
    io.string
  end

  channel "the warn line every raised error writes",
    "is the message, which is why the message carries no body" do
    error = raised(echoing(500))
    expect(io.string).to include("GraphWeaver::ServerError: #{error.message}")
    io.string
  end

  channel "a redirect's destination",
    "a url the server chose, said the way we say our own" do
    location = "http://svc:#{Redaction::PASSWORD}@elsewhere.example.com/graphql" \
      "?access_token=#{Redaction::URL_TOKEN}"
    error = raised(echoing(302, "Location" => location))
    expect(error.message).to include "point the client at http://[FILTERED]@elsewhere.example.com"
    [error.message, io.string]
  end

  channel "a transport failure",
    "the adapter's own sentence, capped, plus the safe url" do
    error = raised("http://127.0.0.1:1/graphql")
    expect(error).to be_a GraphWeaver::TransportError
    [error.message, error.to_h.inspect, io.string]
  end

  channel "a 200 that isn't GraphQL",
    "names the misbehaviour; the page it named stays on #body" do
    error = raised(echoing(200))
    expect(error.message).to include "non-GraphQL response"
    [error.message, error.to_h.inspect, io.string]
  end

  channel "an InputError the library raised",
    "[FILTERED] in the message, in #value and in #to_h, at every depth" do
    module_ = GraphWeaver.parse(schema: Demo::Schema,
      query: "query Login($password: Int) { search(term: \"x\", first: $password) { __typename } }")
    error = begin
      module_.execute(password: Redaction::PASSWORD)
    rescue GraphWeaver::InputError => e
      e
    end
    expect(error.value).to eq GraphWeaver::FILTERED
    [error.message, error.to_h.inspect, io.string]
  end

  channel "the APM payload",
    "never the query or the variables; :url scrubbed, :code stripped of framing" do
    events = []
    GraphWeaver.instrumenter = ->(_event, payload, &block) { block.call.tap { events << payload } }
    drive(echoing(200, "Content-Type" => "application/json")) rescue nil
    events.map(&:inspect)
  end

  channel "inspect on every public object",
    "the class and the safe url, never a header, a context or a body" do
    url = "http://127.0.0.1:1/graphql?access_token=#{Redaction::URL_TOKEN}"
    transport = GraphWeaver::Transport::HTTP.new(url, headers: { "Authorization" => Redaction::BEARER })
    [
      transport.inspect, transport.to_s,
      GraphWeaver::Retry.new(transport).inspect,
      GraphWeaver::InProcess.new(Demo::Schema, context: { token: Redaction::BEARER }).inspect,
      GraphWeaver::Testing::Endpoint.new(GraphWeaver::InProcess.new(Demo::Schema)).inspect,
      GraphWeaver.new(url, auth: Redaction::BEARER).inspect,
    ]
  end

  channel "the one line a Rails log writes at info",
    "one line per operation — a server's code can't forge a second" do
    require "graph_weaver/log_subscriber"
    payload = { operation: "Login" }
    GraphWeaver.instrumenter = ->(_event, p, &block) { block.call.tap { payload = p } }
    GraphWeaver::Internal::Log.instrument_request(payload) do
      { "errors" => [{ "message" => "no", "extensions" => { "code" => Redaction::FORGED_CODE } }] }
    end
    line = StringIO.new
    GraphWeaver.logger = Logger.new(line, level: Logger::INFO)
    GraphWeaver::LogSubscriber.new.execute(Struct.new(:payload, :duration).new(payload, 1.0))
    expect(line.string.lines.size).to eq 1
    line.string
  end

  # The two channels that DO carry foreign text, on purpose. Each is
  # documented rather than scrubbed, and pinning them here is what keeps
  # "passed through untouched" from quietly becoming "scrubbed, mostly".
  describe "the channels that carry it deliberately" do
    it "passes a server's own sentence through untouched, in errors and in QueryError" do
      url = serving do |socket|
        body = JSON.generate("errors" => [{ "message" => "rejected #{Redaction::PASSWORD}" }])
        socket.write(http_response(200, body))
      end

      module_ = GraphWeaver.parse(schema: Demo::Schema,
        query: "query Q { search(term: \"x\", first: 1) { __typename } }")
      client = GraphWeaver::Transport::HTTP.new("#{url}?access_token=#{Redaction::URL_TOKEN}")

      error = begin
        module_.execute!(client:)
      rescue GraphWeaver::QueryError => e
        e
      end

      expect(error.message).to include Redaction::PASSWORD
      # what the library ADDS to it is still ours, and still scrubbed
      expect(error.message).not_to include Redaction::URL_TOKEN
    end

    it "hands a Testing::Endpoint 400 the sender's own bytes back, and logs none of it" do
      app = GraphWeaver::Testing::Endpoint.new(GraphWeaver::InProcess.new(Demo::Schema))

      status, _headers, body = app.call(
        "REQUEST_METHOD" => "POST",
        "rack.input" => StringIO.new("not json #{Redaction::PASSWORD}"),
      )

      expect(status).to eq 400
      expect(body.join).to include Redaction::PASSWORD # back to whoever sent it
      expect(io.string).not_to include Redaction::PASSWORD
    end
  end
end
