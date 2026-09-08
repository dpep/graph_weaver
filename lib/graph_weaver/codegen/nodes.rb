# typed: true
# frozen_string_literal: true

require "forwardable"

# The typed intermediate representation of a query selection: one node
# per GraphQL type shape, each knowing its Sorbet prop type and the
# cast/serialize code to emit.
class GraphWeaver::Codegen
  # Protocol defaults — subclasses override what differs. The full node
  # protocol: bare_type, prop_type, cast(expr, depth), identity?,
  # serialize(expr, depth), serialize_identity?, coerce?, coerce(expr),
  # coerce_input_type, hash_coerce(expr, depth), hash_coerce_identity?,
  # non_null?, nested.
  class Node
    def bare_type = raise(GraphWeaver::Error, "#{self.class} must define bare_type")
    def prop_type = "T.nilable(#{bare_type})"
    def identity? = false
    def serialize_identity? = false
    def coerce? = false
    def hash_coerce_identity? = false
    def non_null? = false
    def nested = nil
  end

  class Scalar < Node
    # takes a resolved ScalarType — the generator picks it from the
    # client-scoped overlay or the global registry
    def initialize(scalar_type)
      @scalar = scalar_type
    end

    def bare_type
      @scalar.type
    end

    def prop_type
      # unregistered scalars are already T.untyped — wrapping in
      # T.nilable is redundant and an srb tc error under typed: strict
      bare_type == "T.untyped" ? bare_type : "T.nilable(#{bare_type})"
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

    # coercion (coerce: per scalar, or GraphWeaver.auto_coerce for all):
    # accept the value or its raw input and normalize before serializing.
    # See ScalarType#coercion.
    def coerce? = @scalar.coerce?
    def coerce(expr) = @scalar.coerce_input(expr)
    def coerce_input_type = @scalar.coerce_type

    # inside input-struct hashes, scalars coerce exactly like variable
    # kwargs do — the registry (incl. GraphWeaver.auto_coerce) decides
    def hash_coerce(expr, _depth)
      @scalar.coerce_input(expr) || expr
    end

    def hash_coerce_identity? = !@scalar.coerce?
  end

  # NonNull is its inner node with the nilability stripped — everything
  # else passes through.
  class NonNull < Node
    extend Forwardable

    attr_reader :of

    def_delegators :@of, :bare_type, :cast, :identity?, :serialize, :serialize_identity?,
      :coerce?, :coerce, :coerce_input_type, :hash_coerce, :hash_coerce_identity?, :nested

    def initialize(of)
      @of = of
    end

    def prop_type = bare_type
    def non_null? = true
  end

  class List < Node
    attr_reader :of

    def initialize(of)
      @of = of
    end

    def bare_type
      "T::Array[#{@of.prop_type}]"
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

    # A list coerces exactly as its elements do, per element: `sort: ["POPULARITY_DESC"]`
    # has to accept a wire string the way `type: "ANIME"` does. Sorbet's runtime
    # doesn't check element types, so without this a String reached .serialize
    # and raised a NoMethodError naming neither the variable nor the enum.
    def coerce? = !hash_coerce_identity?
    def coerce(expr) = hash_coerce(expr, 1)

    def coerce_input_type
      element = @of.coerce? ? @of.coerce_input_type : @of.prop_type
      element = "T.nilable(#{element})" if @of.coerce? && !@of.non_null? && element != "T.untyped"
      "T::Array[#{element}]"
    end

    def hash_coerce(expr, depth)
      var = "v#{depth}"
      inner = if @of.non_null? || @of.hash_coerce_identity?
        @of.hash_coerce_identity? ? var : @of.hash_coerce(var, depth + 1)
      else
        "#{var}&.then { |v#{depth + 1}| #{@of.hash_coerce("v#{depth + 1}", depth + 2)} }"
      end

      "#{expr}.map { |#{var}| #{inner} }"
    end

    def hash_coerce_identity? = @of.hash_coerce_identity?
    def nested = @of.nested
  end

  class ObjectNode < Node
    Field = Struct.new(:prop, :key, :node)
    # a resolved alias delegator (extend_type alias:): the accessor name, the
    # Ruby path expression it reads (meta&.tag), and its Sorbet return type
    Alias = Struct.new(:name, :expr, :type)

    attr_reader :class_name, :fields
    # the GraphQL type this struct was generated from, any registered helper
    # modules to include, and any resolved alias delegators (see extend_type)
    attr_accessor :graphql_type, :mixins, :aliases

    def initialize(class_name)
      @class_name = class_name
      @fields = []
      @mixins = []
      @aliases = []
    end

    def bare_type = class_name

    def cast(expr, _depth)
      "#{class_name}.from_h(#{expr})"
    end

    def nested = self
  end

  class EnumNode < Node
    attr_reader :class_name, :values

    def initialize(class_name, values)
      @class_name = class_name
      @values = values
    end

    def bare_type = class_name

    def cast(expr, _depth)
      "#{class_name}.deserialize(#{expr})"
    end

    def serialize(expr, _depth)
      "#{expr}.serialize"
    end

    # enums always coerce: a kwarg or hash field accepts the T::Enum or
    # its wire value (deserialize raises on anything else)
    def coerce? = true

    def coerce(expr)
      "GraphWeaver::InputStruct.enum(#{class_name}, #{expr})"
    end

    def coerce_input_type = "T.any(#{class_name}, String)"
    def hash_coerce(expr, _depth) = coerce(expr)
    def nested = self
  end

  # A GraphQL enum mapped onto an app-owned T::Enum (see EnumType): no
  # generated enum class — instead module-level <NAME>_FROM_WIRE /
  # <NAME>_TO_WIRE constants translate at the boundary. fallback: makes
  # casting absorb unknown wire values (inputs stay strict).
  class MappedEnum < Node
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

    def cast(expr, _depth)
      if @fallback
        "#{const_prefix}_FROM_WIRE.fetch(#{expr}) { #{fallback_const} }"
      else
        "#{const_prefix}_FROM_WIRE.fetch(#{expr})"
      end
    end

    def serialize(expr, _depth)
      "#{const_prefix}_TO_WIRE.fetch(#{expr})"
    end

    # kwargs and hash fields accept the member or its wire value; unlike
    # casting, bad input raises even with a fallback (a typo'd input is
    # our bug, not server drift)
    def coerce? = true

    def coerce(expr)
      "GraphWeaver::InputStruct.mapped_enum(#{@type_name}, #{const_prefix}_FROM_WIRE, #{expr})"
    end

    def coerce_input_type = "T.any(#{@type_name}, String)"
    def hash_coerce(expr, _depth) = coerce(expr)
  end

  # A single-condition narrowing of an abstract field (`... on Pet { ... }`
  # and nothing else): the member struct when the runtime type matches,
  # nil when it doesn't. Always nilable, whatever the schema's nullability,
  # because narrowing filters.
  #
  # typename: is the member's GraphQL name when the selection also carries an
  # unconditional `__typename` — then the match is read off the tag. Without
  # it there is nothing to read but the object's emptiness: a non-match
  # carries none of the selected fields, so the hash arrives empty.
  class NarrowedNode < Node
    def initialize(of, typename: nil)
      @of = of
      @typename = typename
    end

    def class_name = @of.class_name
    def bare_type = @of.bare_type

    def cast(expr, depth)
      if @typename
        "(#{expr}[\"__typename\"] == #{@typename.inspect} ? #{@of.cast(expr, depth)} : nil)"
      else
        "(#{expr}.empty? ? nil : #{@of.cast(expr, depth)})"
      end
    end

    def nested = @of
  end

  class UnionNode < Node
    # class_name is writable: fields sharing one collapsed union settle on the
    # alphabetically first of their keys, which the walk may reach second
    attr_accessor :class_name
    attr_reader :members # graphql type name => ObjectNode
    # the struct an unnamed (or newly-added) __typename deserializes into
    attr_reader :catch_all

    def initialize(class_name, members, catch_all = nil)
      @class_name = class_name
      @members = members
      @catch_all = catch_all
    end

    def bare_type = "#{class_name}::Type"

    def cast(expr, _depth)
      "#{class_name}.from_h(#{expr})"
    end

    def nested = self
  end

  # A reference to a union hoisted into the shared types module (a named
  # shared fragment spread as a whole union field): the query references
  # <Name>::Type and dispatches through <Name>.from_h, where <Name> is the
  # alias the query module gives GraphQLTypes::<Name>. The type family lives
  # once in the shared module, so the same union across queries is one Ruby
  # type — nested is nil, nothing is emitted here.
  class UnionRefNode < Node
    attr_reader :class_name

    def initialize(class_name)
      @class_name = class_name
    end

    def bare_type = "#{class_name}::Type"

    def cast(expr, _depth)
      "#{class_name}.from_h(#{expr})"
    end
  end

  # An input-object variable: emitted as a module-level T::Struct whose
  # serialize produces the wire hash. Inputs never cast FROM the wire.
  # Joins the coerce protocol so execute kwargs accept plain hashes,
  # normalized (and type-checked) through the generated .coerce.
  class InputNode < Node
    Field = Struct.new(:prop, :wire, :node, :required)

    attr_reader :class_name, :fields
    # @oneOf: exactly one field may be supplied. The schema can't say so — every
    # @oneOf field is nullable — so the generated struct carries the flag and
    # InputStruct#serialize enforces it.
    attr_accessor :one_of

    def initialize(class_name)
      @class_name = class_name
      @fields = []
      @one_of = false
    end

    def bare_type = class_name

    def serialize(expr, _depth)
      "#{expr}.serialize"
    end

    def cast(_expr, _depth)
      raise GraphWeaver::Error, "input objects are never cast from responses"
    end

    def coerce? = true
    def coerce(expr) = "#{class_name}.coerce(#{expr})"
    def coerce_input_type = "T.any(#{class_name}, T::Hash[T.untyped, T.untyped])"

    # building a struct field from a caller-supplied plain hash value
    def hash_coerce(expr, _depth) = "#{class_name}.coerce(#{expr})"
  end

  # One entity's `Representations` builder: the typed constructor for the
  # references an `_entities(representations:)` query takes. `key_sets` are
  # the type's @key field sets as dotted paths ("organization.id"), in
  # declaration order; `params` the union of their top-level fields, which
  # is what the generated method takes as kwargs. Not part of the node
  # protocol — nothing casts or serializes through it — it's a shape emit
  # walks, sitting beside the result tree rather than inside it.
  class RepresentationNode
    # `wire` is the GraphQL field name, `value` the emitted expression that
    # puts the kwarg on the wire (a registered scalar serializes here)
    Param = Struct.new(:kwarg, :wire, :type, :value, :required)

    attr_reader :method_name, :graphql_type, :key_fields, :key_sets, :params

    # key_fields are the @key(fields:) strings as written, kept for the
    # comment above the builder — "organization { id }" reads better there
    # than the flattened path it becomes
    def initialize(method_name, graphql_type, key_fields, key_sets, params)
      @method_name = method_name
      @graphql_type = graphql_type
      @key_fields = key_fields
      @key_sets = key_sets
      @params = params
    end
  end
end
