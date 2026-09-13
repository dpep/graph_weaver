# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

module GraphWeaver
  # Included in every generated result struct — the twin of InputStruct on
  # the way out. T::Struct compares by identity, has no #to_h and can't be
  # destructured, so two results parsed from the same response come back
  # unequal, `result.to_h` raises, and `case result in {person:}` raises
  # NoMatchingPatternError. A struct the library hands you should behave
  # like an ordinary Ruby object; this is that behaviour, in one place.
  module ResultStruct
    extend T::Sig
    include Kernel # for sorbet: hosts are T::Structs

    # Value equality over the struct's props. Nested structs compare
    # through their own copy of this, so a whole result tree compares.
    # eql? on the props hash rather than ==, so that this and #hash agree
    # on what "same" means (1 and 1.0 hash differently).
    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      other.instance_of?(self.class) && deconstruct_keys(nil).eql?(other.deconstruct_keys(nil))
    end
    alias_method :eql?, :==

    # eql? and hash move together, or a struct is a broken Hash key.
    sig { returns(Integer) }
    def hash = [self.class, *deconstruct_keys(nil).values].hash

    # Pattern matching: `case result in {person: {name:}}`. Every prop,
    # always — the pattern binds the ones it names, and a nested struct
    # destructures through its own copy. Values stay as they are, so
    # `in {person: Person => p}` binds the struct rather than a hash.
    sig { params(_keys: T.nilable(T::Array[Symbol])).returns(T::Hash[Symbol, T.untyped]) }
    def deconstruct_keys(_keys)
      self.class.props.keys.to_h { |prop| [prop, public_send(prop)] }
    end

    # The Ruby-side view of the result: snake_case prop names as Symbols,
    # nils kept, nested structs and arrays followed, enums left as their
    # T::Enum members.
    #
    # Deliberately NOT the wire shape, and not an inverse of .from_h — a
    # registered scalar keeps whatever Ruby object its codec built. That
    # is the same objection Response#to_h raises against re-serializing
    # its data, and it doesn't apply here: this hash is Symbol-keyed and
    # Ruby-cased, so it can't be mistaken for the server's response.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      deconstruct_keys(nil).transform_values { |value| unwrap_value(value) }
    end

    # JSON is the wire's shape, not Ruby's: `to_json` is the generated
    # `as_json` encoded, so it carries the response keys and each leaf back
    # through its scalar registration's `serialize:`, and
    # `.from_h(JSON.parse(result.to_json))` gives an equal struct. That is
    # the opposite of #to_h, deliberately — a Symbol-keyed Ruby hash can't be
    # mistaken for a response, and a JSON string can, so the string is the
    # one that has to be true. (A registration with no `serialize:` has no
    # wire form; its value passes through, exactly as it does on the way in.)
    #
    # Defined here rather than left to Ruby: Object#to_json writes the
    # #inspect string, quoted, and ActiveSupport's Object#as_json writes the
    # ivars — a result's snake_cased props, `class_` and all.
    sig { params(options: T.untyped).returns(String) }
    def to_json(options = nil) = as_json.to_json(options)

    # Only reached by a struct generated before as_json existed — the
    # generated override otherwise wins, being defined on the struct itself.
    sig { params(_options: T.untyped).returns(T::Hash[String, T.untyped]) }
    def as_json(*_options)
      raise GraphWeaver::Error,
        "#{self.class} was generated before #as_json — regenerate (rake graph_weaver:generate)"
    end

    private

    # Follows a value into nested result structs and lists (which nest, for
    # a `[[Pet!]!]!`); everything else is already Ruby-side.
    sig { params(value: T.untyped).returns(T.untyped) }
    def unwrap_value(value)
      case value
      when ResultStruct then value.to_h
      when Array then value.map { |item| unwrap_value(item) }
      else value
      end
    end
  end
end
