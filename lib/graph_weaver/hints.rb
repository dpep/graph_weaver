# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "errors"
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
        else
          GraphWeaver.did_you_mean(known, prop)
        end
        suggestion ? "#{key} (did you mean '#{suggestion}'?)" : key
      end
      raise GraphWeaver::InputError.new(
        "unknown key(s) for #{struct}: #{hints.join(", ")}",
        field: unknown.join(", "),
        struct: struct,
      )
    end

    # Wraps one field's cast in generated from_h so a failure says which
    # field. A scalar's cast is arbitrary Ruby — Float(), Date.iso8601, an
    # app's Money.parse — and its complaint is about the value alone
    # ("invalid date"), which locates nothing on a struct holding four
    # dates. Sorbet's own prop errors already name the prop, so this is
    # only on the leaves that cast.
    def self.field(struct, key)
      yield
    rescue GraphWeaver::Error
      raise # a nested struct already named its own field
    rescue StandardError => e
      raise GraphWeaver::TypeError.new(struct:, message: "#{key}: #{e.message}")
    end

    # A wire value the generated enum doesn't have — the response-side twin
    # of InputStruct.enum. Almost always drift (the server grew a value since
    # you generated) rather than a bad value, and T::Enum's own KeyError says
    # neither that nor which values exist. Raised bare so the enclosing
    # Hints.field brands it with the field.
    def self.enum(type, value)
      type.try_deserialize(value) || drifted!(type, value, type.values.map(&:serialize))
    end

    # the same, for an enum mapped onto an app-owned T::Enum, where the wire
    # table rather than the type knows the accepted values
    def self.mapped_enum(type, table, value)
      table.fetch(value) { drifted!(type, value, table.keys) }
    end

    def self.drifted!(type, value, values)
      raise KeyError, "#{value.inspect} is not a #{type} — expected one of: " \
        "#{values.sort.join(", ")}; a value the server added since you generated " \
        "needs a regenerate, or register_enum fallback: to absorb them"
    end
    private_class_method :drifted!

    # The message for a response that wouldn't cast. sorbet names the prop
    # and the value but not whose bug it is, and an ID the server sent as
    # its raw integer primary key is the case that keeps happening — so
    # say that GraphQL requires the quotes, and how to take it anyway.
    def self.cast_message(struct, data, error)
      message = error.message.sub(GraphWeaver::TypeError::SORBET_CALLER, "")
      keys = unquoted_keys(struct, data)
      return message if keys.empty?

      "#{message} — the server sent #{keys.join(", ")} unquoted; GraphQL serializes ID and " \
        "String as JSON strings, so that is the server being out of spec. To take it anyway, " \
        'register the scalar loosely: GraphWeaver.register_scalar("ID", "T.untyped")'
    end

    # Response keys whose prop would take a String but whose value is
    # another JSON scalar. Narrow on purpose: a prop that casts (a Date, an
    # enum) legitimately arrives as some other type, so only the
    # pass-through String ones say anything.
    def self.unquoted_keys(struct, data)
      return [] unless data.is_a?(Hash) && struct.respond_to?(:props)

      props = struct.props
      data.filter_map do |key, value|
        next unless value.is_a?(Numeric) || value == true || value == false

        prop = props[GraphWeaver::Inflect.underscore(key.to_s).to_sym]
        next unless prop

        # :type is a raw Class for a bare-class prop, a T::Types::Base otherwise
        type = T::Utils.coerce(prop[:type])
        key.inspect if type.valid?("") && !type.valid?(value)
      end
    end
    private_class_method :unquoted_keys

    def method_missing(name, *args, &block)
      if args.empty? && (hint = prop_hint(name.to_s))
        raise NoMethodError, "undefined method '#{name}' for #{self.class} — #{hint}"
      end

      super
    end

    # keeps #method and #respond_to? agreeing with method_missing — without
    # it `struct.method(:nmae)` raises a bare NameError while `struct.nmae`
    # gets the hint
    def respond_to_missing?(name, include_private = false)
      !!prop_hint(name.to_s) || super
    end

    private

    def prop_hint(name)
      prop = GraphWeaver::Inflect.underscore(name)
      # method_defined?, not respond_to? — respond_to_missing? lands back here
      if prop != name && T.unsafe(self.class).method_defined?(prop)
        return "GraphQL fields generate snake_case props; use '#{prop}'"
      end

      # a guess, not a mapping — spellcheck the (underscored) miss
      # against the props that exist, so typos in either casing land
      props = T.unsafe(self.class).props.keys.map(&:to_s)
      suggestion = GraphWeaver.did_you_mean(props, prop)
      "did you mean '#{suggestion}'?" if suggestion
    end
  end
end
