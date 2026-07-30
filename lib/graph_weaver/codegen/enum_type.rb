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
    def register_enum(graphql_name, type, map: nil, fallback: nil, requires: nil)
      enum_registry[graphql_name.to_s] = EnumType.new(graphql_name, type, map:, fallback:, requires:)
    end

    # Bulk, inference-only form: register_enums("Species" => PetKind, ...)
    def register_enums(mappings)
      mappings.each { |graphql_name, type| register_enum(graphql_name, type) }
    end

    def enum_registry
      @enum_registry ||= {}
    end

    # Attach app-owned helper modules to every struct generated from a
    # GraphQL type — the logic stays in your code, generation wires it in:
    #
    #      GraphWeaver.extend_type("Pet", PetHelpers)
    #
    # Or build the mixin inline — the block is module_eval'd into a fresh
    # module auto-named GraphWeaver::TypeHelpers::<Type>. Handy for quick
    # decoration; srb tc can't see into block-defined methods, so prefer
    # a named module where static checking matters:
    #
    #      GraphWeaver.extend_type("Pet") do
    #        def display_name = "#{name} the pet"
    #      end
    #
    # Additive: repeated registrations (and client-scoped ones) stack.
    #
    # alias: projects a (possibly nested) selected field onto a flat, typed
    # accessor on the struct — the one derivation codegen can type itself, so
    # it's emitted into the struct body where the field is in scope:
    #
    #      GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" })
    #      GraphWeaver.extend_type("Widget", alias: "meta.tag")        # accessor named `tag`
    #      GraphWeaver.extend_type("Widget", alias: ["meta.tag", "meta.color"])
    def extend_type(graphql_name, *mixins, requires: nil, **kw, &block)
      aliases = take_aliases(kw)
      entry = type_registry[graphql_name.to_s] ||= { mixins: [], requires: [], aliases: {} }
      add_type_helpers(entry, graphql_name, mixins, requires, block, aliases)
    end

    # Pull alias: out of the keyword rest and normalize it; any other keyword
    # is a typo worth flagging rather than silently dropping.
    def take_aliases(kw)
      aliases = normalize_aliases(kw.delete(:alias))
      raise ArgumentError, "unknown keyword: #{kw.keys.first}" unless kw.empty?
      aliases
    end

    # { accessor => [path, segments] } from a path string (accessor named
    # after the last segment), an array of such, or an { accessor => path } hash.
    def normalize_aliases(input)
      case input
      when nil then {}
      when String then { input.split(".").last => input.split(".") }
      when Array then input.to_h { |path| [path.split(".").last, path.split(".")] }
      when Hash then input.to_h { |name, path| [name.to_s, path.to_s.split(".")] }
      else raise ArgumentError, "alias: expects a String, Array, or Hash, got #{input.class}"
      end
    end

    def type_registry
      @type_registry ||= {}
    end

    # shared with Client#extend_type: build/validate the mixins and
    # append them to a registry entry
    def add_type_helpers(entry, graphql_name, mixins, requires, block, aliases = {})
      mixins = mixins.dup
      mixins << helper_module(graphql_name, block) if block

      if mixins.empty? && aliases.empty?
        raise ArgumentError, "pass one or more helper modules, a block, or alias:"
      end
      mixins.each do |mixin|
        unless mixin.is_a?(Module) && mixin.name
          raise ArgumentError, "type helpers must be named modules, got #{mixin.inspect}"
        end
      end

      entry[:mixins].concat(mixins)
      entry[:requires].concat(Array(requires))
      (entry[:aliases] ||= {}).merge!(aliases)
      entry
    end

    # a block-built mixin needs a name generated files can reference:
    # GraphWeaver::TypeHelpers::Pet (suffixed on re-registration)
    def helper_module(graphql_name, block)
      base = GraphWeaver::Inflect.camelize(graphql_name.to_s)
      name = base
      count = 1
      name = "#{base}V#{count += 1}" while GraphWeaver::TypeHelpers.const_defined?(name, false)
      GraphWeaver::TypeHelpers.const_set(name, Module.new(&block))
    end
    private :helper_module
  end
end

module GraphWeaver
  # Home of block-built type helpers (extend_type with a block), which
  # need constant names so generated files can reference them.
  module TypeHelpers; end
end
