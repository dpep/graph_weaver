# typed: true
# frozen_string_literal: true

require "json"

require_relative "errors"
require_relative "internal"
require_relative "context_seam"
require_relative "parsing"
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
  include GraphWeaver::Parsing
  # #context/#context= plus the lock over them: Testing::Endpoint answers a
  # `context:` proc from one request's headers by writing this field, so the
  # field's owner owns the lock
  include GraphWeaver::ContextSeam

  # the schema queries run against
  attr_reader :schema

  def initialize(schema, context: {})
    unless schema.respond_to?(:execute)
      raise ArgumentError, "expected a graphql-ruby schema class, got #{schema.inspect}"
    end

    @schema = schema
    init_context_seam(context)
  end

  def execute(query, variables: {}, operation_name: nil)
    operation_name ||= GraphWeaver::Internal::Wire.operation_name(query)
    payload = { url: nil, schema: schema_label, operation: operation_name, client: self.class,
                kind: GraphWeaver::Internal::Wire.kind(query) }

    GraphWeaver::Internal::Log.instrument_request(payload) do
      perform(query, variables, operation_name)
    end
  end

  # The query itself. Separate from execute so the instrumenter wraps a
  # call rather than a block this method returns out of.
  private def perform(query, variables, operation_name)
    # same tag/truncation as the network transports, so one log reads the
    # same whichever side of the seam a query ran on
    tag = GraphWeaver.logger && GraphWeaver::Internal::Wire.log_tag(operation_name)

    GraphWeaver::Internal::Log.log(:debug) do
      "in-process #{schema_label} #{tag} variables=#{GraphWeaver::Internal::Log.variables_for_log(variables)}\n" \
        "#{GraphWeaver::Internal::Wire.truncate_for_log(query)}"
    end

    GraphWeaver::Internal::Log.log_timed(:debug, "in-process #{schema_label} #{tag} completed") do
      # a copy per query: graphql-ruby writes a resolver's `context[...] =`
      # into the hash it is handed, and one client serves every request
      @schema.execute(query, variables:, operation_name:,
        context: GraphWeaver::Internal::Util.context!(@context).dup)
    end
  rescue GraphWeaver::Error
    raise
  rescue => e
    # a resolver blew up. The same failure over HTTP arrives as a 500, so
    # raise what HTTP would — code that rescues GraphWeaver::Error, or
    # branches on ServerError#status, behaves the same either side.
    # detail:, not body: — there was no response, so there are no bytes to
    # hold, and the diagnosis is this process's own exception
    raise GraphWeaver::ServerError.new(
      status: 500, detail: "#{e.class}: #{GraphWeaver::Internal::Redact.cap(e.message)}",
    )
  end

  # never leak the context (session tokens, current_user) through logs or
  # exceptions — an in-process client inspects as its schema, nothing more
  def inspect = "#<#{self.class.name} schema=#{schema_label}>"
  alias to_s inspect

  # What to call this schema in a log line or an instrumentation payload. A
  # schema built from SDL is an anonymous class, whose #to_s is its object
  # address — a new value every boot, and unbounded cardinality as an APM tag.
  private def schema_label = @schema.name || "anonymous"
end
