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
    #
    # A client whose `context` is a **proc** is asked what this request's
    # headers mean, per request: that is the identity-propagation seam, the
    # one thing an in-process client can't test.
    #
    #      Router.new(supergraph:, context: ->(headers) { { current_user: User.find_by(token: headers["Authorization"]) } })
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

        result = with_context(headers(env)) do
          @client.execute(request["query"], variables: request["variables"] || {},
            operation_name: request["operationName"])
        end
        [200, JSON_HEADERS, [JSON.generate(result)]]
      end

      # never leak the client's context (tokens, current_user)
      def inspect = "#<#{self.class.name} client=#{@client.class}>"
      alias to_s inspect

      private

      # A `context:` proc is answered from the request in hand, so it is
      # resolved here and put back after — one request's identity must not
      # leak into the next. A client with no context, or a hash one, is
      # served untouched.
      def with_context(headers)
        context = @client.context if @client.respond_to?(:context) && @client.respond_to?(:context=)
        return yield unless context.respond_to?(:call)

        @client.context = context.call(headers)
        begin
          yield
        ensure
          @client.context = context
        end
      end

      # Rack spells a header HTTP_X_CALLER; the proc reads "X-Caller".
      # Capitalization is reconstructed, not remembered — the CGI env
      # dropped it — so a header sent as X-CALLER arrives here as X-Caller.
      def headers(env)
        env.each_with_object({}) do |(key, value), headers|
          name = case key
          when /\AHTTP_(.+)\z/ then Regexp.last_match(1)
          when "CONTENT_TYPE", "CONTENT_LENGTH" then key
          end
          next unless name && value.is_a?(String)

          headers[name.downcase.split("_").map(&:capitalize).join("-")] = value
        end
      end

      def excerpt(body) = body.empty? ? "an empty body" : body[0, EXCERPT].inspect

      def refuse(message) = [400, TEXT_HEADERS, [message]]
    end
  end
end
