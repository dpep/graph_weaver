# typed: true
# frozen_string_literal: true

class GraphWeaver::Codegen
  # How one GraphQL enum maps onto an app-owned T::Enum, so generated
  # code speaks YOUR enum instead of generating one per module:
  #
  #      class PetKind < T::Enum
  #        enums { Cat = new("cat"); Dog = new("dog") }
  #      end
  #
  #      GraphWeaver.register_enum("Species", type: PetKind)
  #
  # The wire mapping is inferred by name ("CAT" <-> PetKind::Cat,
  # case/underscore-insensitive against each member's serialized value);
  # map: pins renames explicitly and merges over inference. Every wire
  # value the schema declares must resolve — generation fails naming the
  # gaps — unless fallback: names a member to absorb unknown values
  # (forward-compat for servers that add members; inputs stay strict).
  class EnumType
    attr_reader :graphql_name, :type, :fallback, :requires

    def initialize(graphql_name, type:, map: nil, fallback: nil, requires: nil)
      @graphql_name = graphql_name.to_s
      unless type.is_a?(Class) && type < T::Enum
        raise ArgumentError, "type: must be a T::Enum subclass, got #{type.inspect}"
      end
      unless type.name
        raise ArgumentError, "type: must be a named constant (anonymous classes can't appear in generated source)"
      end

      @type = type
      @map = map || {}
      @fallback = fallback
      @requires = Array(requires)

      if fallback && !type.values.include?(fallback)
        raise ArgumentError, "fallback: must be a #{type} member, got #{fallback.inspect}"
      end
    end

    # wire value => member for every value the schema declares; raises
    # naming the unmappable ones (unless fallback: absorbs them)
    def mapping_for(wire_values)
      mapping = {}
      missing = []

      wire_values.each do |wire|
        member = @map[wire] || infer(wire)
        member ? mapping[wire] = member : missing << wire
      end

      if missing.any? && !fallback
        raise GraphWeaver::Error,
          "#{type} has no member for #{graphql_name} value(s) #{missing.join(", ")} — " \
          "add them, pin with map:, or absorb with fallback:"
      end

      mapping
    end

    private

    # "CAT" matches serialize "cat"; "NOT_FOUND" matches "not_found"
    def infer(wire)
      @type.values.find { |member| normalize(member.serialize.to_s) == normalize(wire) }
    end

    def normalize(value)
      value.downcase.delete("_")
    end
  end

  class << self
    # Map a GraphQL enum onto an app-owned T::Enum (see EnumType); the
    # global default — client.register_enum scopes to one client.
    def register_enum(graphql_name, type:, map: nil, fallback: nil, requires: nil)
      enum_registry[graphql_name.to_s] = EnumType.new(graphql_name, type:, map:, fallback:, requires:)
    end

    # Bulk, inference-only form: register_enums("Species" => PetKind, ...)
    def register_enums(mappings)
      mappings.each { |graphql_name, type| register_enum(graphql_name, type:) }
    end

    def enum_registry
      @enum_registry ||= {}
    end

    # Attach app-owned helper modules to every struct generated from a
    # GraphQL type — the logic stays in your code, generation wires it in:
    #
    #      GraphWeaver.register_type("Pet", include: PetHelpers)
    #
    # Additive: repeated registrations (and client-scoped ones) stack.
    def register_type(graphql_name, include:, requires: nil)
      mixins = Array(include)
      mixins.each do |mixin|
        unless mixin.is_a?(Module) && mixin.name
          raise ArgumentError, "include: must be (an array of) named modules, got #{mixin.inspect}"
        end
      end

      entry = type_registry[graphql_name.to_s] ||= { mixins: [], requires: [] }
      entry[:mixins].concat(mixins)
      entry[:requires].concat(Array(requires))
      entry
    end

    def type_registry
      @type_registry ||= {}
    end
  end
end
