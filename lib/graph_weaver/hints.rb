# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "inflect"

module GraphWeaver
  # Included in generated response structs. GraphQL's camelCase fields
  # become snake_case props, and reaching for the wire name is a classic
  # stumble — result.nameWithOwner instead of result.name_with_owner.
  # Catch the miss and point at the prop that does exist ("use ..." when
  # the mapping is exact, "did you mean ...?" for a near-miss typo).
  # (Typed call sites get this hint earlier, from srb tc.)
  module Hints
    include Kernel # for sorbet: hosts are Objects

    # Guard for generated input-struct .coerce: a hash key that matches
    # no prop raises (spellchecked) instead of silently dropping — a
    # typo'd filter key must not become "match everything" on the wire.
    def self.validate_keys!(struct, hash)
      known = struct.props.keys.map(&:to_s)
      unknown = hash.keys.map(&:to_s) - known
      return if unknown.empty?

      hints = unknown.map do |key|
        prop = GraphWeaver::Inflect.underscore(key)
        suggestion = if known.include?(prop)
          prop # a wire-cased key — the exact snake_case prop exists
        elsif defined?(DidYouMean::SpellChecker)
          DidYouMean::SpellChecker.new(dictionary: known).correct(prop).first
        end
        suggestion ? "#{key} (did you mean '#{suggestion}'?)" : key
      end
      raise ArgumentError, "unknown key(s) for #{struct}: #{hints.join(", ")}"
    end

    def method_missing(name, *args, &block)
      if args.empty? && (hint = prop_hint(name.to_s))
        raise NoMethodError, "undefined method '#{name}' for #{self.class} — #{hint}"
      end

      super
    end

    private

    def prop_hint(name)
      prop = GraphWeaver::Inflect.underscore(name)
      if prop != name && respond_to?(prop)
        return "GraphQL fields generate snake_case props; use '#{prop}'"
      end

      return unless defined?(DidYouMean::SpellChecker)

      # a guess, not a mapping — spellcheck the (underscored) miss
      # against the props that exist, so typos in either casing land
      props = T.unsafe(self.class).props.keys.map(&:to_s)
      suggestion = DidYouMean::SpellChecker.new(dictionary: props).correct(prop).first
      "did you mean '#{suggestion}'?" if suggestion
    end
  end
end
