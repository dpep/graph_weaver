# typed: true
# frozen_string_literal: true

module GraphWeaver
  module Internal
    # Response headers, as ServerError carries them. HTTP field names are
    # case-insensitive (RFC 9110 §5.1) and the spelling a caller reaches for
    # is the one the server sent ("Retry-After"), while transports store them
    # downcased — so the name is folded on the way in and on the lookups that
    # take one: #[], #fetch, #dig, #key?. Only lookup is forgiving: iteration,
    # #keys and #to_h stay one spelling, which is what a log line and a doc
    # can promise.
    class Headers < Hash
      # tells "no default given" from a default of nil
      MISSING = Object.new
      private_constant :MISSING

      # A Hash of any casing as one of these; already one, untouched.
      def self.wrap(headers)
        return headers if headers.is_a?(self)

        headers.each_with_object(new) { |(name, value), out| out.store(fold(name), value) }
      end

      def self.fold(name) = name.to_s.downcase

      def [](name) = super(Headers.fold(name))

      # spelled out rather than forwarded: sorbet can't splat into Hash#fetch's
      # overloads, and a block beats a default there (Ruby warns if given both)
      def fetch(name, default = MISSING, &block)
        folded = Headers.fold(name)
        return super(folded, &block) if block || default.equal?(MISSING)

        super(folded, default)
      end

      # Hash#dig reads the slot directly rather than through #[], so the fold
      # has to happen here; a header value is a String, so `rest` can only error
      def dig(name, *rest)
        value = self[name]
        rest.empty? ? value : value&.dig(*rest)
      end

      def key?(name) = super(Headers.fold(name))
      alias_method :has_key?, :key?
      alias_method :include?, :key?
      alias_method :member?, :key?
    end
  end
end
