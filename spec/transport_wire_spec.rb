require "bigdecimal"
require "pathname"
require "stringio"
require "zlib"

# What a transport does with the bytes a real network actually delivers — a
# proxy's login page, a compressed body, a socket the server reaped between
# requests. Driven against a server that writes exact bytes rather than a stub,
# because every one of these is a question about the wire.
describe "a transport reading the wire" do
  include_context "raw http server"

  let(:good_body) { '{"data":{"x":1}}' }
  let(:query) { "query Q { x }" }
  let(:answer) { { "data" => { "x" => 1 } } }

  # a difference between the two bundled transports is one a user discovers in
  # production, so every case here asks both
  def transports = [GraphWeaver::Transport::HTTP, GraphWeaver::Transport::Faraday]

  def answering(bytes) = serving { |socket| socket.write(bytes) }

  describe "bodies" do
    # RFC 8259 §8.1 lets a parser ignore a leading BOM and Ruby's doesn't.
    # .NET/IIS-fronted endpoints emit one, and it fails invisibly: the body an
    # error quotes back looks like perfectly good GraphQL.
    it "reads JSON behind a UTF-8 BOM" do
      url = answering(http_response(200, "\xEF\xBB\xBF#{good_body}"))
      transports.each { |transport| expect(transport.new(url).execute(query)).to eq answer }
    end

    it "says an empty body is empty rather than trailing off after the colon" do
      url = answering("HTTP/1.1 204 No Content\r\n\r\n")
      transports.each do |transport|
        expect { transport.new(url).execute(query) }
          .to raise_error(GraphWeaver::ServerError, "HTTP 204 — empty response body — POST #{url}")
      end
    end

    it "reports a captive portal's HTML as the misbehaviour it is" do
      url = answering(http_response(200, "<html>sign in</html>", "Content-Type" => "text/html"))
      transports.each do |transport|
        expect { transport.new(url).execute(query) }
          .to raise_error(GraphWeaver::ServerError, /non-GraphQL response/) { |e|
            expect(e.body).to eq "<html>sign in</html>"
          }
      end
    end

    # a bare array, string or null is valid JSON and not a GraphQL response
    it "refuses JSON that isn't an object" do
      ["[1,2]", '"hello"', "null", '{"data":'].each do |body|
        url = answering(http_response(200, body))
        expect { GraphWeaver::Transport::HTTP.new(url).execute(query) }
          .to raise_error(GraphWeaver::ServerError, /non-GraphQL response/)
      end
    end

    # A router streams @defer/@stream as multipart/mixed when the Accept asks
    # for it. Refusing is right — this client reads one JSON document — but
    # "non-GraphQL response" plus the whole payload misdiagnoses a body that is
    # perfectly well-formed GraphQL, just more than one of it.
    it "names an incremental-delivery body rather than quoting it back" do
      payload = "\r\n--graphql\r\ncontent-type: application/json\r\n\r\n" \
        '{"data":{"x":1},"hasNext":true}' "\r\n--graphql--\r\n"
      url = answering(http_response(200, payload, "Content-Type" => "multipart/mixed; boundary=graphql"))

      transports.each do |transport|
        expect { transport.new(url).execute(query) }.to raise_error(
          GraphWeaver::ServerError,
          "HTTP 200 — this response is incremental delivery (@defer/@stream), " \
            "which this client doesn't read — POST #{url}",
        )
      end
    end

    it "decodes a chunked body" do
      url = serving do |socket|
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n")
        socket.write("#{good_body.bytesize.to_s(16)}\r\n#{good_body}\r\n0\r\n\r\n")
      end
      transports.each { |transport| expect(transport.new(url).execute(query)).to eq answer }
    end

    # net/http asks for compression on its own and gunzips the answer — a
    # transport that set its own Accept-Encoding would silently turn that off
    it "asks for compression and decodes what comes back" do
      gzipped = StringIO.new
      Zlib::GzipWriter.new(gzipped).tap { |io| io.write(good_body); io.close }
      url = serving { |socket| socket.write(http_response(200, gzipped.string, "Content-Encoding" => "gzip")) }

      transports.each do |transport|
        expect(transport.new(url).execute(query)).to eq answer
        expect(raw_requests.last.first).to match(/^accept-encoding:.*gzip/i)
      end
    end

    it "decodes a deflated body" do
      url = answering(http_response(200, Zlib::Deflate.deflate(good_body), "Content-Encoding" => "deflate"))
      transports.each { |transport| expect(transport.new(url).execute(query)).to eq answer }
    end

    it "reads a body far past one socket read" do
      url = answering(http_response(200, JSON.generate({ "data" => { "x" => "a" * 5_000_000 } })))
      expect(GraphWeaver::Transport::HTTP.new(url).execute(query)["data"]["x"].bytesize).to eq 5_000_000
    end
  end

  # THE case a pooled transport must not get wrong. net/http notices the peer's
  # FIN before it writes and reconnects; when the close races the write instead
  # it raises, because POST is not idempotent and it will not repeat one.
  # Either way the server applies the charge exactly once — a guarantee that
  # lives in net/http's internals, so it is worth pinning here.
  it "never replays a mutation on a keep-alive socket the server closed" do
    url = serving { |socket| socket.write(http_response(200, good_body)) }
    transport = GraphWeaver::Transport::HTTP.new(url)
    transport.execute(query)
    sleep 0.3 # the FIN lands while the socket sits in the pool

    begin
      transport.execute("mutation Charge { charge }")
    rescue GraphWeaver::TransportError
      nil # the racing close — a failure, which is the correct answer
    end

    expect(raw_requests.count { |_head, body| body.include?("mutation Charge") }).to eq 1
  end

  describe "statuses" do
    it "does not follow a redirect, and says where it would have gone" do
      url = answering(http_response(302, "", "Location" => "https://elsewhere.example/graphql"))
      transports.each do |transport|
        expect { transport.new(url).execute(query) }
          .to raise_error(GraphWeaver::ServerError, %r{redirects are not followed — point the client at https://elsewhere\.example/graphql})
      end
    end

    it "carries Retry-After off a real 429, as seconds or as an HTTP-date" do
      { "7" => 7.0, (Time.now + 30).httpdate => 30.0 }.each do |header, expected|
        url = answering(http_response(429, "slow down", "Retry-After" => header))
        error = nil
        begin
          GraphWeaver::Transport::HTTP.new(url).execute(query)
        rescue GraphWeaver::ServerError => e
          error = e
        end

        expect(error).to be_throttled
        expect(error.retry_after).to be_within(2).of(expected)
      end
    end
  end

  # JSON.generate renders anything it doesn't know as the value's #to_s — right
  # for a Date, a memory address for a File. An Upload! variable given a real
  # file went out as {"file":"#<File:0x…>"} with a 200 back and no error
  # anywhere, which is wire corruption the server stores as if it meant
  # something.
  describe "variables with no JSON form" do
    let(:url) { answering(http_response(200, good_body)) }

    def sending(variables, transport = GraphWeaver::Transport::HTTP)
      transport.new(url).execute(query, variables:)
    end

    it "refuses a file, and says why a file can't ride in a JSON body" do
      transports.each do |transport|
        expect { sending({ "file" => File.open(__FILE__) }, transport) }
          .to raise_error(GraphWeaver::Error, /\$file is a File — .*multipart request spec.*own transport/m)
      end
      expect(raw_requests).to be_empty # refused before anything was sent
    end

    it "refuses a stream whose #to_s reads fine, like a Pathname" do
      expect { sending({ "avatar" => Pathname.new("/tmp/avatar.png") }) }
        .to raise_error(GraphWeaver::Error, /\$avatar is a Pathname/)
    end

    # an object that never said what it is — the memory address is the point
    it "refuses an object JSON would render as its debug form" do
      expect { sending({ "who" => Object.new }) }
        .to raise_error(GraphWeaver::Error, /\$who is a Object, which has no JSON form.*#<Object:0x/m)
    end

    it "names where in a variable the value sits" do
      expect { sending({ "input" => { "avatar" => StringIO.new("x") } }) }
        .to raise_error(GraphWeaver::Error, /\$input\.avatar is a StringIO/)
      expect { sending({ "files" => [nil, File.open(__FILE__)] }) }
        .to raise_error(GraphWeaver::Error, /\$files\[1\] is a File/)
    end

    # the refusal has to stay narrow: these all have an honest string form,
    # and a registered scalar's serialized value is JSON-native by then
    it "leaves a value that renders honestly alone" do
      variables = {
        "day" => Date.new(2024, 1, 1), "at" => Time.at(0).utc, "amount" => BigDecimal("1.5"),
        "mode" => :live, "nested" => { "list" => [Date.new(2024, 1, 1), 1, "s", true, nil] },
      }

      transports.each { |transport| expect(sending(variables, transport)).to eq answer }
      expect(raw_requests.last.last).to include %("day":"2024-01-01"), %("mode":"live")
    end
  end

  # A gateway attributes traffic to whatever the apollographql-client-* headers
  # say, and Apollo's "client" is the consuming application — so a Rails app
  # answers with its own name rather than with the gem's.
  describe "client identity" do
    def names_itself(transport)
      url = answering(http_response(200, good_body))
      transport.new(url).execute(query)
      raw_requests.last.first[/^apollographql-client-name: (.*)\r$/i, 1]
    end

    it "sends the gem's name outside Rails" do
      transports.each { |transport| expect(names_itself(transport)).to eq "graph_weaver" }
    end

    it "sends the app's name inside Rails" do
      application = stub_const("Storefront::Application", Class.new).new
      stub_const("Rails", Module.new { define_singleton_method(:application) { application } })

      transports.each { |transport| expect(names_itself(transport)).to eq "Storefront" }
    end
  end

  describe "proxies" do
    # URI#find_proxy never proxies a loopback address, so the origin has to be
    # a name that isn't 127.0.0.1 — and one that never resolves, so a request
    # reaching the proxy at all is proof the proxy was used.
    let(:origin) { "http://origin.invalid/graphql" }

    around do |example|
      previous = ENV.values_at("http_proxy", "HTTP_PROXY", "no_proxy")
      example.run
    ensure
      ENV["http_proxy"], ENV["HTTP_PROXY"], ENV["no_proxy"] = previous
    end

    it "honours http_proxy, on both transports" do
      proxy = serving { |socket| socket.write(http_response(200, good_body)) }
      ENV["http_proxy"] = proxy.delete_suffix("/graphql")

      transports.each do |transport|
        expect(transport.new(origin).execute(query)).to eq answer
        expect(raw_requests.last.first).to start_with "POST #{origin} HTTP/1.1"
      end
    end

    it "stops proxying when no_proxy names the host" do
      proxy = serving { |socket| socket.write(http_response(200, good_body)) }
      ENV["http_proxy"] = proxy.delete_suffix("/graphql")
      ENV["no_proxy"] = "origin.invalid"

      expect { GraphWeaver::Transport::HTTP.new(origin).execute(query) }
        .to raise_error(GraphWeaver::TransportError)
      expect(raw_requests).to be_empty
    end
  end
end
