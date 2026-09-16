# typed: true
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "errors"
require_relative "hints"

module GraphWeaver
  # Called by generated code — not semver'd for direct use.
  #
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
    # means identity (the wire value passes through untouched). coordinate
    # is the schema's name for the slot ("PetFilter.species") and type its
    # spelling of what goes there ("[Float!]!"), so a refusal can say where
    # it happened, and in whose vocabulary, without reflecting at runtime.
    Field = Data.define(:prop, :wire, :required, :serializer, :coercer, :coordinate, :type)

    # An enum reaching the library as input — an execute kwarg or an input
    # field — as the member or its wire value. Generated code calls these
    # rather than T::Enum.deserialize / the wire table directly: both raise a
    # bare KeyError naming an anonymous module and none of the values they
    # would have taken.
    def self.enum(type, value)
      return value if value.is_a?(type)

      type.try_deserialize(value) || invalid_enum!(type, value, type.values.map(&:serialize))
    end

    # A list element's index, prepended when something inside it refused —
    # `where._and.0._not.species` needs the 0 to name one form field.
    #
    # A nested input's coercer raises an InputError that already holds a path;
    # every LEAF coercer (Coerce.*, .enum) raises a branded plain error instead,
    # so without the second branch the index was dropped for every list of
    # leaves — and an element that wasn't a list at all reached the caller as a
    # raw NoMethodError from the inner `.map`.
    # `value` is the element itself, so a refused leaf carries what was refused
    def self.element(index, value = nil)
      yield
    rescue GraphWeaver::InputError => e
      raise e.within(index)
    rescue StandardError => e
      raise GraphWeaver::InputError.new(
        e.message, kind: GraphWeaver::Internal::Refusal.kind_of(e), path: [index], value:,
        details: GraphWeaver::Internal::Refusal.details_of(e),
      )
    end

    # the same, for an enum mapped onto an app-owned T::Enum (register_enum),
    # where the wire table rather than the type knows the accepted values
    def self.mapped_enum(type, table, value)
      return value if value.is_a?(type)

      table.fetch(value) { invalid_enum!(type, value, table.keys) }
    end

    # Names the input field a coercion refused — a scalar's coercer, an
    # enum's, or a nested input's — since the complaint underneath is about
    # the value alone. A nested error that already named a field keeps its
    # sentence, and only grows a path segment: the innermost input is the one
    # that actually held the bad value.
    def self.field(struct, field, raw)
      prop = field.prop
      yield
    rescue GraphWeaver::InputError => e
      redact = GraphWeaver::Internal::Redact
      raise e.within(field.wire, prop:) if e.field && !redact.filtered?(prop)

      raise GraphWeaver::InputError.new(
        "#{prop}: #{redact.detail(prop, e.message)}",
        kind: e.kind, path: [field.wire, *e.path], coordinate: e.coordinate || field.coordinate,
        # #value is the value AT #path: this layer owns it only when nothing
        # inner named a field (so a missing one stays valueless, as it is)
        value: redact.value(prop, e.path.empty? ? raw : e.value),
        details: e.details, struct: e.struct || struct,
      )
    rescue StandardError => e
      redact = GraphWeaver::Internal::Redact
      raise GraphWeaver::InputError.new(
        "#{prop}: #{redact.detail(prop, e.message)}",
        kind: GraphWeaver::Internal::Refusal.kind_of(e), path: [field.wire],
        coordinate: field.coordinate, value: redact.value(prop, raw),
        details: GraphWeaver::Internal::Refusal.details_of(e), struct:,
      )
    end

    # Raised bare, like Hints.drifted!: the enclosing .field or Coerce.variable
    # knows the key, and so is the only layer that can decide whether this
    # value may be named. The verdict rides along, since nothing outside here
    # can tell an out-of-range enum from any other KeyError.
    def self.invalid_enum!(type, value, values)
      shown = GraphWeaver::Internal::Redact.shown(value)
      raise GraphWeaver::Internal::Refusal.brand(
        KeyError.new("#{shown} is not a valid #{type} — expected one of: #{values.sort.join(", ")}"),
        :not_a_member, members: values.sort,
      )
    end
    private_class_method :invalid_enum!

    def self.included(base)
      base.extend(ClassMethods)
    end

    # Which props the caller actually named, when we know. GraphQL tells an
    # absent input field from an explicit null, and a Hash can say which it
    # meant — so .coerce records it. A struct built with .new can't: every
    # unset prop is nil either way, and nil there stays "leave it out".
    attr_accessor :supplied

    # the wire hash — an optional field stays off it unless the caller
    # supplied the nil
    def serialize
      given = supplied
      wire = self.class.const_get(:FIELDS).each_with_object({}) do |field, out|
        value = public_send(field.prop)
        next if value.nil? && !field.required && !given&.include?(field.prop)

        out[field.wire] =
          begin
            field.serializer && !value.nil? ? field.serializer.call(value) : value
          rescue GraphWeaver::InputError => e
            # a nested input's own refusal (@oneOf, a custom serialize:) —
            # every layer prepends the segment that led to it. Kernel.raise,
            # since this module is mixed into the struct and a prop named
            # `raise` would shadow a bare one with a zero-arity reader.
            Kernel.raise e.within(field.wire, prop: field.prop)
          end
      end

      # @oneOf declares "exactly one of these, and not null", but every field
      # is nullable, so nothing before here can enforce it — not the struct's
      # types, not the server until the round trip
      one_of!(wire) if self.class.const_defined?(:ONE_OF, false)

      wire
    end
    alias_method :to_h, :serialize

    # Two different mistakes, and "supply exactly one field" is the wrong
    # sentence for the second: the caller who wrote `{ id: nil }` supplied
    # exactly one field. That one is a missing value, so it says so and names
    # the slot — a form has something to highlight, which the count case
    # (nothing, or several) has no single field to give.
    private def one_of!(wire)
      if wire.size == 1 && wire.values.first.nil?
        name = wire.keys.first
        field = self.class.const_get(:FIELDS).find { |candidate| candidate.wire == name }
        Kernel.raise GraphWeaver::InputError.new(
          "#{self.class} is @oneOf and #{name} was null — supply a value for it, or a different field",
          kind: :missing, path: [field.wire], coordinate: field.coordinate, struct: self.class,
        )
      end

      return if wire.size == 1

      Kernel.raise GraphWeaver::InputError.new(
        "#{self.class} is @oneOf — supply exactly one field, non-null, got " \
          "#{wire.empty? ? "none" : wire.keys.sort.join(", ")}",
        struct: self.class,
      )
    end

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
          # the message names the Ruby you may pass; #details is what an app
          # translates for a user, so it speaks the schema's vocabulary
          raise GraphWeaver::InputError.new(
            "expected a Hash or #{self}, got #{value.class}",
            kind: :type_mismatch, details: { type: graphql_name }, struct: self,
          )
        end

        # a typo'd key must not silently drop off the wire
        GraphWeaver::Hints.validate_keys!(self, value)

        fields = T.unsafe(self).const_get(:FIELDS)
        given = fields.select { |field| value.key?(field.prop) || value.key?(field.prop.to_s) }.map(&:prop)
        supplied = fields.to_h do |field|
          raw = value.key?(field.prop) ? value[field.prop] : value[field.prop.to_s]
          next [field.prop, raw] if raw.nil? || field.coercer.nil?

          # a coercer is arbitrary Ruby — Coerce.integer, Date.iso8601, a
          # nested .coerce — and its complaint is about the value alone
          [field.prop, GraphWeaver::InputStruct.field(self, field, raw) { field.coercer.call(raw) }]
        end

        # FIELDS knows which are required, so say what is missing — sorbet's
        # own complaint describes the symptom ("Can't set .name to nil") and
        # names only the first one it reaches
        missing = fields.select { |field| field.required && supplied[field.prop].nil? }
        unless missing.empty?
          # the message lists every one; #path names the first, because a
          # path that points at two fields points at neither
          raise GraphWeaver::InputError.new(
            "missing required key(s) for #{self}: #{missing.map(&:prop).join(", ")}",
            kind: :missing, path: [missing.first.wire],
            coordinate: missing.first.coordinate, struct: self,
          )
        end

        T.unsafe(self).new(**supplied).tap { |struct| struct.supplied = given }
      rescue GraphWeaver::InputError
        raise # already contextualized by a nested input / enum coercion
      rescue ::TypeError, ::ArgumentError, KeyError => e
        # a wrong-typed field, a missing required field, or an out-of-range
        # enum — surface one branded, structured error for a 422.
        raise mistyped(supplied) ||
          GraphWeaver::InputError.new(
            "invalid input for #{self}: #{e.message}",
            kind: GraphWeaver::Internal::Refusal.kind_of(e),
            details: GraphWeaver::Internal::Refusal.details_of(e), struct: self,
          )
      end

      private

      def graphql_name = T.unsafe(self).const_get(:GRAPHQL_NAME)

      # The prop whose value its own type refuses, reported the way every
      # other input failure is. Only sorbet stands between a field with no
      # coercer and the struct, and it names the prop and the value inside
      # one free-text sentence — which reads as the library's own bug, and
      # which no filter can see into.
      def mistyped(supplied)
        return unless supplied

        T.unsafe(self).props.each do |prop, info|
          value = supplied[prop]
          # :type_object carries the nilable-ness the prop was declared with;
          # :type is that unwrapped, which is the half worth naming — an
          # absent optional field is nil and legal, and a missing required
          # one was reported by name before we got here.
          #
          # recursively_valid?, which is the predicate the SETTER enforces:
          # #valid? stops at the outermost type, so `[1, 2, 3]` for a
          # T::Array[Float] (a type-string registration, so no coercer ran)
          # passed here while the setter refused it — and the refusal came
          # out blaming the list that held the struct, in sorbet's words.
          next if T::Utils.coerce(info[:type_object]).recursively_valid?(value)

          # the SCHEMA's spelling, from the FIELDS row — #details[:type] is
          # what an app translates for a user, and "T::Array[Float]" is the
          # library's vocabulary leaking into theirs
          field = T.unsafe(self).const_get(:FIELDS).find { |f| f.prop == prop }
          type = field&.type || T::Utils.coerce(info[:type]).to_s
          return GraphWeaver::InputError.new(
            "#{prop}: expected #{type}, got #{GraphWeaver::Internal::Redact.shown(value, prop)}",
            kind: :type_mismatch, path: [prop.to_s], coordinate: field&.coordinate,
            value: GraphWeaver::Internal::Redact.value(prop, value),
            details: { type: }, struct: self,
          )
        end
        nil
      end
    end
  end
end
