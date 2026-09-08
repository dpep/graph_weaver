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

    # An enum reaching the library as input — an execute kwarg or an input
    # field — as the member or its wire value. Generated code calls these
    # rather than T::Enum.deserialize / the wire table directly: both raise a
    # bare KeyError naming an anonymous module and none of the values they
    # would have taken, and a kwarg's KeyError escapes the umbrella entirely
    # (nothing wraps it the way #coerce wraps an input field's).
    def self.enum(type, value)
      return value if value.is_a?(type)

      type.try_deserialize(value) || invalid_enum!(type, value, type.values.map(&:serialize))
    end

    # the same, for an enum mapped onto an app-owned T::Enum (register_enum),
    # where the wire table rather than the type knows the accepted values
    def self.mapped_enum(type, table, value)
      return value if value.is_a?(type)

      table.fetch(value) { invalid_enum!(type, value, table.keys) }
    end

    def self.invalid_enum!(type, value, values)
      raise GraphWeaver::InputError.new(
        "#{value.inspect} is not a valid #{type} — expected one of: #{values.sort.join(", ")}",
        struct: type,
      )
    end
    private_class_method :invalid_enum!

    def self.included(base)
      base.extend(ClassMethods)
    end

    # the wire hash — optional fields left nil stay off the wire
    def serialize
      wire = self.class.const_get(:FIELDS).each_with_object({}) do |field, out|
        value = public_send(field.prop)
        next if value.nil? && !field.required

        out[field.wire] = field.serializer && !value.nil? ? field.serializer.call(value) : value
      end

      # @oneOf declares "exactly one of these", but every field is nullable, so
      # nothing before here can enforce it — not the struct's types, not the
      # server until the round trip
      if wire.size != 1 && self.class.const_defined?(:ONE_OF, false)
        raise GraphWeaver::InputError.new(
          "#{self.class} is @oneOf — supply exactly one field, got #{wire.empty? ? "none" : wire.keys.sort.join(", ")}",
          struct: self.class,
        )
      end

      wire
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
        supplied = fields.to_h do |field|
          raw = value.key?(field.prop) ? value[field.prop] : value[field.prop.to_s]
          [field.prop, raw.nil? || field.coercer.nil? ? raw : field.coercer.call(raw)]
        end

        # FIELDS knows which are required, so say what is missing — sorbet's
        # own complaint describes the symptom ("Can't set .name to nil") and
        # names only the first one it reaches
        missing = fields.select { |field| field.required && supplied[field.prop].nil? }.map(&:prop)
        unless missing.empty?
          raise GraphWeaver::InputError.new(
            "missing required key(s) for #{self}: #{missing.join(", ")}",
            field: missing.join(", "), struct: self,
          )
        end

        T.unsafe(self).new(**supplied)
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
