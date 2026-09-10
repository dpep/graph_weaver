# typed: true
# frozen_string_literal: true

require "date"

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

    # A scalar with no `cast:` to run input through: its Ruby type is the
    # whole rule, so key on that — a custom scalar registered as a plain
    # String gets the same check. ID is the exception GraphQL itself names
    # (see Coerce.id), matched by GraphQL name in #coercer.
    COERCERS = {
      "Integer" => "integer",
      "Float" => "float",
      "String" => "string",
      "T::Boolean" => "boolean",
    }.freeze
    private_constant :Codec, :CODECS, :COERCERS

    attr_reader :graphql_name, :type, :requires

    def initialize(graphql_name, type, cast: nil, serialize: nil, requires: nil, fake: nil)
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
      @fake = fake
      validate_fake!
    end

    def cast(expr) = @cast&.call(expr)
    def cast? = !@cast.nil?
    def serialize(expr) = @serialize&.call(expr)
    def serialize? = !@serialize.nil?
    def coerce? = !coerce_input("v").nil?
    def fake? = !@fake.nil?

    # The wire value the testing harness fabricates for this scalar. Only the
    # registration can know one: an app class's `cast` accepts whatever its
    # author decided it accepts. A proc is handed the seeded Random, so a
    # varying fake still reproduces under `rspec --seed`.
    def fake(rng)
      return @fake unless @fake.is_a?(Proc)

      @fake.arity.zero? ? @fake.call : @fake.call(rng)
    end

    # The code that normalizes a loose input — a Rails param — into this
    # scalar's Ruby type before it is serialized, or nil for nothing to do.
    # `cast:` is the how: it already knows how to build the Ruby object from
    # a wire value, guarded so an already-typed value passes through. A
    # scalar without one falls back to its Ruby type's check, which is what
    # `.checked(:never)` on the generated sig gives up.
    def coerce_input(expr)
      if cast?
        "(#{expr}.is_a?(#{@type}) ? #{expr} : #{cast(expr)})"
      elsif (fn = coercer)
        "GraphWeaver::Coerce.#{fn}(#{expr})"
      end
    end

    private

    def coercer
      return "id" if @graphql_name == "ID" && @type == "String"

      COERCERS[@type]
    end

    def type_name(type)
      case type
      when Module
        # an anonymous class has no name to emit — it would land as a literal
        # `nil` in generated source
        type.name || raise(ArgumentError, "type: must be a named class/module, got an anonymous one")
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

    # With only a type-name string we can't assume the lib is installed at
    # codegen time, so the paths aren't loaded — only shape-checked.
    def normalize_requires(requires)
      GraphWeaver::Codegen.normalize_requires!(requires, load: !@klass.nil?)
    end

    # A proc taking anything else can't be called at fabrication time, and
    # the ArgumentError it would raise there names no scalar.
    def validate_fake!
      return unless @fake.is_a?(Proc) && @fake.arity > 1

      raise ArgumentError, "fake: takes no arguments, or one — the seeded Random " \
        "(fake: ->(rng) { ... }); #{@graphql_name}'s takes #{@fake.arity}"
    end
  end

  class << self
    # requires: is a require path or list of them; each must be a non-empty
    # String (it is emitted verbatim as `require "..."` atop the generated
    # file), caught here rather than as a syntax error in the generated file.
    # load: when the registration handed us live constants — a class, a T::Enum,
    # a helper module — we're in a runtime with its deps loaded, so each path is
    # required to prove it resolves: a typo fails now, not in the generated file
    # (a no-op for already-loaded libs).
    def normalize_requires!(requires, load:)
      Array(requires).each do |req|
        unless req.is_a?(String) && !req.empty?
          raise ArgumentError, "requires: must be a String or Array of Strings, got #{req.inspect}"
        end

        next unless load

        begin
          require req
        rescue LoadError => e
          raise ArgumentError, "requires: #{req.inspect} is not loadable (#{e.message})"
        end
      end
    end

    # Register (or override) how a GraphQL custom scalar deserializes into
    # a Ruby object and serializes back onto the wire. See ScalarType for
    # the accepted cast:/serialize:/requires: forms. Later registrations
    # win, so an app can override a built-in (e.g. map Date onto its own
    # type).
    def register_scalar(graphql_name, type, cast: nil, serialize: nil, requires: nil, fake: nil)
      scalar_registry[graphql_name.to_s] =
        ScalarType.new(graphql_name, type, cast:, serialize:, requires:, fake:)
    end

    # The ScalarType in play for a scalar, most specific first: the
    # `Type.field` registration when `coordinate` names one, then the
    # scalar-name registration. Unknown scalars fall back to an untyped
    # pass-through (T.untyped, no cast) — the prior behavior for scalars
    # outside the table.
    def scalar(graphql_name, coordinate = nil)
      (coordinate && scalar_registry[coordinate.to_s]) ||
        scalar_registry.fetch(graphql_name.to_s) { ScalarType.new(graphql_name, "T.untyped") }
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
    # clean slate to reach for between tests, or to undo overrides.
    def reset_scalars!
      clear_scalars!
      register_builtin_scalars!
      self
    end

    # Built-in scalars — pre-registered entries in the one registry. Most stay
    # pass-through: their Ruby classes (String, Integer) define neither .parse
    # nor .load, so codec inference matches nothing and leaves them identity —
    # which is exactly why we can name them with the real class constants.
    # Float is the exception: JSON has one number type, so a whole Float
    # arrives as `1` from every encoder that drops the trailing zero
    # (graphql-js and Go both do), and Coerce.float widens that without
    # accepting the garbage `.to_f` would silently turn into 0.0. Date
    # deserializes via ISO-8601 (it *does* define .parse, but we want iso8601
    # specifically, so it's explicit). The rest carry no cast and coerce
    # input by their Ruby type — see coerce_input.
    def register_builtin_scalars!
      register_scalar "ID", String
      register_scalar "String", String
      register_scalar "Int", Integer
      register_scalar "Float", Float, cast: ->(expr) { "GraphWeaver::Coerce.float(#{expr})" }
      register_scalar "Boolean", "T::Boolean"
      register_scalar "Date", Date, cast: :iso8601, serialize: :iso8601, requires: "date"
    end
    private :register_builtin_scalars!
  end

  # codegen's own record of a registration; users get one back from
  # `.scalar` but never name the class
  private_constant :ScalarType

  register_builtin_scalars!

  # Pre-registered rather than user intent, so generation doesn't hold a schema
  # to them (validate_registration! skips these). Read off the registry the line
  # above just filled: a seventh built-in shouldn't have to be named twice.
  BUILTIN_SCALARS = scalar_registry.keys.freeze
end
