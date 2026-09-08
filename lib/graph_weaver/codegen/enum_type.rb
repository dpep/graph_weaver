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
  #      GraphWeaver.register_enum("Species", PetKind)
  #
  # The wire mapping is inferred by name ("CAT" <-> PetKind::Cat,
  # case/underscore-insensitive against each member's serialized value);
  # map: pins renames explicitly and merges over inference. Every wire
  # value the schema declares must resolve — generation fails naming the
  # gaps — unless fallback: names a member to absorb unknown values
  # (forward-compat for servers that add members; inputs stay strict).
  class EnumType
    attr_reader :graphql_name, :type, :fallback, :requires

    def initialize(graphql_name, type, map: nil, fallback: nil, requires: nil)
      @graphql_name = graphql_name.to_s
      # A name, not the class, is what you write when the constant won't
      # resolve yet — which in Rails means a config/initializers file, since
      # autoloading is set up after those run. Say where it does resolve.
      if type.is_a?(String)
        raise ArgumentError, "type: is the T::Enum itself, not its name — " \
          "register_enum(#{@graphql_name.inspect}, #{type}). #{GraphWeaver::Codegen::AUTOLOAD_HINT}"
      end
      unless type.is_a?(Class) && type < T::Enum
        raise ArgumentError, "type: must be a T::Enum subclass, got #{type.inspect}"
      end
      unless type.name
        raise ArgumentError, "type: must be a named constant (anonymous classes can't appear in generated source)"
      end

      @type = type
      @map = map || {}
      @fallback = fallback
      @requires = GraphWeaver::Codegen.normalize_requires!(requires, load: true)

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
    # Map a GraphQL enum onto an app-owned T::Enum (see EnumType). The one
    # implementation — GraphWeaver.register_enum is a delegate, so the same
    # call reaches it whichever door you came in by.
    #
    # A value map is a natural third *positional* guess, and Ruby's arity
    # complaint ("given 3, expected 2") never mentions the keyword.
    def register_enum(graphql_name, type, positional_map = nil, map: nil, fallback: nil, requires: nil)
      if positional_map
        raise GraphWeaver::Error, "register_enum: the value map is a keyword — " \
          "register_enum(#{graphql_name.inspect}, #{type}, map: {...})"
      end

      enum_registry[graphql_name.to_s] = EnumType.new(graphql_name, type, map:, fallback:, requires:)
    end

    def enum_registry
      @enum_registry ||= {}
    end

    # Drop every register_enum mapping. No pair with a clear_ twin the way
    # scalars have one: there are no built-in enums to restore.
    def reset_enums!
      enum_registry.clear
      self
    end
  end
end
