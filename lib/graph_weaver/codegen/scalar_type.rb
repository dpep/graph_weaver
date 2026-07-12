# typed: true
# frozen_string_literal: true

class GraphWeaver::Codegen

  # How one GraphQL scalar maps to Ruby: the Sorbet prop type, the
  # (optional) code emitted to deserialize a wire value into a rich Ruby
  # object and serialize it back, and any requires the generated file
  # needs. A single registry (below) holds one of these per scalar name;
  # the built-in scalars are just pre-registered entries, so custom
  # scalars and overrides go through the same path.
  #
  # cast/serialize normalize to procs that, given a Ruby expression string,
  # return the code to inline. Left nil (the default) they are inferred
  # from the Ruby type when it is a real class, by probing for a known
  # deserializer and pairing its serializer (see CODECS) — so the common
  # case needs no more than a class:
  #      type: Money   (defines .parse)   => Money.parse(expr) / expr.to_s
  #      type: Blob    (defines .load)    => Blob.load(expr)   / Blob.dump(expr)
  # Probing the *deserialize* side is deliberate: every object has #to_s,
  # so inferring a serializer off it would wrongly wrap plain types (String,
  # Integer) — pairing off a deserializer the type actually defines avoids
  # that. Override with an explicit value:
  #   - a Symbol names a method, so there is no string to misspell:
  #           cast: :load        => "Blob.load(expr)"    (class method on type)
  #           serialize: :to_json => "expr.to_json"      (instance method)
  #   - a Proc handles anything a Symbol can't express:
  #           cast: ->(e) { "Money.new(#{e})" }
  #   - :itself opts out — force identity pass-through even when a codec
  #     would otherwise match (rare)
  # requires: a String or Array of paths emitted as `require`s atop the
  # generated file (e.g. "bigdecimal") so the cast/type resolve.
  class ScalarType
    # Inferred (deserialize, serialize) codecs, tried in order; the first
    # whose probe the Ruby type defines as a class method wins, and its
    # serialize is paired with it. Builders take (type_name, expr) => code.
    Codec = Struct.new(:probe, :cast, :serialize)
    CODECS = [
      Codec.new(:parse, # Type.parse(wire) <-> value.to_s
        ->(type, expr) { "#{type}.parse(#{expr})" },
        ->(_type, expr) { "#{expr}.to_s" }),
      Codec.new(:load, # Type.load(wire) <-> Type.dump(value)
        ->(type, expr) { "#{type}.load(#{expr})" },
        ->(type, expr) { "#{type}.dump(#{expr})" }),
    ].freeze

    # Accepted kwarg types for Symbol (instance-method) coercion — the
    # looser inputs the conversion sensibly handles. #to_s is defined on
    # every object, so it accepts anything; #to_f/#to_i only make sense for
    # numerics and strings.
    CONVERT_INPUTS = {
      to_f: "T.any(Float, Integer, String)",
      to_i: "T.any(Integer, Float, String)",
      to_s: "T.anything",
    }.freeze

    attr_reader :graphql_name, :type, :requires

    def initialize(graphql_name, type, cast: nil, serialize: nil, requires: nil, coerce: nil)
      @graphql_name = graphql_name.to_s
      @klass = type.is_a?(Module) ? type : nil
      @type = type_name(type)
      # requires: load BEFORE codec probing — the probe method may come
      # from the required file (core Time has no .parse until the "time"
      # stdlib loads)
      @requires = normalize_requires(requires)
      codec = @klass && CODECS.find { |c| @klass.respond_to?(c.probe) }
      @cast = normalize_cast(cast, codec&.cast)
      @serialize = normalize_serialize(serialize, codec&.serialize)
      @coerce = coerce
      validate_coerce!
    end

    # conversions applied to the four convertible built-ins when the
    # global GraphWeaver.auto_coerce is on and no explicit coerce: given
    AUTO_CONVERSIONS = {
      "ID" => :to_s, "String" => :to_s, "Int" => :to_i, "Float" => :to_f,
    }.freeze

    def cast(expr) = @cast&.call(expr)
    def cast? = !@cast.nil?
    def serialize(expr) = @serialize&.call(expr)
    def serialize? = !@serialize.nil?
    def coerce? = !!effective_coerce

    # Explicit coerce: always wins (false means never). Left unset, the
    # global GraphWeaver.auto_coerce decides — resolved HERE, at
    # generation time, so registration order doesn't matter: convertible
    # built-ins get their conversion, anything with a full cast/serialize
    # pair gets parse-style coercion.
    def effective_coerce
      return @coerce unless @coerce.nil?
      return false unless GraphWeaver.auto_coerce

      AUTO_CONVERSIONS.fetch(@graphql_name) { (cast? && serialize?) || nil }
    end

    # The code that normalizes a variable input before it's serialized. Two
    # shapes: coerce: true parses a raw value into the rich type via the cast
    # (guarded so an already-typed value passes through); coerce: :to_f (a
    # Symbol) calls that instance method, for built-ins where a plain
    # conversion is the whole story (5, "5" -> 5.0). serialize still runs
    # afterward, but is identity for the conversion built-ins, so the
    # converted value goes on the wire natively (a Float, not "5.0").
    def coerce_input(expr)
      case effective_coerce
      when true then "(#{expr}.is_a?(#{@type}) ? #{expr} : #{cast(expr)})"
      when Symbol then "#{expr}.#{effective_coerce}"
      end
    end

    # the accepted Sorbet type for a coercible variable kwarg
    def coerce_type
      case effective_coerce
      when true then "T.any(#{@type}, String)"
      when Symbol then CONVERT_INPUTS.fetch(effective_coerce, "T.untyped")
      end
    end

    private

    def type_name(type)
      case type
      when Module then type.name
      when String then type
      else raise ArgumentError, "type: must be a class/module or String, got #{type.inspect}"
      end
    end

    # nil infers via the matched codec; :itself opts out (identity); a
    # Symbol is a class method on the type — Money.parse(expr)
    def normalize_cast(cast, inferred)
      case cast
      when :itself then nil
      when nil then inferred && ->(expr) { inferred.call(@type, expr) }
      when Proc then cast
      when Symbol then ->(expr) { "#{@type}.#{cast}(#{expr})" }
      else raise ArgumentError, "cast: must be a Symbol, Proc, :itself, or nil, got #{cast.inspect}"
      end
    end

    # nil infers via the matched codec; :itself opts out (identity); a
    # Symbol is an instance method on the value — expr.to_s
    def normalize_serialize(serialize, inferred)
      case serialize
      when :itself then nil
      when nil then inferred && ->(expr) { inferred.call(@type, expr) }
      when Proc then serialize
      when Symbol then ->(expr) { "#{expr}.#{serialize}" }
      else raise ArgumentError, "serialize: must be a Symbol, Proc, :itself, or nil, got #{serialize.inspect}"
      end
    end

    # requires: is a require path or list of them; each must be a non-empty
    # String (it is emitted verbatim as `require "..."`), caught here rather
    # than as a syntax error in the generated file. When a real class was
    # given as type:, we're in a runtime with its deps loaded, so we also
    # `require` each path to prove it resolves (a no-op for already-loaded
    # libs, and it surfaces a typo now). With only a type-name string we
    # can't assume the lib is installed at codegen time, so we don't try.
    def normalize_requires(requires)
      Array(requires).each do |req|
        unless req.is_a?(String) && !req.empty?
          raise ArgumentError, "requires: must be a String or Array of Strings, got #{req.inspect}"
        end

        next unless @klass

        begin
          require req
        rescue LoadError => e
          raise ArgumentError, "requires: #{req.inspect} is not loadable (#{e.message})"
        end
      end
    end

    # coerce: true round-trips through cast+serialize, so it needs both; a
    # Symbol is a self-contained conversion and needs neither.
    def validate_coerce!
      case @coerce
      when false, nil, Symbol then nil
      when true
        return if cast? && serialize?

        raise ArgumentError,
          "coerce: true needs both a cast and a serialize (#{@graphql_name} is missing one)"
      else
        raise ArgumentError, "coerce: must be true, false, or a Symbol method name, got #{@coerce.inspect}"
      end
    end
  end

  class << self
    # Register (or override) how a GraphQL custom scalar deserializes into
    # a Ruby object and serializes back onto the wire. See ScalarType for
    # the accepted cast:/serialize:/requires: forms. Later registrations
    # win, so an app can override a built-in (e.g. map Date onto its own
    # type).
    def register_scalar(graphql_name, type, cast: nil, serialize: nil, requires: nil, coerce: nil)
      scalar_registry[graphql_name.to_s] =
        ScalarType.new(graphql_name, type, cast:, serialize:, requires:, coerce:)
    end

    # The ScalarType for a scalar name; unknown scalars fall back to an
    # untyped pass-through (T.untyped, no cast) — the prior behavior for
    # scalars outside the table.
    def scalar(graphql_name)
      scalar_registry.fetch(graphql_name.to_s) do
        ScalarType.new(graphql_name, "T.untyped")
      end
    end

    def scalar_registry
      @scalar_registry ||= {}
    end

    # Empty the registry entirely, built-ins included. Mostly useful for
    # tests; see reset_scalars! to restore the built-in defaults.
    def clear_scalars!
      scalar_registry.clear
      self
    end

    # Drop every custom registration and restore the built-in scalars — the
    # clean slate to reach for between tests, or to undo overrides. (Want
    # the built-ins to coerce loose input? That's GraphWeaver.auto_coerce,
    # resolved at generation time — no re-registering.)
    def reset_scalars!
      clear_scalars!
      register_builtin_scalars!
      self
    end

    # Built-in scalars — pre-registered entries in the one registry. The
    # standard scalars stay pass-through: their Ruby classes (String,
    # Integer, Float) define neither .parse nor .load, so codec inference
    # matches nothing and leaves them identity — which is exactly why we
    # can name them with the real class constants. Date deserializes via
    # ISO-8601 (it *does* define .parse, but we want iso8601 specifically,
    # so it's explicit). Input coercion is a generation-time concern:
    # GraphWeaver.auto_coerce gives the convertible built-ins their
    # conversion (see ScalarType::AUTO_CONVERSIONS).
    def register_builtin_scalars!
      register_scalar "ID", String
      register_scalar "String", String
      register_scalar "Int", Integer
      register_scalar "Float", Float
      register_scalar "Boolean", "T::Boolean"
      register_scalar "Date", Date, cast: :iso8601, serialize: :iso8601, requires: "date"
    end
  end

  register_builtin_scalars!
end
