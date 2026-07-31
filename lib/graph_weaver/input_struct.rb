# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "errors"
require_relative "hints"

module GraphWeaver
  # Runtime for generated input structs. Each struct declares its typed
  # consts plus a compact FIELDS table — (prop, wire name, requiredness,
  # serializer, coercer) per field, with the conversions emitted as
  # lambdas — and this module is the loop that drives it. One copy here
  # instead of unrolled methods in every struct, which is the difference
  # between ~2 lines and ~6 lines per field when a Hasura bool_exp pulls
  # hundreds of input types into one module.
  module InputStruct
    include Kernel # for sorbet: hosts are T::Structs

    # serializer/coercer are code-as-data from the generated file; nil
    # means identity (the wire value passes through untouched)
    Field = Struct.new(:prop, :wire, :required, :serializer, :coercer)

    def self.included(base)
      base.extend(ClassMethods)
    end

    # the wire hash — optional fields left nil stay off the wire
    def serialize
      self.class.const_get(:FIELDS).each_with_object({}) do |field, wire|
        value = public_send(field.prop)
        next if value.nil? && !field.required

        wire[field.wire] = field.serializer && !value.nil? ? field.serializer.call(value) : value
      end
    end
    alias_method :to_h, :serialize

    module ClassMethods
      include Kernel

      # Build from a plain hash (underscored keys, Symbol or String):
      # enums accept their wire values, nested inputs accept hashes; the
      # struct's types are enforced on construction, and unknown keys
      # raise with a spellchecked hint.
      def coerce(value)
        return value if value.is_a?(self)

        # a caller passing a non-Hash (a bare string, or a Hash where a nested
        # list was expected) is bad input — surface a branded 422, not a raw
        # NoMethodError from validate_keys!'s `.keys`
        unless value.is_a?(Hash)
          raise GraphWeaver::InputError.new("expected a Hash or #{self}, got #{value.class}", struct: self)
        end

        # a typo'd key must not silently drop off the wire
        GraphWeaver::Hints.validate_keys!(self, value)

        fields = T.unsafe(self).const_get(:FIELDS)
        T.unsafe(self).new(**fields.to_h do |field|
          raw = value.key?(field.prop) ? value[field.prop] : value[field.prop.to_s]
          [field.prop, raw.nil? || field.coercer.nil? ? raw : field.coercer.call(raw)]
        end)
      rescue GraphWeaver::InputError
        raise # already contextualized by a nested input / enum coercion
      rescue ::TypeError, ::ArgumentError, KeyError => e
        # a wrong-typed field, a missing required field, or an out-of-range
        # enum — surface one branded, structured error for a 422. (`::` so the
        # rescue catches Ruby's TypeError, not GraphWeaver::TypeError.)
        raise GraphWeaver::InputError.new("invalid input for #{self}: #{e.message}", struct: self)
      end
    end
  end
end
