# typed: true
# frozen_string_literal: true

require "json"
require "net/http" # Net::ReadTimeout, the shape a real read timeout arrives in

module GraphWeaver
  module Testing
    # Canned failure clients — each produces exactly what the real
    # transports produce, so error-handling paths are testable without a
    # server that misbehaves on cue:
    #
    #      PersonQuery.execute(client: Failure.transport, id: "1")   # TransportError
    #      PersonQuery.execute(client: Failure.timeout, id: "1")      # TransportError, read timeout
    #      PersonQuery.execute(client: Failure.server(status: 502), id: "1")
    #      PersonQuery.execute(client: Failure.throttled, id: "1")    # QueryError, code THROTTLED
    #      PersonQuery.execute(client: Failure.stale_schema, id: "1") # schema_stale? => true
    #
    # For type mismatches, corrupt the wire with a FakeClient override:
    #      FakeClient.new(schema:, overrides: { "Person.birthday" => 123 })
    # casting then raises GraphWeaver::CastError, exactly as a bad server
    # payload would. For partial failures, see FakeClient's fail_at:.
    module Failure
      include Kernel # for sorbet
      module_function

      # the request never reaches the server — cause preserved, and the
      # message shaped as the bundled transports shape it
      def transport(message = "simulated network failure", cause: SocketError)
        network_failure(cause, message)
      end

      # The request went out and no answer came back in time — net/http's own
      # Net::ReadTimeout as #cause, so a spec says "it timed out" without
      # naming net/http's classes. Retriable, but a read timeout says nothing
      # about whether the server applied the request, which is why Retry gives
      # a mutation one attempt.
      def timeout(message = "simulated read timeout")
        network_failure(Net::ReadTimeout, message)
      end

      # What Transport does with a network-level failure: a TransportError
      # reading "Class: detail", the original preserved as #cause. The detail
      # is passed rather than read off the exception — Net::ReadTimeout's own
      # initialize takes the socket it gave up on, not a message, so a string
      # handed to `raise` lands in quotes where the socket goes.
      def network_failure(cause, message)
        FailureClient.new do
          raise cause
        rescue cause => e
          raise GraphWeaver::TransportError, "#{e.class}: #{message}"
        end
      end
      private_class_method :network_failure

      # The server answered non-2xx. headers: is where the answer to "wait,
      # then" lives — ServerError#retry_after and #throttled? read it, so a
      # backoff is only exercised by a failure that carries one:
      #
      #      Failure.server(status: 429, headers: { "retry-after" => "2" })
      def server(status: 500, body: "simulated server error", headers: {})
        FailureClient.new { raise GraphWeaver::ServerError.new(status:, body:, headers:) }
      end

      # The wire fields an error carries, beyond its message. `code:` is the
      # sugar fail_at: already uses — extensions.code, the one every server
      # states. Anything else is refused by name: a swallowed keyword leaves a
      # simulated failure that doesn't simulate what the example asked for.
      ERROR_FIELDS = %i[code extensions path locations].freeze
      private_constant :ERROR_FIELDS

      # Top-level GraphQL errors — a **whole-response** failure unless data:
      # rides along. Each positional is a String (just the message) or a Hash
      # in the wire error shape; the fields of ONE error may be named beside
      # its message instead:
      #
      #      Failure.graphql("boom")
      #      Failure.graphql("boom", code: "BAD_USER_INPUT", path: ["adopt"])
      #      Failure.graphql("min must be at least 1", code: "BAD_USER_INPUT",
      #        extensions: { "input" => { "kind" => "out_of_range", "min" => 1 } })
      #      Failure.graphql({ message: "a", path: ["x"] }, { message: "b" }, data: { "x" => nil })
      def graphql(*errors, data: nil, **fields)
        unknown = fields.keys - ERROR_FIELDS
        unless unknown.empty?
          raise ArgumentError, "Failure.graphql: unknown keyword(s) #{unknown.join(", ")} — " \
            "expected data:, or #{ERROR_FIELDS.join(", ")} to shape the error"
        end

        errors = errors.flatten
        unless fields.empty? || errors.one?
          raise ArgumentError, "Failure.graphql: #{fields.keys.join(", ")} shapes one error, " \
            "got #{errors.size} — give each its own hash"
        end

        response = { "errors" => errors.map { |error| wire_error(error, fields) } }
        response["data"] = data if data
        FailureClient.new { response }
      end

      # a String is its message; a Hash is the wire error as written. The
      # kwargs merge on top, so `code:` and `extensions:` compose.
      def wire_error(error, fields)
        wire = error.is_a?(String) ? { "message" => error } : JSON.parse(JSON.generate(error))
        return wire if fields.empty?

        extensions = JSON.parse(JSON.generate(fields[:extensions] || {}))
        extensions["code"] = fields[:code].to_s if fields[:code]
        wire.merge!(JSON.parse(JSON.generate(fields.slice(:path, :locations))))
        wire["extensions"] = (wire["extensions"] || {}).merge(extensions) unless extensions.empty?
        wire
      end
      private_class_method :wire_error

      def throttled
        # a code from the list #throttled? recognizes, not one spelled here —
        # a fake that doesn't trip the predicate it exists to exercise is worse
        # than no fake
        graphql("rate limited", code: GraphWeaver::GraphQLError::THROTTLE_CODES.first)
      end

      # A validation-shaped rejection — trips schema_stale? and its
      # regenerate hint, as if the schema changed under the module. Name the
      # casualty when the message matters:
      #
      #      Failure.stale_schema(type: "Person", field: "name")
      def stale_schema(field: nil, type: nil)
        graphql("Field '#{field || "someField"}' doesn't exist on type '#{type || "SomeType"}'")
      end
    end

    # runs the block per request — raise or return an envelope
    class FailureClient
      def initialize(&response)
        @response = response
      end

      def execute(_query, variables: {}, operation_name: nil)
        @response.call
      end
    end

    # Delegates each call to the next client in line (the last one
    # repeats) — fail N times, then succeed, for retry/backoff testing:
    #
    #      Sequence.new(Failure.transport, Failure.transport, fake)
    class Sequence
      def initialize(*clients)
        @clients = clients.flatten
        @calls = 0
      end

      def execute(query, variables: {}, operation_name: nil)
        client = @clients[[@calls, @clients.size - 1].min]
        @calls += 1
        client.execute(query, variables:, operation_name:)
      end
    end
  end
end
