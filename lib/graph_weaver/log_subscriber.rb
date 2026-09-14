# typed: ignore — ActiveSupport::LogSubscriber, which sorbet can't resolve here
# frozen_string_literal: true

# The superclass, so this file stands alone: requiring it by hand is the
# documented way to subscribe outside Rails, and there is no railtie out there
# to have loaded ActiveSupport first. Skipped when the constant already
# exists, which is how a stand-in can take its place.
require "active_support/log_subscriber" unless defined?(ActiveSupport::LogSubscriber)

module GraphWeaver
  # One line per GraphQL operation in a Rails log, the shape ActiveRecord
  # uses for a query:
  #
  #      GraphWeaver PersonQuery (12.3ms) ok
  #      GraphWeaver PersonQuery (8.1ms) errors [THROTTLED]
  #      GraphWeaver PersonQuery (31.2ms) failed GraphWeaver::TransportError
  #      GraphWeaver billing/InvoicesQuery (12.3ms) ok
  #
  # Attached by the railtie wherever ActiveSupport is, and fed by the
  # instrumenter it sets. Requires ActiveSupport — `require` this yourself
  # only if you subscribe by hand.
  #
  # **One rule decides which line you get: the summary is info, the wire is
  # debug.** This is the only GraphWeaver line at info, so a production log
  # gets one per operation and nothing that could carry PII; turning
  # GraphWeaver.logger up to debug adds the query, the variables and the
  # response *beneath* it rather than repeating it.
  #
  # It writes through GraphWeaver.logger rather than Rails.logger, so
  # `GraphWeaver.logger = nil` — the documented way to silence the gem —
  # silences this too, and the line carries the same `graph_weaver`
  # progname as every other one.
  class LogSubscriber < ActiveSupport::LogSubscriber
    # attach_to(:graph_weaver) subscribes "#{method}.graph_weaver" and
    # ActiveSupport::Subscriber#call dispatches on the name up to the first
    # dot — so this method name is EXECUTE_EVENT's first half, both ways.
    def execute(event)
      payload = event.payload

      GraphWeaver::Internal::Log.log(:info) do
        # duration_ms is the instrumenter's own measurement; event.duration
        # covers a subscriber attached to something that didn't set it
        ms = payload[:duration_ms] || event.duration
        "GraphWeaver #{subject(payload)} (#{format("%.1f", ms)}ms) #{outcome(payload)}"
      end
    end

    # GraphWeaver's logger, not Rails' — LogSubscriber#call skips a
    # subscriber whose logger is nil, which is what makes the gem's own
    # opt-out reach this line too.
    def logger = GraphWeaver.logger

    private

    # What ran: the operation, prefixed by its graph when the request carried
    # one — an app with several graphs reads `billing/InvoicesQuery` without
    # a second line shape to learn, and one with a single graph never sees it.
    def subject(payload)
      operation = payload[:operation] || "query"
      payload[:graph] ? "#{payload[:graph]}/#{operation}" : operation
    end

    # status, then whatever narrows it: the error class, the reason an alert
    # groups by, and which attempt this was when a Retry is in the stack.
    def outcome(payload)
      parts = [payload[:status], payload[:error]]
      # the GraphQL code, or the HTTP status where the request never got one
      reason = payload[:code] || (payload[:http_status] if payload[:status] == :failed)
      parts << "[#{reason}]" if reason
      parts << "(retry #{payload[:retries]})" if payload[:retries].to_i.positive?
      parts.compact.join(" ")
    end
  end
end
