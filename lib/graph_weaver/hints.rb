# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "errors"
require_relative "internal"
require_relative "inflect"

module GraphWeaver
  # Called by generated code — not semver'd for direct use.
  #
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

      suggestions = unknown.to_h do |key|
        prop = GraphWeaver::Codegen.prop_name(key)
        # a wire-cased key — the exact snake_case prop exists
        [key, known.include?(prop) ? prop : GraphWeaver::Internal::Util.did_you_mean(known, prop)]
      end
      hints = suggestions.map { |key, s| s ? "#{key} (did you mean '#{s}'?)" : key }

      # the message lists every unknown key; #path names the first, because a
      # path that points at two fields points at neither. No coordinate: the
      # input type defines no such field, so the schema has no name for it.
      # No value either — and not only because the key owns no slot to hold
      # one: filter_parameters can only match the key the caller supplied, and
      # a typo is by definition not the key they meant, so `passwrod` dodges
      # the `password` filter in the one error that names it as the suggestion.
      first = unknown.first
      raise GraphWeaver::InputError.new(
        "unknown key(s) for #{struct}: #{hints.join(", ")}",
        kind: :unknown, path: [first],
        details: { suggestion: suggestions[first] }.compact, struct: struct,
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
      raise GraphWeaver::CastError.new(struct:, message: "#{key}: #{e.message}")
    end

    # A wire value the generated enum doesn't have — the response-side twin
    # of InputStruct.enum. Almost always drift (the server grew a value since
    # you generated) rather than a bad value, and T::Enum's own KeyError says
    # neither that nor which values exist. Raised bare so the enclosing
    # Hints.field brands it with the field.
    # aliases (register_enum alias:) is wire spelling => the value it reads as.
    def self.enum(type, value, aliases = nil)
      value = aliases.fetch(value, value) if aliases

      type.try_deserialize(value) || drifted!(type, value, type.values.map(&:serialize))
    end

    # the same, for an enum mapped onto an app-owned T::Enum, where the wire
    # table rather than the type knows the accepted values
    def self.mapped_enum(type, table, value)
      table.fetch(value) { drifted!(type, value, table.keys) }
    end

    def self.drifted!(type, value, values)
      raise KeyError, "#{GraphWeaver::Internal::Redact.shown(value)} is not a #{type} — expected one of: " \
        "#{values.sort.join(", ")}; a value the server added since you generated " \
        "needs a regenerate, or register_enum fallback: to absorb them"
    end
    private_class_method :drifted!

    # The message for a response that wouldn't cast. sorbet names the prop
    # and the value but not whose bug it is, and an ID the server sent as
    # its raw integer primary key is the case that keeps happening — so
    # say that GraphQL requires the quotes, and how to take it anyway.
    def self.cast_message(struct, data, error)
      # Shape drift first, because sorbet's account of it is wrong: see
      # drifted_shape. Otherwise sorbet's message is the better one — it names
      # the prop and the value.
      drift = drifted_shape(struct, data)
      return drift if drift

      message = error.message.sub(GraphWeaver::CastError::SORBET_CALLER, "")
      keys = unquoted_keys(struct, data)
      return message if keys.empty?

      "#{message} — the server sent #{keys.join(", ")} unquoted; GraphQL serializes ID and " \
        "String as JSON strings, so that is the server being out of spec. To take it anyway, " \
        'register the scalar loosely: GraphWeaver.register_scalar("ID", "T.untyped")'
    end

    # A response value whose SHAPE its prop can never hold — an object where a
    # list belongs, a scalar inside a list of objects. sorbet catches these in
    # the CALLER's frame, since it is the child's `data` parameter that fails:
    # the parent brands the error, so the struct named is the parent and the
    # key is named nowhere. Worse, a parent mapping over an object has already
    # let Hash#map turn it into [key, value] pairs, so sorbet reports a list of
    # strings the server never sent.
    #
    # Returns the located message, or nil when nothing is out of shape.
    def self.drifted_shape(struct, data)
      return unless data.is_a?(Hash) && struct.respond_to?(:props)

      props = struct.props
      data.filter_map do |key, value|
        prop = props[GraphWeaver::Codegen.prop_name(key.to_s).to_sym]
        # :type_object keeps the nilable-ness :type strips — a null where the
        # schema allows one is not drift, and must not be blamed for a sibling's
        prop && shape_drift(T::Utils.coerce(prop[:type_object]), value, key.to_s)
      end.first
    end
    private_class_method :drifted_shape

    # Only the two shapes a server can get wrong are modelled: a nested struct
    # arrives as an object, a list of them as a list. A scalar prop says
    # nothing here — one that casts already names itself through Hints.field,
    # and T.untyped holds anything.
    def self.shape_drift(type, value, path)
      return if value.nil? && type.valid?(nil)

      core = type.is_a?(T::Types::Union) ? type.types.find { |t| !t.valid?(nil) } : type
      want =
        if core.is_a?(T::Types::TypedArray) then :list
        elsif core.is_a?(T::Types::Simple) && core.raw_type < T::Struct then :object
        end
      return if want.nil?

      unless want == :list ? value.is_a?(Array) : value.is_a?(Hash)
        return "#{path}: expected #{want == :list ? "a list" : "an object"}, " \
          "but the server sent #{wire_kind(value)}"
      end
      return unless want == :list

      value.each_with_index.filter_map { |element, i| shape_drift(core.type, element, "#{path}.#{i}") }.first
    end
    private_class_method :shape_drift

    # What arrived, named as JSON names it. sorbet reports the Ruby type of
    # whatever the cast had half-built by then, which is a different thing.
    def self.wire_kind(value)
      case value
      when nil then "null"
      when Hash then "an object"
      when Array then "a list"
      when String then "a string"
      when Numeric then "a number"
      when true, false then "a boolean"
      else "a #{value.class}"
      end
    end
    private_class_method :wire_kind

    # Response keys whose prop would take a String but whose value is
    # another JSON scalar. Narrow on purpose: a prop that casts (a Date, an
    # enum) legitimately arrives as some other type, so only the
    # pass-through String ones say anything.
    def self.unquoted_keys(struct, data)
      return [] unless data.is_a?(Hash) && struct.respond_to?(:props)

      props = struct.props
      data.filter_map do |key, value|
        next unless value.is_a?(Numeric) || value == true || value == false

        prop = props[GraphWeaver::Codegen.prop_name(key.to_s).to_sym]
        next unless prop

        # :type is a raw Class for a bare-class prop, a T::Types::Base otherwise
        type = T::Utils.coerce(prop[:type])
        key.inspect if type.valid?("") && !type.valid?(value)
      end
    end
    private_class_method :unquoted_keys

    # No matching respond_to_missing?. The hint is an answer about a call that
    # was actually made; respond_to? is a question about the object's shape,
    # and a near miss is not a method this struct has. Answering true broke the
    # standard guard — `obj.pet if obj.respond_to?(:pet)` raised on the very
    # typo the hint exists for — which costs more than `#method(:nmae)` raising
    # Ruby's own bare NameError.
    # Kernel.raise, not bare raise: this module is mixed into every generated
    # struct, so a prop named `raise` would shadow it with a zero-arity reader.
    # Codegen reserves the name; qualifying it here needs no such rule to hold.
    def method_missing(name, *args, &block)
      if args.empty? && (hint = prop_hint(name.to_s))
        Kernel.raise NoMethodError, "undefined method '#{name}' for #{self.class} — #{hint}"
      end

      super
    end

    private

    def prop_hint(name)
      prop = GraphWeaver::Codegen.prop_name(name)
      # method_defined? rather than respond_to?, which a host's own
      # respond_to_missing? could answer for a method it doesn't define
      if prop != name && T.unsafe(self.class).method_defined?(prop)
        return "GraphQL fields generate snake_case props; use '#{prop}'"
      end

      # a guess, not a mapping — spellcheck the (underscored) miss
      # against the props that exist, so typos in either casing land
      props = T.unsafe(self.class).props.keys.map(&:to_s)
      suggestion = GraphWeaver::Internal::Util.did_you_mean(props, prop)
      "did you mean '#{suggestion}'?" if suggestion
    end
  end
end
