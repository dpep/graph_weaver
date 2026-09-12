# typed: ignore — ActiveSupport::LogSubscriber, which sorbet can't resolve here
# frozen_string_literal: true

module GraphWeaver
  # One line per GraphQL operation in a Rails log, the shape ActiveRecord
  # uses for a query:
  #
  #      GraphWeaver PersonQuery (12.3ms) ok
  #      GraphWeaver PersonQuery (8.1ms) errors [THROTTLED]
  #      GraphWeaver PersonQuery (31.2ms) failed GraphWeaver::TransportError
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
        "GraphWeaver #{payload[:operation] || "query"} (#{format("%.1f", ms)}ms) #{outcome(payload)}"
      end
    end

    # GraphWeaver's logger, not Rails' — LogSubscriber#call skips a
    # subscriber whose logger is nil, which is what makes the gem's own
    # opt-out reach this line too.
    def logger = GraphWeaver.logger

    private

    # status, then whatever narrows it: the error class, the code an alert
    # groups by, and which attempt this was when a Retry is in the stack.
    def outcome(payload)
      parts = [payload[:status], payload[:error]]
      parts << "[#{payload[:code]}]" if payload[:code]
      parts << "(retry #{payload[:retries]})" if payload[:retries].to_i.positive?
      parts.compact.join(" ")
    end
  end
end
