# typed: true
# frozen_string_literal: true

require "json"

module GraphWeaver
  module Testing
    # Canned failure executors — each produces exactly what the real
    # transports produce, so error-handling paths are testable without a
    # server that misbehaves on cue:
    #
    #      PersonQuery.execute(id: "1", executor: Failure.transport)   # TransportError
    #      PersonQuery.execute(id: "1", executor: Failure.server(status: 502))
    #      PersonQuery.execute(id: "1", executor: Failure.throttled)   # QueryError, code THROTTLED
    #      PersonQuery.execute(id: "1", executor: Failure.stale_schema) # schema_stale? => true
    #
    # For type mismatches, corrupt the wire with a FakeExecutor override:
    #      FakeExecutor.new(schema:, overrides: { "Person.birthday" => 123 })
    # casting then raises GraphWeaver::TypeError, exactly as a bad server
    # payload would. For partial failures, see FakeExecutor's fail_at:.
    module Failure
      include Kernel # for sorbet
      module_function

      # the request never reaches the server — cause preserved, like the
      # bundled transports do
      def transport(message = "simulated network failure", cause: SocketError)
        FailureExecutor.new do
          raise cause, message
        rescue cause => e
          raise GraphWeaver::TransportError, e.message
        end
      end

      # the server answered non-2xx
      def server(status: 500, body: "simulated server error")
        FailureExecutor.new { raise GraphWeaver::ServerError.new(status:, body:) }
      end

      # top-level GraphQL errors: strings, or hashes with message/path/
      # extensions; data: rides along for partial-failure envelopes
      def graphql(*errors, data: nil, extensions: {})
        normalized = errors.flatten.map do |error|
          error.is_a?(String) ? { "message" => error } : JSON.parse(JSON.generate(error))
        end

        response = { "errors" => normalized }
        response["data"] = data if data
        response["extensions"] = JSON.parse(JSON.generate(extensions)) unless extensions.empty?
        FailureExecutor.new { response }
      end

      def throttled
        # array-wrapped so the hash can't parse as kwargs
        graphql([{ message: "rate limited", extensions: { code: "THROTTLED" } }])
      end

      # A validation-shaped rejection — trips schema_stale? and its
      # regenerate hint, as if the schema changed under the module. Name
      # the casualty explicitly, or pass schema: to sample a real
      # type/field (as if the server just dropped it):
      #
      #      Failure.stale_schema(type: "Person", field: "name")
      #      Failure.stale_schema(schema: MySchema)             # random real field
      #      Failure.stale_schema(schema: MySchema, seed: 42)   # reproducibly random
      def stale_schema(field: nil, type: nil, schema: nil, seed: nil)
        if schema && (field.nil? || type.nil?)
          rng = Random.new(seed || GraphWeaver::Testing.config.seed || Random.new_seed)
          candidates = schema.types.values.select do |candidate|
            candidate.kind.name == "OBJECT" && !candidate.graphql_name.start_with?("__")
          end
          chosen = candidates.sort_by(&:graphql_name).sample(random: rng)
          type ||= chosen.graphql_name
          field ||= chosen.fields.keys.sort.sample(random: rng)
        end

        graphql("Field '#{field || "someField"}' doesn't exist on type '#{type || "SomeType"}'")
      end
    end

    # runs the block per request — raise or return an envelope
    class FailureExecutor
      def initialize(&response)
        @response = response
      end

      def execute(_query, variables: {})
        @response.call
      end
    end

    # Delegates each call to the next executor in line (the last one
    # repeats) — fail N times, then succeed, for retry/backoff testing:
    #
    #      SequenceExecutor.new(Failure.transport, Failure.transport, fake)
    class SequenceExecutor
      def initialize(*executors)
        @executors = executors.flatten
        @calls = 0
      end

      def execute(query, variables: {})
        executor = @executors[[@calls, @executors.size - 1].min]
        @calls += 1
        executor.execute(query, variables:)
      end
    end
  end
end
