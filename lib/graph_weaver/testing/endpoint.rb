# typed: true
# frozen_string_literal: true

require "json"

module GraphWeaver
  module Testing
    # A Rack app serving any client — the {Router}, a live schema class, a
    # {FakeClient} — at a GraphQL endpoint, so a query crosses a real wire:
    # serialized by your transport, posted, deserialized by `from_h`.
    #
    #      run GraphWeaver::Testing::Endpoint.new(router)
    #
    # In rspec that is the `graphql: :wire` tag, which mounts this behind
    # your own transport's url (see graph_weaver/rspec). Anywhere else it is
    # an ordinary Rack app — a rackup file, a Puma in a thread, WebMock's
    # `to_rack`.
    #
    # It answers the way a router and graphql-ruby answer: a query the
    # server can't parse or validate is a **200 carrying GraphQL errors**,
    # not an HTTP failure. Only a request that isn't a GraphQL request at
    # all — the wrong method, a body that isn't JSON — is a 400, and it says
    # what it got.
    class Endpoint
      JSON_HEADERS = { "content-type" => "application/json" }.freeze
      TEXT_HEADERS = { "content-type" => "text/plain" }.freeze
      private_constant :JSON_HEADERS, :TEXT_HEADERS

      # how much of an unservable body the 400 quotes back
      EXCERPT = 200
      private_constant :EXCERPT

      def initialize(client)
        @client = client
      end

      def call(env)
        method = env["REQUEST_METHOD"]
        return refuse("expected a POST of a GraphQL request, got #{method}") unless method == "POST"

        body = env["rack.input"]&.read.to_s
        request = begin
          JSON.parse(body)
        rescue JSON::ParserError => e
          return refuse("expected a JSON GraphQL request body, got #{excerpt(body)} (#{e.message})")
        end
        unless request.is_a?(Hash) && request["query"].is_a?(String)
          return refuse("expected a JSON GraphQL request body with a \"query\" string, got #{excerpt(body)}")
        end

        result = @client.execute(request["query"], variables: request["variables"] || {},
          operation_name: request["operationName"])
        [200, JSON_HEADERS, [JSON.generate(result)]]
      end

      # never leak the client's context (tokens, current_user)
      def inspect = "#<#{self.class.name} client=#{@client.class}>"
      alias to_s inspect

      private

      def excerpt(body) = body.empty? ? "an empty body" : body[0, EXCERPT].inspect

      def refuse(message) = [400, TEXT_HEADERS, [message]]
    end
  end
end
