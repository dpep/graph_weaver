# typed: true
# frozen_string_literal: true

# Source emission: turns the node tree into the generated module text.
# Mixed into Codegen — methods run with the generator instance state.
class GraphWeaver::Codegen
  module Emit
    include GraphWeaver::Inflect

    private

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
      out << "#{pad}  rescue GraphWeaver::TypeError"
      out << "#{pad}    raise # already wrapped by a nested struct — keep the innermost context"
      out << "#{pad}  rescue TypeError, ArgumentError, KeyError => e"
      out << "#{pad}    raise GraphWeaver::TypeError.new(struct: self, error: e)"
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
      out << "#{pad}    else raise GraphWeaver::TypeError.new(struct: self, message: \"unexpected __typename: \#{typename}\")"
      out << "#{pad}    end"
      out << "#{pad}  end"
      out << "#{pad}end"
    end

    def emit_execute(out, variables, flatten: nil)
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

      # the kwarg surface: the input's fields when flattened, else one
      # kwarg per declared variable — typed identically either way
      params = flatten ? flatten.fields.partition(&:required).flatten : variables

      sig_params = params.map do |param|
        bare = param.node.coerce? ? param.node.coerce_input_type : param.node.bare_type
        kwarg_type = param.required ? bare : "T.nilable(#{bare})"
        "#{kwarg_name(param)}: #{kwarg_type}"
      end
      sig_params << "executor: T.untyped"

      kwargs = params.map { |param| param.required ? "#{kwarg_name(param)}:" : "#{kwarg_name(param)}: nil" }
      kwargs << "executor: self.executor"

      # execute returns the full envelope; execute! is the strict shortcut for
      # `execute(...).data!` — the typed result, or a raised QueryError.
      forward = (params.map { |param| "#{kwarg_name(param)}: #{kwarg_name(param)}" } + ["executor: executor"]).join(", ")

      if flatten
        out << "  # $#{variables.first.wire}'s fields, flattened into kwargs (single input-object variable)"
      end
      out << "  sig { params(#{sig_params.join(", ")}).returns(GraphWeaver::Response[Result]) }"
      out << "  def self.execute(#{kwargs.join(", ")})"

      if flatten
        fields = flatten.fields.map { |field| "#{field.prop}:" }.join(", ")
        out << "    variables = {"
        out << "      #{variables.first.wire.inspect} => #{flatten.class_name}.coerce({ #{fields} }).serialize,"
        out << "    }"
      else
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
      end

      out << ""
      out << "    raw = executor.execute(QUERY, variables: variables).to_h"
      out << "    GraphWeaver::Response[Result].new("
      out << "      data: (Result.from_h(raw[\"data\"]) if raw[\"data\"]),"
      out << "      errors: (raw[\"errors\"] || []).map { |e| GraphWeaver::GraphQLError.from_h(e) },"
      out << "      extensions: raw[\"extensions\"] || {},"
      out << "    )"
      out << "  end"
      out << ""
      out << "  sig { params(#{sig_params.join(", ")}).returns(Result) }"
      out << "  def self.execute!(#{kwargs.join(", ")})"
      out << "    execute(#{forward}).data!"
      out << "  end"
    end

    # a kwarg surface entry is a VarDef (.kwarg) or, when flattened, an
    # InputNode::Field (.prop)
    def kwarg_name(param)
      param.respond_to?(:kwarg) ? param.kwarg : param.prop
    end

    def variable_serialize(var)
      value = var.node.coerce? ? var.node.coerce(var.kwarg) : var.kwarg
      var.node.serialize_identity? ? value : var.node.serialize(value, 1)
    end

    # Structured shape for a schema-validation error: message plus its first
    # source location, so ValidationError#errors is inspectable.
    def validation_detail(error)
      loc = (error.to_h["locations"]&.first if error.respond_to?(:to_h))
      { message: error.message, line: loc && loc["line"], column: loc && loc["column"] }
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

    # a module-level T::Struct per input type; serialize builds the wire
    # hash, omitting optional fields left nil
    def emit_input(node, out, indent)
      pad = "  " * indent

      out << "#{pad}class #{node.class_name} < T::Struct"
      out << "#{pad}  extend T::Sig"
      out << ""
      node.fields.each do |field|
        default = field.required ? "" : ", default: nil"
        out << "#{pad}  const :#{field.prop}, #{field.node.prop_type}#{default}"
      end
      out << ""
      out << "#{pad}  sig { returns(T::Hash[String, T.untyped]) }"
      out << "#{pad}  def serialize"
      out << "#{pad}    result = T.let({}, T::Hash[String, T.untyped])"
      node.fields.each do |field|
        if field.required || field.node.serialize_identity?
          value = field.node.serialize_identity? ? field.prop.to_s : field.node.serialize(field.prop.to_s, 1)
          line = "result[#{field.wire.inspect}] = #{value}"
          line += " unless #{field.prop}.nil?" unless field.required
          out << "#{pad}    #{line}"
        else
          # bind a local so sorbet's flow-sensitivity narrows the nilable
          out << "#{pad}    unless (value = #{field.prop}).nil?"
          out << "#{pad}      result[#{field.wire.inspect}] = #{field.node.serialize("value", 1)}"
          out << "#{pad}    end"
        end
      end
      out << "#{pad}    result"
      out << "#{pad}  end"
      out << ""
      out << "#{pad}  # serialize, under the conventional name"
      out << "#{pad}  sig { returns(T::Hash[String, T.untyped]) }"
      out << "#{pad}  def to_h = serialize"
      out << ""
      out << "#{pad}  # Build from a plain hash (underscored keys, Symbol or String):"
      out << "#{pad}  # enums accept their wire values, nested inputs accept hashes;"
      out << "#{pad}  # the struct's types are enforced on construction."
      out << "#{pad}  sig { params(value: T.any(#{node.class_name}, T::Hash[T.untyped, T.untyped])).returns(#{node.class_name}) }"
      out << "#{pad}  def self.coerce(value)"
      out << "#{pad}    return value if value.is_a?(#{node.class_name})"
      out << ""
      out << "#{pad}    new("
      node.fields.each do |field|
        raw = "value_at(value, :#{field.prop})"
        expr = if field.node.hash_coerce_identity?
          raw
        elsif field.required
          "#{raw}.then { |v1| #{field.node.hash_coerce("v1", 2)} }"
        else
          "#{raw}&.then { |v1| #{field.node.hash_coerce("v1", 2)} }"
        end
        out << "#{pad}      #{field.prop}: #{expr},"
      end
      out << "#{pad}    )"
      out << "#{pad}  end"
      out << ""
      out << "#{pad}  sig { params(hash: T::Hash[T.untyped, T.untyped], key: Symbol).returns(T.untyped) }"
      out << "#{pad}  private_class_method def self.value_at(hash, key)"
      out << "#{pad}    hash.key?(key) ? hash[key] : hash[key.to_s]"
      out << "#{pad}  end"
      out << "#{pad}end"
    end
  end
end
