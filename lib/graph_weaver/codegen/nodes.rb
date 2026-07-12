# typed: true
# frozen_string_literal: true

# The typed intermediate representation of a query selection: one node
# per GraphQL type shape, each knowing its Sorbet prop type and the
# cast/serialize code to emit.
class GraphWeaver::Codegen
  class Scalar
    # takes a resolved ScalarType — the generator picks it from the
    # client-scoped overlay or the global registry
    def initialize(scalar_type)
      @scalar = scalar_type
    end

    def bare_type
      @scalar.type
    end

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, _depth)
      @scalar.cast(expr)
    end

    def identity?
      !@scalar.cast?
    end

    def serialize(expr, _depth)
      @scalar.serialize(expr)
    end

    def serialize_identity?
      !@scalar.serialize?
    end

    # coercion (opt-in per scalar): accept the value or its raw input and
    # normalize before serializing — parse for a rich type (coerce: true),
    # or a plain conversion for built-ins (coerce: :to_f). See ScalarType.
    def coerce? = @scalar.coerce?
    def coerce(expr) = @scalar.coerce_input(expr)
    def coerce_input_type = @scalar.coerce_type

    # inside input-struct hashes, scalars coerce exactly like variable
    # kwargs do — the registry (incl. GraphWeaver.auto_coerce) decides
    def hash_coerce(expr, _depth)
      @scalar.coerce_input(expr) || expr
    end

    def hash_coerce_identity? = !@scalar.coerce?

    def non_null? = false
    def nested = nil
  end

  class NonNull
    attr_reader :of

    def initialize(of)
      @of = of
    end

    def bare_type = @of.bare_type
    def prop_type = bare_type
    def cast(expr, depth) = @of.cast(expr, depth)
    def identity? = @of.identity?
    def serialize(expr, depth) = @of.serialize(expr, depth)
    def serialize_identity? = @of.serialize_identity?
    def coerce? = @of.coerce?
    def coerce(expr) = @of.coerce(expr)
    def coerce_input_type = @of.coerce_input_type
    def hash_coerce(expr, depth) = @of.hash_coerce(expr, depth)
    def hash_coerce_identity? = @of.hash_coerce_identity?
    def non_null? = true
    def nested = @of.nested
  end

  class List
    def initialize(of)
      @of = of
    end

    def bare_type
      "T::Array[#{@of.prop_type}]"
    end

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, depth)
      var = "v#{depth}"
      element = if @of.non_null? || @of.identity?
        @of.identity? ? var : @of.cast(var, depth + 1)
      else
        "#{var}&.then { |v#{depth + 1}| #{@of.cast("v#{depth + 1}", depth + 2)} }"
      end

      "#{expr}.map { |#{var}| #{element} }"
    end

    def identity? = @of.identity?

    def serialize(expr, depth)
      var = "v#{depth}"
      element = if @of.non_null? || @of.serialize_identity?
        @of.serialize_identity? ? var : @of.serialize(var, depth + 1)
      else
        "#{var}&.then { |v#{depth + 1}| #{@of.serialize("v#{depth + 1}", depth + 2)} }"
      end

      "#{expr}.map { |#{var}| #{element} }"
    end

    def serialize_identity? = @of.serialize_identity?
    def coerce? = false

    def hash_coerce(expr, depth)
      var = "v#{depth}"
      inner = if @of.non_null? || @of.hash_coerce_identity?
        @of.hash_coerce_identity? ? var : @of.hash_coerce(var, depth + 1)
      else
        "#{var}.nil? ? nil : #{@of.hash_coerce(var, depth + 1)}"
      end

      "#{expr}.map { |#{var}| #{inner} }"
    end

    def hash_coerce_identity? = @of.hash_coerce_identity?
    def non_null? = false
    def nested = @of.nested
  end

  class ObjectNode
    Field = Struct.new(:prop, :key, :node)

    attr_reader :class_name, :fields
    # the GraphQL type this struct was generated from, and any registered
    # helper modules to include (see Codegen.register_type)
    attr_accessor :graphql_type, :mixins

    def initialize(class_name)
      @class_name = class_name
      @fields = []
      @mixins = []
    end

    def bare_type = class_name

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, _depth)
      "#{class_name}.from_h(#{expr})"
    end

    def identity? = false
    def non_null? = false
    def nested = self
  end

  class EnumNode
    attr_reader :class_name, :values

    def initialize(class_name, values)
      @class_name = class_name
      @values = values
    end

    def bare_type = class_name

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, _depth)
      "#{class_name}.deserialize(#{expr})"
    end

    def identity? = false

    def serialize(expr, _depth)
      "#{expr}.serialize"
    end

    def serialize_identity? = false

    # enums always coerce: a kwarg or hash field accepts the T::Enum or
    # its wire value (deserialize raises on anything else)
    def coerce? = true

    def coerce(expr)
      "(#{expr}.is_a?(#{class_name}) ? #{expr} : #{class_name}.deserialize(#{expr}))"
    end

    def coerce_input_type = "T.any(#{class_name}, String)"
    def hash_coerce(expr, _depth) = coerce(expr)
    def hash_coerce_identity? = false
    def non_null? = false
    def nested = self
  end

  # A GraphQL enum mapped onto an app-owned T::Enum (see EnumType): no
  # generated enum class — instead module-level <NAME>_FROM_WIRE /
  # <NAME>_TO_WIRE constants translate at the boundary. fallback: makes
  # casting absorb unknown wire values (inputs stay strict).
  class MappedEnum
    attr_reader :graphql_name, :mapping

    def initialize(enum_type, wire_values)
      @graphql_name = enum_type.graphql_name
      @type_name = enum_type.type.name
      @fallback = enum_type.fallback
      @mapping = enum_type.mapping_for(wire_values)
    end

    def const_prefix = GraphWeaver::Inflect.underscore(@graphql_name).upcase
    def fallback_const = @fallback && "#{@type_name}.deserialize(#{@fallback.serialize.to_s.inspect})"

    def bare_type = @type_name

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, _depth)
      if @fallback
        "#{const_prefix}_FROM_WIRE.fetch(#{expr}) { #{fallback_const} }"
      else
        "#{const_prefix}_FROM_WIRE.fetch(#{expr})"
      end
    end

    def identity? = false

    def serialize(expr, _depth)
      "#{const_prefix}_TO_WIRE.fetch(#{expr})"
    end

    def serialize_identity? = false

    # kwargs and hash fields accept the member or its wire value; unlike
    # casting, bad input raises even with a fallback (a typo'd input is
    # our bug, not server drift)
    def coerce? = true

    def coerce(expr)
      "(#{expr}.is_a?(#{@type_name}) ? #{expr} : #{const_prefix}_FROM_WIRE.fetch(#{expr}))"
    end

    def coerce_input_type = "T.any(#{@type_name}, String)"
    def hash_coerce(expr, _depth) = coerce(expr)
    def hash_coerce_identity? = false
    def non_null? = false
    def nested = nil
  end

  # A single-condition narrowing of an abstract field (`... on Pet { ... }`
  # and nothing else): the member struct when the runtime type matches,
  # nil when it doesn't — a non-match's response object carries no
  # matching fields, so the hash arrives empty. Always nilable, whatever
  # the schema's nullability, because narrowing filters.
  class NarrowedNode
    def initialize(of)
      @of = of
    end

    def class_name = @of.class_name
    def bare_type = @of.bare_type

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, depth)
      "(#{expr}.empty? ? nil : #{@of.cast(expr, depth)})"
    end

    def identity? = false
    def non_null? = false
    def nested = @of
  end

  class UnionNode
    attr_reader :class_name, :members # graphql type name => ObjectNode

    def initialize(class_name, members)
      @class_name = class_name
      @members = members
    end

    def bare_type = "#{class_name}::Type"

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def cast(expr, _depth)
      "#{class_name}.from_h(#{expr})"
    end

    def identity? = false
    def non_null? = false
    def nested = self
  end

  # An input-object variable: emitted as a module-level T::Struct whose
  # serialize produces the wire hash. Inputs never cast FROM the wire.
  # Joins the coerce protocol so execute kwargs accept plain hashes,
  # normalized (and type-checked) through the generated .coerce.
  class InputNode
    Field = Struct.new(:prop, :wire, :node, :required)

    attr_reader :class_name, :fields

    def initialize(class_name)
      @class_name = class_name
      @fields = []
    end

    def bare_type = class_name

    def prop_type
      "T.nilable(#{bare_type})"
    end

    def serialize(expr, _depth)
      "#{expr}.serialize"
    end

    def serialize_identity? = false

    def cast(_expr, _depth)
      raise NotImplementedError, "input objects are never cast from responses"
    end

    def coerce? = true
    def coerce(expr) = "#{class_name}.coerce(#{expr})"
    def coerce_input_type = "T.any(#{class_name}, T::Hash[T.untyped, T.untyped])"

    # building a struct field from a caller-supplied plain hash value
    def hash_coerce(expr, _depth) = "#{class_name}.coerce(#{expr})"
    def hash_coerce_identity? = false

    def identity? = false
    def non_null? = false
    def nested = nil
  end
end
