# typed: true
# frozen_string_literal: true

require "date" # Date/DateTime, named below
require "time" # Time.iso8601

require_relative "errors"
require_relative "internal/refusal"

module GraphWeaver
  # Called by generated code — not semver'd for direct use.
  #
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

    # said where a date and a timestamp are given for each other
    DATE_HINT = "pass .to_date if dropping the time of day is what you meant"
    TIME_HINT = "a Date has no time of day — pass the Time you mean"
    private_constant :DATE_HINT, :TIME_HINT

    class << self
      # `scalar` is the schema's name for what this rule builds, and it is what
      # the refusal reports — as the message and as #details[:type], which an
      # app translates for a user. It defaults to the GraphQL scalar the rule
      # is named for; generated code passes the schema's own name, so a
      # `register_scalar("BigInt", Integer)` field refuses as a BigInt.
      #
      # A real number converts to the number the scalar names, and whether it
      # is whole is asked of the value — so a BigDecimal off a decimal column
      # and a Rational are ordinary arguments.
      def integer(value, scalar = "Int")
        case value
        when Integer then value
        when Numeric then whole(real(value, scalar), scalar)
        when String then INTEGER.match?(value.strip) ? Integer(value.strip, 10) : unparseable(value, scalar)
        else refuse(value, scalar)
        end
      end

      # Float's own precision is what asking for a Float means, so a BigDecimal
      # past it loses digits here rather than being refused.
      def float(value, scalar = "Float")
        case value
        when Numeric then finite(real(value, scalar).to_f, scalar)
        when String then NUMBER.match?(value.strip) ? finite(Float(value.strip), scalar) : unparseable(value, scalar)
        else refuse(value, scalar)
        end
      end

      # A date stays a Date and a timestamp a Time. Converting between them
      # drops the time of day or invents a midnight, so a cross-type value is
      # refused rather than guessed at — by class, since a timestamp printed
      # in full looks a great deal like a date.
      def date(value, scalar = "Date")
        case value
        # DateTime is a Date to Ruby and a timestamp to everyone else
        when DateTime, Time then cross(value, scalar, DATE_HINT)
        when Date then value
        when String then parsing(scalar, value) { Date.iso8601(value) }
        else time_like?(value) ? cross(value, scalar, DATE_HINT) : refuse(value, scalar)
        end
      end

      # A timestamp string is ISO 8601, read by Time.iso8601 — the coercer
      # graphql-ruby's own ISO8601DateTime reads input with, and the only
      # shape its coerce_result writes. Time.parse also reads "Jan 15 2024
      # 10:20", which no server sends and no generated struct should take.
      def time(value, scalar = "Time")
        case value
        when Time then value
        when DateTime then value.to_time # the same instant in another class
        when Date then cross(value, scalar, TIME_HINT)
        when String then parsing(scalar, value) { Time.iso8601(value) }
        else time_like?(value) ? value.to_time : refuse(value, scalar)
        end
      end

      # A timestamp on the wire: ISO 8601, carrying microseconds only when the
      # value has them. A server that writes sub-second times (every JS one
      # does) round-trips through Ruby unchanged, and a value that doesn't
      # sends the bytes it always has.
      def timestamp(value)
        # DateTime spells its fraction #sec_fraction, Time (and an
        # ActiveSupport::TimeWithZone) spell it #subsec
        fraction = value.respond_to?(:subsec) ? value.subsec : value.sec_fraction
        value.iso8601(fraction.zero? ? 0 : 6)
      end

      # Ruby has no Kernel#Boolean, and every string rule ("0", "off", "no")
      # is somebody's convention — so refuse rather than pick one.
      def boolean(value, scalar = "Boolean")
        return value if value == true || value == false

        refuse(value, scalar, "there is no one right reading of it — convert at the call site")
      end

      def string(value, scalar = "String")
        return value if value.is_a?(String)

        refuse(value, scalar)
      end

      # The GraphQL spec has ID serialize as a String but accept an integer
      # input, which is `execute(id: user.id)` — the everyday Rails call.
      # String gets no such licence: an Integer where a String belongs is
      # more often a bug than a spelling.
      def id(value, scalar = "ID")
        case value
        when String then value
        when Integer then value.to_s
        else refuse(value, scalar)
        end
      end

      # A registration's own `cast:` — Date.iso8601, Money.parse — standing in
      # for a Coerce rule the library has none of. Two things the codec can't
      # do for itself: the pass-through guard (a value already of the type is
      # not rebuilt), and a verdict, since a cast complains about the value
      # alone — "no implicit conversion of Integer into String" names neither
      # what was expected nor which half of the value was wrong.
      def cast(type, value, scalar = nil)
        scalar ||= type.is_a?(Module) ? type.name : type.to_s
        # DateTime is a Date to Ruby and a timestamp to everyone else, so it is
        # not "already a Date" however the app spelled its cast: .date's own
        # refusal, applied BEFORE the cast rather than instead of it.
        cross(value, scalar, DATE_HINT) if type.equal?(::Date) && value.is_a?(::DateTime)
        # a type given as a type string ("T::Hash[...]") names no class to ask
        return value if type.is_a?(Module) && value.is_a?(type)

        parsing(scalar, value) { yield value }
      end

      # Brands one variable's coercion failure with the variable and the
      # operation: a cast complains about the value alone ("invalid date"),
      # which locates nothing in an app that runs a hundred queries. The
      # variable is also the root of #path, so a nested refusal comes out
      # holding the whole route from the kwarg down to the field.
      def variable(name, operation, value)
        yield value
      rescue GraphWeaver::InputError => e
        raise GraphWeaver::InputError.new(
          "#{at(name, operation)}: #{Internal::Redact.detail(name, e.message)}",
          kind: e.kind, path: [name, *e.path], coordinate: e.coordinate,
          # #value is the value AT #path: this layer owns it only when nothing
          # inner named a field (so a missing one stays valueless, as it is) —
          # but the variable's own filter covers everything beneath it
          value: Internal::Redact.value(name, e.path.empty? ? value : e.value),
          details: e.details, struct: e.struct,
        )
      rescue StandardError => e
        # a cast complains about the value without quoting it ("invalid date")
        quoted = shown(value)
        got = " (got #{quoted})" unless e.message.include?(quoted)
        raise GraphWeaver::InputError.new(
          "#{at(name, operation)}: #{Internal::Redact.detail(name, "#{e.message}#{got}")}",
          kind: Internal::Refusal.kind_of(e), path: [name],
          value: Internal::Redact.value(name, value), details: Internal::Refusal.details_of(e),
        )
      end

      private

      def at(name, operation) = operation ? "$#{name} of #{operation}" : "$#{name}"

      # A stdlib parser's own complaint, kept word for word ("invalid date")
      # and labelled with the scalar the schema named — which the parser,
      # handed only a String, has no way to know. Ruby's own convention splits
      # the two: ArgumentError is wrong CONTENT, and the parser says more
      # about it than we could; TypeError is a wrong CLASS, which the parser
      # describes in terms of its own argument ("no implicit conversion of
      # Integer into String") and we can name properly.
      def parsing(scalar, value = nil)
        yield
      rescue ::ArgumentError => e
        raise Internal::Refusal.brand(e, :unparseable, type: scalar)
      rescue ::TypeError
        raise mismatch(::TypeError, "#{expected(scalar)}, got #{shown(value)}", scalar)
      end

      # Kernel#Float("1e400") is Infinity rather than a raise, and so is
      # (10**400).to_f — while JSON has no spelling for a non-finite number
      # and the GraphQL spec excludes them from Float outright. Refusing here
      # names the variable; the transport otherwise complains that the
      # variables aren't serializable, a whole query away from the value.
      def finite(value, scalar = "Float")
        return value if value.finite?

        # a number, but not one GraphQL's Float admits — no conversion applies
        raise mismatch(ArgumentError, "#{expected(scalar)}, got #{shown(value)} — not a finite number", scalar)
      end

      # Complex is the one Numeric that is not a number a scalar can name, and
      # #real? is the predicate for it — no class list to keep up to date.
      def real(value, scalar)
        return value if value.real?

        refuse(value, scalar)
      end

      def whole(value, scalar = "Int")
        # Integer(2.5) is 2 — a silent loss where refusing costs nothing. `% 1`
        # is exact for a BigDecimal and a Rational; asking Float would not be.
        return value.to_i if value.finite? && (value % 1).zero?

        raise mismatch(ArgumentError, "#{expected(scalar)}, got #{shown(value)} — not a whole number", scalar)
      end

      def unparseable(value, scalar)
        raise Internal::Refusal.brand(
          ArgumentError.new("#{expected(scalar)}, got #{shown(value)}"), :unparseable, type: scalar
        )
      end

      # the refusal a caller sees is the plain Ruby error it always was —
      # the kind rides along for the layer that brands it (see Refusal)
      def mismatch(klass, message, scalar)
        Internal::Refusal.brand(klass.new(message), :type_mismatch, type: scalar)
      end

      # ActiveSupport::TimeWithZone — what Time.zone.now returns — is not a
      # Time but is one for every purpose, and #to_time is lossless. acts_like?
      # is Rails' own duck-type check, so nothing answers it by accident.
      # (The real TimeWithZone also answers is_a?(Time); this doesn't rely on
      # it, so a value that stops lying keeps working.)
      def time_like?(value)
        value.respond_to?(:acts_like?) && value.acts_like?(:time) && value.respond_to?(:to_time)
      end

      def cross(value, scalar, hint)
        raise mismatch(::TypeError, "#{expected(scalar)}, got a #{value.class} — #{hint}", scalar)
      end

      def refuse(value, scalar, hint = nil)
        raise mismatch(::TypeError, "#{expected(scalar)}, got #{shown(value)}#{" — #{hint}" if hint}", scalar)
      end

      # the value a refusal quotes: scrubbed at every depth, so a filtered key
      # inside an input object never reaches a sentence (see Redact)
      def shown(value) = Internal::Redact.shown(value)

      # the article by the initial, so a registered Ruby class ("an Integer")
      # reads as well as the scalars ("an Int", "an ID", "a Date")
      def expected(scalar) = "expected #{scalar.start_with?(/[AEIOU]/) ? "an" : "a"} #{scalar}"
    end
  end
end
