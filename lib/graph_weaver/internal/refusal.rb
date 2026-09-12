# typed: true
# frozen_string_literal: true

module GraphWeaver
  module Internal
    # The verdict a coercion refusal already reached, riding on the plain
    # ::TypeError / ::ArgumentError Coerce raises rather than on a class of
    # its own — so `rescue ::TypeError` still catches it and Coerce keeps
    # complaining the way Kernel#Integer does.
    #
    # The layers that brand a failure (InputStruct.field, Coerce.variable)
    # read it off the exception instead of deriving a kind from the message.
    # A message is prose; reading a verdict back out of one would be a guess,
    # and a wrong `kind` is worse than none — the app will have translated it
    # into a confident sentence.
    module Refusal
      attr_accessor :graph_weaver_kind, :graph_weaver_details

      class << self
        # Tag an exception with its verdict; returns it, ready to raise.
        def brand(error, kind, **details)
          error.extend(Refusal)
          error.graph_weaver_kind = kind
          error.graph_weaver_details = details
          error
        end

        # What a raised exception says went wrong, as an InputError kind.
        # Coerce's own refusals carry their verdict; an app's `cast:` —
        # Date.iso8601, Money.parse — raises whatever it likes, and
        # ArgumentError/TypeError is Ruby's own "that value doesn't convert".
        # Anything else is :refused rather than a guess at what it meant.
        def kind_of(error)
          return error.graph_weaver_kind if error.is_a?(Refusal)

          error.is_a?(::ArgumentError) || error.is_a?(::TypeError) ? :unparseable : :refused
        end

        def details_of(error) = error.is_a?(Refusal) ? error.graph_weaver_details : {}
      end
    end
  end
end
