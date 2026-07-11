# typed: true
# frozen_string_literal: true

# The typed intermediate representation of a query selection: one node
# per GraphQL type shape, each knowing its Sorbet prop type and the
# cast/serialize code to emit.
class GraphWeaver::Codegen
  class Scalar
    def initialize(name)
      @scalar = GraphWeaver::Codegen.scalar(name)
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

    def non_null? = false
    def nested = nil
  end

  class NonNull
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
    def non_null? = false
    def nested = @of.nested
  end

  class ObjectNode
    Field = Struct.new(:prop, :key, :node)

    attr_reader :class_name, :fields

    def initialize(class_name)
      @class_name = class_name
      @fields = []
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
    def coerce? = false
    def non_null? = false
    def nested = self
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

  attr_reader :module_name

  # An executor is anything responding to `execute(query, variables:)`
  # whose result `to_h`s into {"data" => ..., "errors" => ...} — a Schema
  # class for in-process execution, or an Http/FaradayExecutor for a
  # remote endpoint.
  #
  # executor: (a constant, or its name as a string) becomes the generated
  # module's default transport; when omitted, generated code falls back
  # to GraphWeaver.executor. Either way the module exposes .executor= and
  # execute accepts a per-call executor: override.
  #
  # module_name: defaults to the operation's name (`query GetPerson` →
  # GetPerson); required for anonymous operations when generating files.
  # default_module_name: is the last-resort fallback — parse sets it to
  # "Query" since its container scoping makes name collisions impossible,
  # while file generation stays strict (a checked-in file deserves a
end
