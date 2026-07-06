# typed: true
require "graphql/client"
require "sorbet-runtime"

# Proof of concept: a drop-in replacement for the module built by
# GraphQL::Client::Schema.generate. Instead of lazy ObjectClass wrappers,
# it generates a T::Struct per query selection at parse time and casts
# response data directly into those structs at query time.
#
# The contract required by the client is small:
#   - the types module responds to define_class(definition, ast_nodes, type)
#   - whatever that returns responds to cast(value, errors)
#   - the top-level (operation) return value must match a branch of
#     Definition#new's case statement, which tests against the
#     GraphQL::Client::Schema::ObjectType module — so our object caster
#     includes it and provides new(data, errors)
module StructTypes
  # sorbet prop types for builtin scalars; custom scalars register here
  SCALARS = {
    "ID" => String,
    "String" => String,
    "Int" => Integer,
    "Float" => Float,
    "Boolean" => T::Boolean,
    "Date" => Date,
  }.freeze

  def self.generate(schema)
    Types.new(schema)
  end

  class Types
    def initialize(schema)
      @schema = schema
    end

    def define_class(definition, ast_nodes, type)
      case type.kind.name
      when "NON_NULL"
        NonNullType.new(define_class(definition, ast_nodes, type.of_type))
      when "LIST"
        ListType.new(define_class(definition, ast_nodes, type.of_type))
      when "SCALAR"
        ScalarType.new(type)
      when "OBJECT"
        object_type(definition, ast_nodes, type)
      else
        raise TypeError, "unsupported kind: #{type.kind.name}"
      end
    end

    private

    def object_type(definition, ast_nodes, type)
      # gather Field selections by result name (alias-aware), skipping the
      # __typename fields the client injects
      selections = {}
      ast_nodes.flat_map(&:selections).each do |node|
        unless node.is_a?(GraphQL::Language::Nodes::Field)
          raise TypeError, "only plain field selections are supported: #{node.class}"
        end
        next if node.name.start_with?("__")

        (selections[node.alias || node.name] ||= []) << node
      end

      fields = selections.to_h do |result_name, nodes|
        field_type = @schema.get_field(type.graphql_name, nodes.first.name).type
        [result_name, define_class(definition, nodes, field_type)]
      end

      ObjectStructType.new(type.graphql_name, fields)
    end
  end

  class ScalarType
    def initialize(type)
      @type = type
    end

    def cast(value, _errors = nil)
      value.nil? ? nil : @type.coerce_isolated_input(value)
    end

    def bare_type
      SCALARS.fetch(@type.graphql_name, T.untyped)
    end

    def prop_type
      T.nilable(bare_type)
    end
  end

  class NonNullType
    def initialize(of_type)
      @of_type = of_type
    end

    def cast(value, errors = nil)
      @of_type.cast(value, errors)
    end

    def bare_type
      @of_type.bare_type
    end

    # non-null strips the nilable wrapper
    def prop_type
      bare_type
    end
  end

  class ListType
    def initialize(of_type)
      @of_type = of_type
    end

    def cast(value, errors = nil)
      value&.map { |item| @of_type.cast(item, errors) }
    end

    def bare_type
      T::Array[@of_type.prop_type]
    end

    def prop_type
      T.nilable(bare_type)
    end
  end

  class ObjectStructType
    # tag so Definition#new's case dispatch accepts us
    include GraphQL::Client::Schema::ObjectType

    attr_reader :struct_class

    def initialize(graphql_name, fields)
      @fields = fields
      @struct_class = Class.new(T::Struct)
      @struct_class.define_singleton_method(:name) { "StructTypes::#{graphql_name}" }

      fields.each do |result_name, type|
        @struct_class.const(prop_name(result_name), type.prop_type)
      end
    end

    # Definition#new calls this with the operation's response data
    def new(data, _errors = nil)
      cast(data)
    end

    def cast(value, _errors = nil)
      return if value.nil?

      attrs = @fields.to_h do |result_name, type|
        [prop_name(result_name), type.cast(value[result_name])]
      end
      @struct_class.new(**attrs)
    end

    def bare_type
      @struct_class
    end

    def prop_type
      T.nilable(bare_type)
    end

    private

    def prop_name(result_name)
      ActiveSupport::Inflector.underscore(result_name).to_sym
    end
  end
end
