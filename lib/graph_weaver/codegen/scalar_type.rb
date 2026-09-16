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
  # return the code to inline. Left nil (the default) they are inferred from
  # the Ruby type: a type the library already knows takes its codec from
  # STDLIB, otherwise it is probed for a known deserializer whose serializer
  # pairs with it (see CODECS), and failing that for a Kernel conversion
  # function of its own name — so the common case needs no more than a class:
  #      type: BigDecimal (Kernel#BigDecimal) => BigDecimal(expr) / expr.to_s("F")
  #      type: Money   (defines .parse)   => Money.parse(expr) / expr.to_s
  #      type: Blob    (defines .load)    => Blob.load(expr)   / Blob.dump(expr)
  # Probing the *deserialize* side is deliberate: every object has #to_s,
  # so inferring a serializer off it would wrongly wrap plain types (String,
  # Integer) — pairing off a deserializer the type actually defines avoids
  # that. Override with an explicit value:
  #   - a Symbol names a method, so there is no string to misspell:
  #           cast: :load        => "Blob.load(expr)"    (class method on type)
  #           serialize: :to_json => "expr.to_json"      (instance method)
  #   - an Array is that method with arguments: serialize: [:to_s, "F"]
  #   - a Proc handles anything a Symbol can't express:
  #           cast: ->(e) { "Money.new(#{e})" }
  #   - :itself opts out — force identity pass-through even when a codec
  #     would otherwise match (rare)
  # requires: a String or Array of paths emitted as `require`s atop the
  # generated file (e.g. "bigdecimal") so the cast/type resolve.
  class ScalarType
    # Inferred (deserialize, serialize) codecs, tried in order; the first
    # whose probe the Ruby type defines as a class method wins, and its
    # serialize is paired with it. Builders take (type_name, expr) => code;
    # `call` is the same serialization run rather than emitted, for the
    # testing harness (see #serialize_value).
    Codec = Struct.new(:probe, :cast, :serialize, :call)
    CODECS = [
      Codec.new(:parse, # Type.parse(wire) <-> value.to_s
        ->(type, expr) { "#{type}.parse(#{expr})" },
        ->(_type, expr) { "#{expr}.to_s" },
        ->(_klass, value) { value.to_s }),
      Codec.new(:load, # Type.load(wire) <-> Type.dump(value)
        ->(type, expr) { "#{type}.load(#{expr})" },
        ->(type, expr) { "#{type}.dump(#{expr})" },
        ->(klass, value) { klass.dump(value) }),
    ].freeze

    # A scalar whose registration named no `cast:` of its own: its Ruby type
    # is the whole rule, so key on that — a custom scalar registered as a
    # plain String gets the same check. ID is the exception GraphQL itself
    # names (see Coerce.id), matched by GraphQL name in #coercer.
    COERCERS = {
      "Integer" => "integer",
      "Float" => "float",
      "String" => "string",
      "T::Boolean" => "boolean",
      "Date" => "date",
      "Time" => "time",
    }.freeze

    # What the library already knows about a Ruby type, so registering one
    # takes nothing but the class. Consulted only where the registration is
    # silent; an explicit cast:/serialize:/requires: wins. Two things the
    # probe above can't work out on its own:
    #   - the wire spelling. BigDecimal#to_s writes "0.125e2", which is not
    #     what any server means by 12.5, and Date.parse reads a great deal
    #     more than the ISO 8601 a Date scalar carries.
    #   - the file to require, so the generated source stands alone.
    # Only types whose wire form is unambiguous belong here.
    #
    # `call:` is the runnable twin of a Proc `serialize:`, which builds source
    # and so can't be run — the testing harness needs both (see
    # #serialize_value).
    TIMESTAMP = ->(expr) { "GraphWeaver::Coerce.timestamp(#{expr})" }
    TIMESTAMP_CALL = ->(value) { GraphWeaver::Coerce.timestamp(value) }

    STDLIB = {
      "BigDecimal" => { serialize: [:to_s, "F"], requires: "bigdecimal" },
      # JSON has one number type, so a whole Float arrives as `1` from every
      # encoder that drops the trailing zero (graphql-js and Go both do)
      "Float" => { cast: ->(expr) { "GraphWeaver::Coerce.float(#{expr})" } },
      # strftime, not #iso8601: DateTime < Date passes the is_a? guard, and its
      # #iso8601 writes a timestamp where the schema said a date goes
      "Date" => { cast: :iso8601, serialize: [:strftime, "%F"], requires: "date" },
      # Time.iso8601, not Time.parse: the latter also reads "Jan 15 2024
      # 10:20", which no spec-compliant server writes, at 3× the cost.
      # Writing back goes through Coerce.timestamp rather than #iso8601,
      # which takes no precision — a sub-second timestamp would go out
      # poorer than it came in.
      "Time" => { cast: :iso8601, serialize: TIMESTAMP, call: TIMESTAMP_CALL, requires: "time" },
      "DateTime" => { cast: :iso8601, serialize: TIMESTAMP, call: TIMESTAMP_CALL, requires: "date" },
    }.freeze

    # Everything JSON.parse can hand back. A registered type outside this set
    # has to be BUILT from one of them, which is what a cast is for (and what
    # Codegen#refuse_uncastable! insists on).
    WIRE_CLASSES = [String, Integer, Float, Hash, Array, TrueClass, FalseClass].freeze

    private_constant :Codec, :CODECS, :COERCERS, :STDLIB

    attr_reader :graphql_name, :type, :requires

    def initialize(graphql_name, type, cast: nil, serialize: nil, requires: nil)
      @graphql_name = graphql_name.to_s
      @klass = type.is_a?(Module) ? type : nil
      @type = type_name(type)
      known = STDLIB[@type] || {}
      # requires: load BEFORE probing — the deserializer may arrive with the
      # file (core Time has no .parse until the "time" stdlib loads, and
      # Kernel#BigDecimal none until "bigdecimal" does). A path from STDLIB
      # is the library's own, so it loads even for a type: given as a String,
      # whose dependency we otherwise can't assume is installed.
      @requires =
        if requires.nil?
          GraphWeaver::Codegen.normalize_requires!(known[:requires], load: true)
        else
          GraphWeaver::Codegen.normalize_requires!(requires, load: !@klass.nil?)
        end
      @cast_given = cast unless cast == :itself
      codec = @klass && CODECS.find { |c| @klass.respond_to?(c.probe) }
      @cast = normalize_cast(cast || known[:cast], codec&.cast || kernel_cast)
      @serialize = normalize_serialize(serialize || known[:serialize], codec&.serialize)
      @serialize_value = (known[:call] if serialize.nil?) ||
        runtime_serialize(serialize || known[:serialize], codec)
      warn_half_a_value_object
      warn_half_a_codec(serialize)
    end

    def cast(expr) = @cast&.call(expr)
    def cast? = !@cast.nil?
    def serialize(expr) = @serialize&.call(expr)
    def serialize? = !@serialize.nil?
    def coerce? = !coerce_input("v").nil?

    # #serialize run rather than emitted: the wire value for a Ruby one. The
    # testing harness reads app objects — a Time, a Money — off an object pin
    # and has to write what the server would. A `serialize:` proc builds code
    # and can't be run, so its value passes through and the cast complains.
    def serialize_value(value)
      return value if value.nil? || @serialize_value.nil?

      @serialize_value.call(value)
    end

    # Whether #serialize_value actually runs this registration's serializer,
    # rather than passing the value through for want of one to run.
    def serialize_value? = !@serialize_value.nil?

    # The code that normalizes a loose input — a Rails param — into this
    # scalar's Ruby type before it is serialized, or nil for nothing to do.
    # The Ruby type's own rule in Coerce is the check, which is what
    # `.checked(:never)` on the generated sig gives up. A registration that
    # named its own `cast:` says how to build the Ruby object instead — but
    # the guard in front of it and the verdict when it refuses are still the
    # library's, so both go through Coerce.cast rather than a bare `is_a?`
    # (a DateTime is one of those, and is not a Date on any wire).
    # The schema's name for the scalar travels with the value, so a refusal
    # reports GraphQL vocabulary rather than the Ruby type it maps to —
    # register_scalar("Money", BigDecimal) refuses a Money, not a BigDecimal.
    def coerce_input(expr)
      if (fn = coercer)
        "GraphWeaver::Coerce.#{fn}(#{expr}, #{@graphql_name.inspect})"
      elsif cast?
        "GraphWeaver::Coerce.cast(#{@type}, #{expr}, #{@graphql_name.inspect}) { |raw| #{cast("raw")} }"
      end
    end

    # Why this registration can't read the JSON at `where`, and what to do about
    # it. Two different mistakes land here, so say which: a type: given by name
    # was never probed (there is no class in hand to probe), while a class was
    # probed and matched nothing. Raised by Codegen#refuse_uncastable!, which
    # owns the question of whether the wire could satisfy the prop at all.
    def uncastable_message(where)
      article = GraphWeaver::Internal::Util.article(@type)
      head = "register_scalar(#{@graphql_name.inspect}, #{@klass ? @type : @type.inspect}) has no " \
        "cast, so nothing builds #{article} #{@type} out of the JSON at #{where}"
      if @klass.nil?
        "#{head} — a type: given by name is never probed, since there is no class in hand. Pass " \
          "the class (register_scalar(#{@graphql_name.inspect}, #{@type})) to infer a cast from " \
          "it, or name one yourself (cast: :parse names a class method, " \
          "cast: ->(v) { \"#{@type}.parse(\#{v})\" } emits any expression)"
      else
        "#{head} — #{@type} defines no .parse and no .load, and Kernel has no #{@type} conversion " \
          "function, so there was nothing to infer. Give it a cast (cast: :parse names a class " \
          "method, cast: ->(v) { \"#{@type}.new(\#{v})\" } emits any expression), or register a " \
          "type the wire already parses into"
      end
    end

    private

    # A result compares its props with eql?, so that it and #hash agree on what
    # "same" means. A type that leaves eql? at Object's compares by identity,
    # so two results parsed from the same bytes are unequal and useless as hash
    # keys — whether it defined == (the common Ruby idiom, and the leaf itself
    # then compares fine) or no equality at all. Nothing here can fix that;
    # only the type can.
    def warn_half_a_value_object
      # a Module type names a duck the gem never sees an instance of; a T::Enum's
      # values are singletons, so identity already is equality
      return unless @klass.is_a?(Class) && !(@klass < T::Enum) && !defines?(:eql?)

      GraphWeaver::Internal::Log.log(:warn) do
        "register_scalar(#{@graphql_name.inspect}, #{@type}): #{@type} inherits #eql? and #hash, " \
          "so its instances compare by identity — two results parsed from the same response won't " \
          "be equal and a result won't work as a hash key — define ==, eql? and hash off the same " \
          "values (alias_method :eql?, :== is the usual shortcut)"
      end
    end

    # The other half of the same rule: a registration says both directions or
    # is told what it can't do. A cast with nothing to write back reads the
    # wire and can't put a variable of that scalar onto it, and a result's
    # #as_json can't reproduce what the server sent — both silent, since
    # `#to_json` answers for any object.
    def warn_half_a_codec(serialize)
      # nothing said and nothing inferred: `serialize: :itself` said it, and a
      # Ruby type JSON already holds has no other half to name
      return if !cast? || serialize? || !serialize.nil? || json_shaped?

      GraphWeaver::Internal::Log.log(:warn) do
        "register_scalar(#{@graphql_name.inspect}, #{@klass ? @type : @type.inspect}): cast: reads " \
          "#{GraphWeaver::Internal::Util.article(@type)} #{@type} off the wire and nothing writes one " \
          "back — a #{@graphql_name} variable goes out as whatever #to_json makes of it, and a result's " \
          "#as_json can't reproduce what the server sent. Name the other half (serialize: :to_s names an " \
          "instance method, serialize: [:to_s, \"F\"] passes it arguments, " \
          "serialize: ->(v) { \"\#{v}.to_s\" } emits any expression), or serialize: :itself if the value " \
          "really does go out as it is"
      end
    end

    # A Ruby type JSON already holds writes itself, subclasses included
    def json_shaped? = !@klass.nil? && WIRE_CLASSES.any? { |native| @klass <= native }

    def defines?(method)
      ![BasicObject, Kernel, Object].include?(@klass.instance_method(method).owner)
    end

    def coercer
      # a cast: the registration named is the whole rule (:itself asks for
      # no rich object, which is not the same as asking for no check)
      return unless @cast_given.nil?
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

    # Kernel's conversion functions are how a wire value becomes one of these
    # — BigDecimal defines neither .parse nor .load, but Kernel#BigDecimal has
    # read a decimal string all along. Only for a type the wire can't already
    # be: Kernel#String and Kernel#Array wrap a value rather than convert it.
    def kernel_cast
      return unless Kernel.private_method_defined?(@type.to_sym)
      return if WIRE_CLASSES.any? { |native| native.name == @type }

      ->(type, expr) { "#{type}(#{expr})" }
    end

    # A Proc here builds SOURCE for the generated file, so a proc that
    # converts a value (`->(v) { v.to_sym }`) can't work — it interpolates to
    # nothing and every response fails far from the registration. Probe it
    # once now, where the message can name the spelling.
    def source_builder!(option, proc)
      probe = proc.arity.zero? ? proc.call : proc.call("v")
      return proc if probe.is_a?(String)

      raise ArgumentError, "#{option}: a Proc must return the Ruby source to emit — " \
        "e.g. #{option}: ->(v) { \"#{@type}.parse(\#{v})\" } — got #{probe.inspect}; " \
        "a Symbol names a method instead (#{option}: :parse)"
    rescue ArgumentError => e
      raise if e.message.start_with?("#{option}:")

      raise ArgumentError, "#{option}: a Proc takes one argument, the expression to wrap — #{e.message}"
    end

    # nil infers via the matched codec; :itself opts out (identity); a
    # Symbol is a class method on the type — Money.parse(expr)
    def normalize_cast(cast, inferred)
      case cast
      when :itself then nil
      when nil then inferred && ->(expr) { inferred.call(@type, expr) }
      when Proc then source_builder!(:cast, cast)
      when Symbol then ->(expr) { "#{@type}.#{cast}(#{expr})" }
      else raise ArgumentError, "cast: must be a Symbol, Proc, :itself, or nil, got #{cast.inspect}"
      end
    end

    # nil infers via the matched codec; :itself opts out (identity); a Symbol
    # is an instance method on the value — expr.to_s — and an Array is that
    # method with arguments: [:to_s, "F"] => expr.to_s("F")
    def normalize_serialize(serialize, inferred)
      case serialize
      when :itself then nil
      when nil then inferred && ->(expr) { inferred.call(@type, expr) }
      when Proc then source_builder!(:serialize, serialize)
      when Symbol then ->(expr) { "#{expr}.#{serialize}" }
      when Array
        method, *args = serialize
        unless method.is_a?(Symbol)
          # a syntax error in the generated file otherwise
          raise ArgumentError, "serialize: an Array is [method, *arguments], got #{serialize.inspect}"
        end

        ->(expr) { "#{expr}.#{method}(#{args.map(&:inspect).join(", ")})" }
      else raise ArgumentError, "serialize: must be a Symbol, Array, Proc, :itself, or nil, got #{serialize.inspect}"
      end
    end

    # The runnable half of normalize_serialize: a Symbol (or Symbol with
    # arguments) names a method — :itself included, which is identity either
    # way — an inferred codec knows its own call, and a Proc emits code there
    # is no way to run.
    def runtime_serialize(serialize, codec)
      case serialize
      when Symbol, Array then ->(value) { value.public_send(*serialize) }
      when nil then codec && ->(value) { codec.call.call(@klass, value) }
      end
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
  end

  # The scalar half of one graph's registrations — see Codegen::Registry.
  class Registry
    # Register (or override) how a GraphQL custom scalar deserializes into
    # a Ruby object and serializes back onto the wire. See ScalarType for
    # the accepted cast:/serialize:/requires: forms. Later registrations
    # win, so an app can override a built-in (e.g. map Date onto its own
    # type).
    def register_scalar(graphql_name, type, cast: nil, serialize: nil, requires: nil)
      scalar_registry[graphql_name.to_s] =
        ScalarType.new(graphql_name, type, cast:, serialize:, requires:)
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

    # Pre-registered scalars — ordinary entries in the one registry, so a
    # later register_scalar overrides any of them.
    #
    # The five the spec names stay pass-through: their Ruby classes (String,
    # Integer) define neither .parse nor .load, so inference matches nothing
    # and leaves them identity — which is exactly why we can name them with
    # the real class constants. Float is the exception, and its rule lives in
    # STDLIB with the others, so `register_scalar "Ratio", Float` reads the
    # wire exactly as the built-in Float does.
    #
    # The rest are names, not guesses: graphql-ruby ships all but DateTime as
    # its own scalars, and this library runs a graphql-ruby schema in-process.
    # DateTime is what GitHub, Shopify and most hand-written schemas call an
    # ISO 8601 timestamp; a schema that means something else by it fails
    # loudly (the cast raises, naming the field) and is one register_scalar
    # away. Date and datetime are told apart by their Ruby type — a Date cast
    # to Time would invent a midnight the server never sent.
    def register_builtin_scalars!
      register_scalar "ID", String
      register_scalar "String", String
      register_scalar "Int", Integer
      register_scalar "Float", Float
      register_scalar "Boolean", "T::Boolean"
      register_scalar "Date", Date
      register_scalar "ISO8601Date", Date
      register_scalar "ISO8601DateTime", Time
      register_scalar "DateTime", Time
      # graphql-ruby writes a BigInt as a string, since JSON numbers stop
      # being exact at 2^53 — so read either spelling and write the one the
      # server does.
      register_scalar "BigInt", Integer,
        cast: ->(expr) { "GraphWeaver::Coerce.integer(#{expr})" }, serialize: :to_s
      # untyped on purpose: registering it says so, rather than leaving JSON
      # in the "unregistered custom scalars" report every generation
      register_scalar "JSON", "T.untyped"
      # the objects, not the names: a later register_scalar("DateTime", ...)
      # replaces the entry, and that is app intent rather than a pre-registration
      @builtin_entries = scalar_registry.values.freeze
    end
    private :register_builtin_scalars!

    # Whether this name still holds the entry pre-registration put there.
    def builtin_scalar?(name)
      entry = scalar_registry[name]
      @builtin_entries.any? { |builtin| builtin.equal?(entry) }
    end
  end

  # codegen's own record of a registration; users get one back from
  # `.scalar` but never name the class
  private_constant :ScalarType
end
