# typed: true
# frozen_string_literal: true

require "monitor"

module GraphWeaver
  # The settable GraphQL context, and the lock that guards it. {InProcess}
  # and {Testing::Router} include it; so can any client of your own that
  # wants the header seam.
  #
  # A `context:` proc is answered from one request's headers, which means
  # assigning the client's context for the length of that dispatch — shared
  # state, on the client. So the lock lives here, beside the field, rather
  # than on whichever wrapper happens to be dispatching:
  # {Testing::Endpoint} is built per request by `graphql: :wire`, and two of
  # them over one client used to share nothing.
  module ContextSeam
    # the context handed to every query this client runs
    attr_reader :context

    def context=(value)
      # Callability is settled by the field's owner, never by the
      # per-request swap below — a resolved hash installed for one dispatch
      # must not tell a concurrent one that this client has no seam.
      @context_callable = value.respond_to?(:call)
      @context = value
    end

    # Run the block with the context this request's headers mean — what
    # {Testing::Endpoint} calls. A callable context is resolved and put back
    # under the lock, so one request's identity can't leak into another's. A
    # plain context has nothing to guard, so it is served concurrently.
    def with_request_context(headers)
      return yield unless @context_callable

      @context_lock.synchronize do
        seam = @context
        @context = seam.call(headers)
        begin
          yield
        ensure
          @context = seam
        end
      end
    end

    # Call from your initializer. A Monitor rather than a Mutex: a resolver
    # may re-enter the app.
    private def init_context_seam(context)
      @context_lock = Monitor.new
      self.context = context
    end
  end
end
