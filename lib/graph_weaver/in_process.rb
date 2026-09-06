# typed: true
# frozen_string_literal: true

require "json"

require_relative "errors"
require_relative "transport"

# Runs queries against a live graphql-ruby schema in the same process —
# no socket, no serialization:
#
#      GraphWeaver.new(MySchema, context: { current_user: user })
#      GraphWeaver::InProcess.new(MySchema, context: { current_user: user })
#
# A schema class already satisfies the client contract on its own (and
# still does — it stays usable bare). The wrapper adds the three things
# it can't do for itself:
#
#   - **context:** — `Schema.execute` takes one, but nothing supplied it,
#     so a resolver reading `context[:current_user]` got nil and it
#     surfaced as "Cannot return null for non-nullable field Query.me".
#     For server-side composition, context *is* the request.
#   - **logging** — all of it lived in Transport#execute, which an
#     in-process schema bypasses entirely.
#   - **branded errors** — a resolver raise was a bare RuntimeError,
#     where the same failure over HTTP is a ServerError, so
#     `rescue GraphWeaver::Error` caught one and missed the other.
#
# The original exception stays as #cause: in-process, the real backtrace
# is usually the whole reason you're running in-process.
class GraphWeaver::InProcess
  # the schema queries run against, and the context handed to every one
  attr_reader :schema, :context

  def initialize(schema, context: {})
    unless schema.respond_to?(:execute)
      raise ArgumentError, "expected a graphql-ruby schema class, got #{schema.inspect}"
    end

    @schema = schema
    @context = context
  end

  def execute(query, variables: {}, operation_name: nil)
    operation_name ||= GraphWeaver::Transport.operation_name(query)
    payload = { url: nil, schema: @schema.to_s, operation: operation_name }

    GraphWeaver.instrument(GraphWeaver::EXECUTE_EVENT, payload) do
      perform(query, variables, operation_name, payload)
    end
  end

  # The query itself. Separate from execute so the instrumenter wraps a
  # call rather than a block this method returns out of.
  private def perform(query, variables, operation_name, payload)
    # same tag/truncation as the network transports, so one log reads the
    # same whichever side of the seam a query ran on
    tag = GraphWeaver.logger && GraphWeaver::Transport.log_tag(operation_name)

    GraphWeaver.log(:debug) do
      "in-process #{@schema} #{tag} variables=#{JSON.generate(variables)}\n" \
        "#{GraphWeaver::Transport.truncate_for_log(query)}"
    end

    result = GraphWeaver.log_timed(:debug, "in-process #{@schema} #{tag} completed") do
      @schema.execute(query, variables:, operation_name:, context: @context)
    end

    # the same key the network transports set, so one instrumenter
    # subscriber reads both sides of the seam without branching — a
    # resolver raise rides the ServerError(500) the hook already sees
    payload[:status] = 200
    result
  rescue GraphWeaver::Error
    raise
  rescue => e
    # a resolver blew up. The same failure over HTTP arrives as a 500, so
    # raise what HTTP would — code that rescues GraphWeaver::Error, or
    # branches on ServerError#status, behaves the same either side.
    raise GraphWeaver::ServerError.new(status: 500, body: "#{e.class}: #{e.message}")
  end

  # never leak the context (session tokens, current_user) through logs or
  # exceptions — an in-process client inspects as its schema, nothing more
  def inspect = "#<#{self.class.name} schema=#{@schema}>"
  alias to_s inspect
end
