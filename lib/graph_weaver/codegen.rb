# typed: true
# frozen_string_literal: true

require "date"
require "graphql"
require "sorbet-runtime"

# Generates plain, statically-typecheckable Ruby from a GraphQL query +
# schema: nested T::Structs, from_h casting code, and a sig'd execute
# method. Unlike StructTypes (which builds classes at parse time, visible
# only at runtime), the output is source on disk — srb tc sees the exact
# result type of each query.
#
# Supports queries and mutations; plain fields, inline fragments, named
# fragment spreads (including interface type conditions), union- and
# interface-typed fields (dispatch on __typename), enums (generated
# T::Enum), and typed variables (kwargs on execute). Input objects and
# subscriptions are still open.
require_relative "inflect"

class GraphWeaver::Codegen
  include GraphWeaver::Inflect

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
  #   type: Money   (defines .parse)   => Money.parse(expr) / expr.to_s
  #   type: Blob    (defines .load)    => Blob.load(expr)   / Blob.dump(expr)
  # Probing the *deserialize* side is deliberate: every object has #to_s,
  # so inferring a serializer off it would wrongly wrap plain types (String,
  # Integer) — pairing off a deserializer the type actually defines avoids
  # that. Override with an explicit value:
  #   - a Symbol names a method, so there is no string to misspell:
  #       cast: :load        => "Blob.load(expr)"    (class method on type)
  #       serialize: :to_json => "expr.to_json"      (instance method)
  #   - a Proc handles anything a Symbol can't express:
  #       cast: ->(e) { "Money.new(#{e})" }
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

    def initialize(graphql_name, type:, cast: nil, serialize: nil, requires: nil, coerce: false)
      @graphql_name = graphql_name.to_s
      @klass = type.is_a?(Module) ? type : nil
      @type = type_name(type)
      codec = @klass && CODECS.find { |c| @klass.respond_to?(c.probe) }
      @cast = normalize_cast(cast, codec&.cast)
      @serialize = normalize_serialize(serialize, codec&.serialize)
      @requires = normalize_requires(requires)
      @coerce = coerce
      validate_coerce!
    end

    def cast(expr) = @cast&.call(expr)
    def cast? = !@cast.nil?
    def serialize(expr) = @serialize&.call(expr)
    def serialize? = !@serialize.nil?
    def coerce? = !!@coerce

    # The code that normalizes a variable input before it's serialized. Two
    # shapes: coerce: true parses a raw value into the rich type via the cast
    # (guarded so an already-typed value passes through); coerce: :to_f (a
    # Symbol) calls that instance method, for built-ins where a plain
    # conversion is the whole story (5, "5" -> 5.0). serialize still runs
    # afterward, but is identity for the conversion built-ins, so the
    # converted value goes on the wire natively (a Float, not "5.0").
    def coerce_input(expr)
      case @coerce
      when true then "(#{expr}.is_a?(#{@type}) ? #{expr} : #{cast(expr)})"
      when Symbol then "#{expr}.#{@coerce}"
      end
    end

    # the accepted Sorbet type for a coercible variable kwarg
    def coerce_type
      case @coerce
      when true then "T.any(#{@type}, String)"
      when Symbol then CONVERT_INPUTS.fetch(@coerce, "T.untyped")
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
    def register_scalar(graphql_name, type:, cast: nil, serialize: nil, requires: nil, coerce: false)
      scalar_registry[graphql_name.to_s] =
        ScalarType.new(graphql_name, type:, cast:, serialize:, requires:, coerce:)
    end

    # The ScalarType for a scalar name; unknown scalars fall back to an
    # untyped pass-through (T.untyped, no cast) — the prior behavior for
    # scalars outside the table.
    def scalar(graphql_name)
      scalar_registry.fetch(graphql_name.to_s) do
        ScalarType.new(graphql_name, type: "T.untyped")
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
    # clean slate to reach for between tests, or to undo overrides. Pass
    # coerce: true to reload the built-ins with input coercion enabled
    # (Float accepts 5/"5" and .to_f's it, etc.), then register your own
    # scalars on top — a one-liner alternative to re-registering each
    # built-in by hand.
    def reset_scalars!(coerce: false)
      clear_scalars!
      register_builtin_scalars!(coerce:)
      self
    end

    # Built-in scalars — pre-registered entries in the one registry. The
    # standard scalars stay pass-through: their Ruby classes (String,
    # Integer, Float) define neither .parse nor .load, so codec inference
    # matches nothing and leaves them identity — which is exactly why we
    # can name them with the real class constants. Date deserializes via
    # ISO-8601 (it *does* define .parse, but we want iso8601 specifically,
    # so it's explicit).
    #
    # coerce: true opts the convertible scalars into input coercion via a
    # plain conversion method (to_f/to_i/to_s); the wire value stays native
    # (a Float, not "5.0"). Boolean and Date have no lossless one-method
    # conversion, so they stay strict either way.
    def register_builtin_scalars!(coerce: false)
      register_scalar "ID", type: String, coerce: (:to_s if coerce)
      register_scalar "String", type: String, coerce: (:to_s if coerce)
      register_scalar "Int", type: Integer, coerce: (:to_i if coerce)
      register_scalar "Float", type: Float, coerce: (:to_f if coerce)
      register_scalar "Boolean", type: "T::Boolean"
      register_scalar "Date", type: Date, cast: :iso8601, serialize: :iso8601, requires: "date"
    end
  end

  register_builtin_scalars!

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
  # deliberate name).
  def initialize(schema:, query:, module_name: nil, executor: nil, default_module_name: nil)
    @schema = schema
    @query = query.strip
    @module_name = module_name
    @default_module_name = default_module_name
    @executor_const = executor.is_a?(Module) ? executor.name : executor
  end

  # one-step shorthand
  def self.generate(schema:, query:, module_name: nil, executor: nil)
    new(schema:, query:, module_name:, executor:).generate
  end

  # Development convenience: generate + eval in one step, no build
  # artifact or checked-in file. Same runtime semantics as the generated
  # file, but invisible to srb tc — use the build step for static typing.
  # Evaluates into an anonymous container, so no global constants leak;
  # executor: additionally accepts a live object (set via .executor=).
  def self.parse(schema:, query:, module_name: nil, executor: nil)
    executor_const = case executor
    when String then executor
    when Module then executor.name # nil for anonymous modules
    end

    codegen = new(schema:, query:, module_name:, executor: executor_const, default_module_name: "Query")
    source = codegen.generate

    container = Module.new
    container.module_eval(source, "(graph_weaver)", 1)
    mod = container.const_get(codegen.module_name)
    # live objects (or anonymous modules) can't be referenced from
    # generated source — set them via the module's writer instead
    mod.executor = executor if executor && executor_const.nil?
    mod
  end

  VarDef = Struct.new(:kwarg, :wire, :node, :required)

  def generate
    errors = @schema.validate(@query)
    if errors.any?
      raise ArgumentError, "invalid query: #{errors.map(&:message).join("; ")}"
    end

    doc = GraphQL.parse(@query)
    @fragments = doc.definitions
      .grep(GraphQL::Language::Nodes::FragmentDefinition)
      .to_h { |fragment| [fragment.name, fragment] }
    @variable_enums = {}
    # requires contributed by the custom scalars this query actually uses
    @scalar_requires = []

    operation = doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition).first
    root_type = case operation&.operation_type
    when "query", nil then @schema.query
    when "mutation" then @schema.mutation
    else raise NotImplementedError, "unsupported operation: #{operation.operation_type}"
    end

    @module_name ||= operation.name || @default_module_name
    unless @module_name
      raise ArgumentError, "module_name: required for anonymous operations"
    end

    variables = operation.variables.map do |var|
      node = ast_type_ref(var.type)
      # a variable is optional when nullable or defaulted; optional kwargs
      # default to nil and are omitted from the wire
      required = node.non_null? && var.default_value.nil?
      VarDef.new(underscore(var.name), var.name, node, required)
    end

    root = object_node(root_type, operation.selections, "Result")

    out = []
    out << "# typed: strict"
    out << "# frozen_string_literal: true"
    out << ""
    out << "# Generated by GraphWeaver — do not edit."
    out << ""
    requires = @scalar_requires.uniq.sort
    if requires.any?
      requires.each { |req| out << "require #{req.inspect}" }
      out << ""
    end
    out << "module #{@module_name}"
    out << "  extend T::Sig"
    out << ""
    out << "  QUERY = T.let(<<~'GRAPHQL', String)"
    @query.each_line { |line| out << "    #{line}".rstrip }
    out << "  GRAPHQL"
    out << ""
    @variable_enums.each_value do |enum|
      emit_enum(enum, out, 1)
      out << ""
    end
    emit_nested(root, out, 1)
    out << ""
    emit_execute(out, variables)
    out << "end"

    out.join("\n") + "\n"
  end

  private

  # Flatten a selection set as seen by `type`: plain fields collect
  # directly; inline fragments and named spreads recurse when their type
  # condition matches (exact name match — interface conditions are out of
  # scope for this spike).
  def gather(type, selections, out = {})
    selections.each do |selection|
      case selection
      when GraphQL::Language::Nodes::Field
        (out[selection.alias || selection.name] ||= []) << selection
      when GraphQL::Language::Nodes::InlineFragment
        gather(type, selection.selections, out) if applies?(selection.type&.name, type)
      when GraphQL::Language::Nodes::FragmentSpread
        fragment = @fragments.fetch(selection.name) do
          raise ArgumentError, "unknown fragment: #{selection.name}"
        end
        gather(type, fragment.selections, out) if applies?(fragment.type.name, type)
      else
        raise NotImplementedError, "unsupported selection: #{selection.class}"
      end
    end

    out
  end

  # A fragment's type condition applies when it names this type exactly,
  # or an interface/union this type belongs to (`... on Named { ... }`).
  def applies?(condition, type)
    return true if condition.nil? || condition == type.graphql_name

    condition_type = @schema.get_type(condition)
    return false unless condition_type

    kind = condition_type.kind.name
    (kind == "INTERFACE" || kind == "UNION") &&
      @schema.possible_types(condition_type).include?(type)
  end

  def object_node(type, selections, class_name)
    node = ObjectNode.new(class_name)
    taken = [class_name]

    gather(type, selections).each do |key, field_nodes|
      field_name = field_nodes.first.name
      prop = underscore(key)

      child = if field_name == "__typename"
        NonNull.new(Scalar.new("String"))
      else
        field_type = @schema.get_field(type.graphql_name, field_name).type
        sub_selections = field_nodes.flat_map(&:selections)

        case (core = unwrap(field_type)).kind.name
        when "OBJECT"
          name = pick_name(core.graphql_name, key, taken)
          type_ref(field_type) { object_node(core, sub_selections, name) }
        when "UNION", "INTERFACE"
          name = pick_name(core.graphql_name, key, taken)
          type_ref(field_type) { union_node(core, sub_selections, name) }
        when "ENUM"
          name = pick_name(core.graphql_name, key, taken)
          # sorted so output is deterministic across schema sources
          # (SDL round-trips reorder values alphabetically)
          type_ref(field_type) { EnumNode.new(name, core.values.keys.sort) }
        when "SCALAR"
          type_ref(field_type) { scalar_node(core.graphql_name) }
        else
          raise NotImplementedError, "unsupported kind: #{core.kind.name}"
        end
      end

      node.fields << ObjectNode::Field.new(prop, key, child)
    end

    node
  end

  # Abstract types (unions AND interfaces): one member struct per
  # possible type; wire dispatch reads __typename, so the query must
  # select it. For interfaces, the interface's own field selections
  # gather into every member.
  def union_node(type, selections, class_name)
    unless gather(type, selections).key?("__typename")
      raise ArgumentError, "select __typename on #{type.graphql_name} so #{class_name} can dispatch"
    end

    # sorted so output is deterministic across schema sources
    members = @schema.possible_types(type).sort_by(&:graphql_name).to_h do |possible|
      [possible.graphql_name, object_node(possible, selections, possible.graphql_name)]
    end

    UnionNode.new(class_name, members)
  end

  # Build a node from an AST type reference (variable definitions), where
  # only the type NAME is known — resolve the core through the schema.
  def ast_type_ref(ast_type)
    case ast_type
    when GraphQL::Language::Nodes::NonNullType
      NonNull.new(ast_type_ref(ast_type.of_type))
    when GraphQL::Language::Nodes::ListType
      List.new(ast_type_ref(ast_type.of_type))
    when GraphQL::Language::Nodes::TypeName
      core = @schema.get_type(ast_type.name)
      case core.kind.name
      when "SCALAR"
        scalar_node(core.graphql_name)
      when "ENUM"
        @variable_enums[core.graphql_name] ||=
          EnumNode.new(core.graphql_name, core.values.keys.sort)
      else
        raise NotImplementedError, "unsupported variable kind: #{core.kind.name}"
      end
    else
      raise NotImplementedError, "unsupported type node: #{ast_type.class}"
    end
  end

  # A Scalar node, recording any requires its registered type needs so the
  # generated file can require them (collected across the whole query).
  def scalar_node(name)
    @scalar_requires.concat(GraphWeaver::Codegen.scalar(name).requires)
    Scalar.new(name)
  end

  # rebuild the NON_NULL/LIST wrappers around the core node
  def type_ref(type, &core)
    case type.kind.name
    when "NON_NULL"
      NonNull.new(type_ref(type.of_type, &core))
    when "LIST"
      List.new(type_ref(type.of_type, &core))
    else
      core.call
    end
  end

  def unwrap(type)
    type = type.of_type while type.kind.name == "NON_NULL" || type.kind.name == "LIST"
    type
  end

  def pick_name(type_name, key, taken)
    candidate = type_name
    candidate = "#{camelize(key)}#{type_name}" if taken.include?(candidate)
    raise NotImplementedError, "class name collision: #{candidate}" if taken.include?(candidate)

    taken << candidate
    candidate
  end

  def emit_nested(node, out, indent)
    case node
    when UnionNode then emit_union(node, out, indent)
    when EnumNode then emit_enum(node, out, indent)
    else emit_object(node, out, indent)
    end
  end

  def emit_enum(node, out, indent)
    pad = "  " * indent

    out << "#{pad}class #{node.class_name} < T::Enum"
    out << "#{pad}  enums do"
    node.values.each do |value|
      out << "#{pad}    #{camelize(value.downcase)} = new(#{value.inspect})"
    end
    out << "#{pad}  end"
    out << "#{pad}end"
  end

  def emit_object(node, out, indent)
    pad = "  " * indent

    out << "#{pad}class #{node.class_name} < T::Struct"
    out << "#{pad}  extend T::Sig"
    out << ""

    node.fields.filter_map { |field| field.node.nested }.each do |child|
      emit_nested(child, out, indent + 1)
      out << ""
    end

    node.fields.each do |field|
      out << "#{pad}  const :#{field.prop}, #{field.node.prop_type}"
    end

    out << ""
    out << "#{pad}  sig { params(data: T::Hash[String, T.untyped]).returns(#{node.class_name}) }"
    out << "#{pad}  def self.from_h(data)"
    out << "#{pad}    new("
    node.fields.each do |field|
      out << "#{pad}      #{field.prop}: #{field_cast(field)},"
    end
    out << "#{pad}    )"
    out << "#{pad}  end"
    out << "#{pad}end"
  end

  def emit_union(node, out, indent)
    pad = "  " * indent

    out << "#{pad}module #{node.class_name}"
    out << "#{pad}  extend T::Sig"
    out << ""

    node.members.each_value do |member|
      emit_object(member, out, indent + 1)
      out << ""
    end

    member_names = node.members.values.map(&:class_name)
    type_alias = member_names.size == 1 ? member_names.first : "T.any(#{member_names.join(", ")})"
    out << "#{pad}  Type = T.type_alias { #{type_alias} }"
    out << ""
    out << "#{pad}  sig { params(data: T::Hash[String, T.untyped]).returns(Type) }"
    out << "#{pad}  def self.from_h(data)"
    out << "#{pad}    case (typename = data.fetch(\"__typename\"))"
    node.members.each do |graphql_name, member|
      out << "#{pad}    when #{graphql_name.inspect} then #{member.class_name}.from_h(data)"
    end
    out << "#{pad}    else raise \"unexpected __typename: \#{typename}\""
    out << "#{pad}    end"
    out << "#{pad}  end"
    out << "#{pad}end"
  end

  def emit_execute(out, variables)
    out << "  @executor = T.let(nil, T.untyped)"
    out << ""
    out << "  class << self"
    out << "    extend T::Sig"
    out << ""
    out << "    sig { params(executor: T.untyped).void }"
    out << "    attr_writer :executor"
    out << ""
    out << "    # default transport for execute"
    out << "    sig { returns(T.untyped) }"
    out << "    def executor"
    out << "      @executor || #{@executor_const || "GraphWeaver.executor"}"
    out << "    end"
    out << "  end"
    out << ""

    sig_params = variables.map do |var|
      bare = var.node.coerce? ? var.node.coerce_input_type : var.node.bare_type
      kwarg_type = var.required ? bare : "T.nilable(#{bare})"
      "#{var.kwarg}: #{kwarg_type}"
    end
    sig_params << "executor: T.untyped"

    kwargs = variables.map { |var| var.required ? "#{var.kwarg}:" : "#{var.kwarg}: nil" }
    kwargs << "executor: self.executor"

    out << "  sig { params(#{sig_params.join(", ")}).returns(Result) }"
    out << "  def self.execute(#{kwargs.join(", ")})"

    required, optional = variables.partition(&:required)
    if required.empty?
      out << "    variables = {}"
    else
      out << "    variables = {"
      required.each do |var|
        out << "      #{var.wire.inspect} => #{variable_serialize(var)},"
      end
      out << "    }"
    end
    optional.each do |var|
      out << "    variables[#{var.wire.inspect}] = #{variable_serialize(var)} unless #{var.kwarg}.nil?"
    end

    out << ""
    out << "    result = executor.execute(QUERY, variables: variables).to_h"
    out << "    if (errors = result[\"errors\"])"
    out << "      raise \"query failed: \#{errors.inspect}\""
    out << "    end"
    out << ""
    out << "    Result.from_h(result.fetch(\"data\"))"
    out << "  end"
  end

  def variable_serialize(var)
    value = var.node.coerce? ? var.node.coerce(var.kwarg) : var.kwarg
    var.node.serialize_identity? ? value : var.node.serialize(value, 1)
  end

  def field_cast(field)
    node = field.node

    if node.non_null?
      raw = "data.fetch(#{field.key.inspect})"
      node.identity? ? raw : node.cast(raw, 1)
    else
      raw = "data[#{field.key.inspect}]"
      node.identity? ? raw : "#{raw}&.then { |v1| #{node.cast("v1", 2)} }"
    end
  end
end
