require "socket"

# A server that writes exactly the bytes an example names — which is the only
# way to drive what a bad proxy, a captive portal or a half-dead keep-alive
# socket actually puts on the wire. WEBrick (see "graphql http server") speaks
# for a well-behaved GraphQL server; this one speaks for everything else.
#
#      url = serving { |socket| socket.write(http_response(500, "<html>")) }
#
# The handler runs per request; return truthy to keep the connection open for
# the next one on the same socket.
RSpec.shared_context "raw http server" do
  # Every request this server read, as [head, body] — so an example can assert
  # a mutation reached it exactly once.
  attr_reader :raw_requests

  before do
    @raw_requests = []
    @raw_servers = []
  end

  after do
    @raw_servers.each(&:close)
    @raw_servers.clear
  end

  def serving(path = "/graphql", &handler)
    server = TCPServer.new("127.0.0.1", 0)
    @raw_servers << server
    Thread.new { accept_loop(server, handler) }.abort_on_exception = false
    "http://127.0.0.1:#{server.addr[1]}#{path}"
  end

  # a complete HTTP/1.1 message — Content-Length computed, so the client isn't
  # left waiting for bytes the example didn't mean to promise
  def http_response(status, body, headers = {})
    fields = { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }.merge(headers)
    "HTTP/1.1 #{status} X\r\n#{fields.map { |name, value| "#{name}: #{value}\r\n" }.join}\r\n#{body}"
  end

  private

  def accept_loop(server, handler)
    loop do
      socket = server.accept
      Thread.new do
        while (request = read_request(socket))
          @raw_requests << request
          break unless handler.call(socket)
        end
      rescue StandardError, IOError
        nil
      ensure
        socket.close unless socket.closed?
      end
    end
  rescue StandardError, IOError
    nil # the server was closed between requests
  end

  def read_request(socket)
    head = +""
    while (line = socket.gets)
      head << line
      break if line == "\r\n"
    end
    return if head.empty?

    length = head[/content-length:\s*(\d+)/i, 1].to_i
    [head, length.positive? ? socket.read(length) : ""]
  end
end
