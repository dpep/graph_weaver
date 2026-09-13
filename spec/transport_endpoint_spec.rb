require "socket"

# A transport failure that doesn't say WHERE starts every investigation with
# "which endpoint" — and an app with two graphs has more than one answer. The
# url it names has to be safe to say, too: it reaches the log, the exception,
# and the APM payload, all of which outlive the request.
describe "the endpoint a transport names" do
  include_context "raw http server"

  describe GraphWeaver::Internal::Endpoint do
    after { GraphWeaver.filter_parameters = GraphWeaver::DEFAULT_FILTER_PARAMETERS }

    it "says a plain url back exactly as it was configured" do
      expect(described_class.safe("https://api.example.com/graphql")).to eq "https://api.example.com/graphql"
      expect(described_class.safe("http://127.0.0.1:4000/graphql")).to eq "http://127.0.0.1:4000/graphql"
    end

    it "keeps a query string that carries nothing secret" do
      expect(described_class.safe("https://api.example.com/graphql?tenant=acme&page=2"))
        .to eq "https://api.example.com/graphql?tenant=acme&page=2"
    end

    it "folds away userinfo" do
      expect(described_class.safe("https://svc:hunter2@api.example.com/graphql"))
        .to eq "https://[FILTERED]@api.example.com/graphql"
    end

    # the same list that scrubs the variables line, so a log reads the same
    # either side of the seam
    it "scrubs a query parameter filter_parameters already filters" do
      expect(described_class.safe("https://api.example.com/graphql?access_token=abc&page=2"))
        .to eq "https://api.example.com/graphql?access_token=[FILTERED]&page=2"
    end

    # filter_parameters is a knob about how much the log says; a url credential
    # is a credential either way, the way the userinfo above already is
    it "scrubs a query credential even when filter_parameters is empty" do
      GraphWeaver.filter_parameters = []
      expect(described_class.safe("https://api.example.com/graphql?access_token=abc&page=2"))
        .to eq "https://api.example.com/graphql?access_token=[FILTERED]&page=2"
      expect(described_class.bare("https://api.example.com/graphql?access_token=abc&page=2"))
        .to eq "https://api.example.com/graphql?page=2"
    end

    it "still takes the app's list as a widening of the default one" do
      GraphWeaver.filter_parameters = [/\Akey\z/]
      expect(described_class.safe("https://api.example.com/graphql?key=abc&api_token=xyz"))
        .to eq "https://api.example.com/graphql?key=[FILTERED]&api_token=[FILTERED]"
    end

    it "answers a url it can't take apart with nothing at all" do
      expect(described_class.safe("not a url")).to eq "[FILTERED]"
    end

    # for a url that is read back later — a marker there would parse as a host
    it "strips credentials rather than marking them when the url must stay usable" do
      expect(described_class.bare("https://svc:hunter2@api.example.com/graphql?access_token=abc&page=2"))
        .to eq "https://api.example.com/graphql?page=2"
      expect(described_class.bare("https://api.example.com/graphql?access_token=abc"))
        .to eq "https://api.example.com/graphql"
      expect(described_class.bare("https://api.example.com/graphql")).to eq "https://api.example.com/graphql"
    end
  end

  describe "on the error" do
    it "names the endpoint a ServerError came from" do
      url = serving { |s| s.write(http_response(500, "<html>oops</html>")) }
      error = nil
      begin
        GraphWeaver::Transport::HTTP.new(url).execute("query Q { x }")
      rescue GraphWeaver::ServerError => e
        error = e
      end

      expect(error.message).to eq "HTTP 500 — POST #{url}"
      expect(error.body).to eq "<html>oops</html>"
      expect(error.url).to eq url
      expect(error.to_h["url"]).to eq url
    end

    it "names the endpoint a TransportError never reached" do
      error = nil
      begin
        GraphWeaver::Transport::HTTP.new("http://127.0.0.1:1/graphql").execute("query Q { x }")
      rescue GraphWeaver::TransportError => e
        error = e
      end

      expect(error.message).to end_with " — POST http://127.0.0.1:1/graphql"
      expect(error.url).to eq "http://127.0.0.1:1/graphql"
      expect(error.to_h["url"]).to eq "http://127.0.0.1:1/graphql"
    end

    # the message reaches GraphWeaver.logger at warn on its way out
    it "names a credential-carrying endpoint without the credential" do
      url = serving { |s| s.write(http_response(500, "nope")) }
      secret = url.sub("http://", "http://svc:hunter2@") + "?access_token=abc"
      error = nil
      begin
        GraphWeaver::Transport::HTTP.new(secret).execute("query Q { x }")
      rescue GraphWeaver::ServerError => e
        error = e
      end

      expect(error.url).to eq url.sub("http://", "http://[FILTERED]@") + "?access_token=[FILTERED]"
      expect(error.message).not_to include "hunter2"
      expect(error.message).not_to include "access_token=abc"
    end
  end

  describe "everywhere else a transport says its url" do
    let(:secret) { "https://svc:hunter2@api.example.com/graphql?access_token=abc" }
    let(:safe) { "https://[FILTERED]@api.example.com/graphql?access_token=[FILTERED]" }

    it "inspects as the safe url" do
      expect(GraphWeaver::Transport::HTTP.new(secret).inspect).to eq %(#<GraphWeaver::Transport::HTTP url="#{safe}">)
    end

    it "keeps #url as the endpoint requests actually go to" do
      expect(GraphWeaver::Transport::HTTP.new(secret).url).to eq secret
    end

    it "hands the APM the safe url, not the credential" do
      url = serving { |s| s.write(http_response(200, '{"data":{"x":1}}')) }
      secret_url = url.sub("http://", "http://svc:hunter2@")
      payload = nil
      begin
        GraphWeaver.instrumenter = ->(_event, data, &block) { payload = data; block.call }
        GraphWeaver::Transport::HTTP.new(secret_url).execute("query Q { x }")
      ensure
        GraphWeaver.instrumenter = nil
      end

      expect(payload[:url]).to eq url.sub("http://", "http://[FILTERED]@")
    end

    it "logs the boot line and the request line without the credential" do
      url = serving { |s| s.write(http_response(200, '{"data":{"x":1}}')) }
      secret_url = url.sub("http://", "http://svc:hunter2@")
      io = StringIO.new
      begin
        GraphWeaver.logger = Logger.new(io, level: Logger::DEBUG)
        GraphWeaver.new(secret_url).execute("query Q { x }")
      ensure
        GraphWeaver.logger = nil
      end

      expect(io.string).to include "[FILTERED]@"
      expect(io.string).not_to include "hunter2"
    end
  end
end
