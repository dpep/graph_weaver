# typed: true
# frozen_string_literal: true

require_relative "errors"

module GraphWeaver
  # Turning a loose value into the Ruby type a generated kwarg promises.
  #
  # Generated `execute` sigs are `.checked(:never)`, so a `params[:first]`
  # String reaches the body instead of being rejected by sorbet-runtime
  # first — and this is what stands where that check used to: it converts
  # what converts unambiguously and refuses the rest.
  #
  # The conversions raise plain Ruby errors (as Kernel#Integer does) and the
  # caller brands them: `.variable` for an execute kwarg, InputStruct.coerce
  # for an input-object field, Hints.field for a response leaf. One table in
  # both directions — `Coerce.float` is also Float's cast from the wire.
  module Coerce
    # Kernel#Integer reads "010" as octal and "0x1f" as hex, and Kernel#Float
    # takes "1_0" — Ruby literal syntax, not wire syntax, and a zero-padded
    # form field is a real input that must not silently mean something else.
    INTEGER = /\A[+-]?\d+\z/
    NUMBER = /\A[+-]?\d+(\.\d+)?([eE][+-]?\d+)?\z/

    class << self
      def integer(value)
        case value
        when Integer then value
        when Float then whole(value)
        when String then INTEGER.match?(value.strip) ? Integer(value.strip, 10) : unparseable(value, "Int")
        else refuse(value, "Int")
        end
      end

      def float(value)
        case value
        when Float then value
        when Integer then value.to_f
        when String then NUMBER.match?(value.strip) ? Float(value.strip) : unparseable(value, "Float")
        else refuse(value, "Float")
        end
      end

      # Ruby has no Kernel#Boolean, and every string rule ("0", "off", "no")
      # is somebody's convention — so refuse rather than pick one.
      def boolean(value)
        return value if value == true || value == false

        refuse(value, "Boolean", "there is no one right reading of it — convert at the call site")
      end

      def string(value)
        return value if value.is_a?(String)

        refuse(value, "String")
      end

      # The GraphQL spec has ID serialize as a String but accept an integer
      # input, which is `execute(id: user.id)` — the everyday Rails call.
      # String gets no such licence: an Integer where a String belongs is
      # more often a bug than a spelling.
      def id(value)
        case value
        when String then value
        when Integer then value.to_s
        else refuse(value, "ID")
        end
      end

      # Brands one variable's coercion failure with the variable and the
      # operation: a cast complains about the value alone ("invalid date"),
      # which locates nothing in an app that runs a hundred queries.
      def variable(name, operation, value)
        yield value
      rescue GraphWeaver::InputError => e
        raise GraphWeaver::InputError.new("#{at(name, operation)}: #{e.message}", field: name, struct: e.struct)
      rescue StandardError => e
        # a cast complains about the value without quoting it ("invalid date")
        shown = value.inspect
        got = " (got #{shown})" unless e.message.include?(shown)
        raise GraphWeaver::InputError.new("#{at(name, operation)}: #{e.message}#{got}", field: name)
      end

      private

      def at(name, operation) = operation ? "$#{name} of #{operation}" : "$#{name}"

      def whole(value)
        # Integer(2.5) is 2 — a silent loss where refusing costs nothing
        return value.to_i if value.finite? && (value % 1).zero?

        raise ArgumentError, "#{expected("Int")}, got #{value.inspect} — not a whole number"
      end

      def unparseable(value, scalar)
        raise ArgumentError, "#{expected(scalar)}, got #{value.inspect}"
      end

      # ::TypeError — inside GraphWeaver, a bare TypeError is ours
      def refuse(value, scalar, hint = nil)
        raise ::TypeError, "#{expected(scalar)}, got #{value.inspect}#{" — #{hint}" if hint}"
      end

      def expected(scalar) = "expected #{%w[Int ID].include?(scalar) ? "an" : "a"} #{scalar}"
    end
  end
end
