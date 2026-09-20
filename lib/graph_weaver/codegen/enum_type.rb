# typed: true
# frozen_string_literal: true

class GraphWeaver::Codegen
  # What a register_enum said about one GraphQL enum: the app-owned T::Enum
  # its values map onto, and which wire spellings are the same value.
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
  #
  # alias: { "legacy_mode" => "LEGACY_MODE" } says two wire values are one
  # value — both spellings cast, the target is what serializes. It is the
  # whole registration when there is no T::Enum to map onto, and then the
  # generated enum gets one constant for the target and none for the alias.
  #
  # fallback: true is the same type-less form asking for leniency instead:
  # the generated enum gains an Other member and absorbs undeclared wire
  # values into it (see Codegen#enum_values).
  class EnumType
    attr_reader :graphql_name, :type, :fallback, :requires

    def initialize(graphql_name, type, map: nil, fallback: nil, requires: nil, aliases: nil)
      @graphql_name = graphql_name.to_s
      @aliases = normalize_aliases!(aliases)
      @type = type
      @map = map || {}
      @fallback = fallback

      return alias_only!(map, fallback, requires) if type.nil?

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

      @requires = GraphWeaver::Codegen.normalize_requires!(requires, load: true)

      if fallback && !type.values.include?(fallback)
        raise ArgumentError, "fallback: must be a #{type} member, got #{fallback.inspect}"
      end
    end

    # register_enum("Species", fallback: true): the generated enum gains an
    # Other member and casts every undeclared wire value to it.
    def generated_fallback? = type.nil? && fallback == true

    # The wire tables for a mapped enum: [wire value => member, member => the
    # wire value that goes out]. Every spelling casts; an alias's target is the
    # one that serializes.
    def tables_for(wire_values)
      aliases = aliases_for(wire_values)
      from_wire = {}
      missing = []

      wire_values.each do |wire|
        canonical = aliases.fetch(wire, wire)
        member = @map[canonical] || infer(canonical)
        member ? from_wire[wire] = member : missing << canonical
      end

      if missing.any? && !fallback
        raise GraphWeaver::Error,
          "#{type} has no member for #{graphql_name} value(s) #{missing.uniq.join(", ")} — " \
          "add them, pin with map:, or absorb with fallback:"
      end

      [from_wire, to_wire(from_wire, aliases)]
    end

    # alias spelling => the value it is read as, checked against what the
    # schema declares — an alias for or onto a value that isn't there is a
    # registration this schema disproves.
    def aliases_for(wire_values)
      declared = wire_values.sort.join(", ")

      @aliases.each do |from, to|
        unless wire_values.include?(from)
          raise GraphWeaver::Error,
            "enum #{graphql_name} has no value #{from.inspect} to alias — its values are #{declared}; " \
            "fix the spelling or drop the alias"
        end
        unless wire_values.include?(to)
          raise GraphWeaver::Error,
            "enum #{graphql_name}: alias #{from.inspect} => #{to.inspect} names no value of #{graphql_name} — " \
            "its values are #{declared}; the target is the spelling that goes on the wire"
        end
      end

      @aliases
    end

    # The register_enum a set of indistinguishable wire values needs, ready to
    # paste. SCREAMING_CASE is the GraphQL convention, so the odd spelling is
    # guessed as the alias — every caller's sentence says to check the direction.
    def self.alias_suggestion(graphql_name, groups, type = nil)
      pairs = groups.flat_map { |group|
        target = group.find { |value| value == value.upcase } || group.first
        (group - [target]).map { |value| "#{value.inspect} => #{target.inspect}" }
      }

      "GraphWeaver.register_enum(#{graphql_name.inspect}#{type ? ", #{type}" : ""}, " \
        "alias: { #{pairs.join(", ")} })"
    end

    private

    # Without a T::Enum there is nothing for map:/requires: to describe, so
    # alias: and fallback: true are the whole registration.
    def alias_only!(map, fallback, requires)
      if fallback && fallback != true
        raise ArgumentError, "register_enum(#{graphql_name.inspect}, fallback: #{fallback.inspect}): the " \
          "generated enum generates its fallback member too, so say fallback: true. To fall back onto a " \
          "member of your own, pass the T::Enum: " \
          "register_enum(#{graphql_name.inspect}, YourEnum, fallback: YourEnum::Unknown)"
      end

      if @aliases.empty? && !fallback
        raise ArgumentError, "register_enum(#{graphql_name.inspect}) says nothing about #{graphql_name} — " \
          "pass the T::Enum to map it onto, alias: { \"old\" => \"NEW\" } to read two wire values as one, " \
          "or fallback: true to absorb values the server adds"
      end

      extra = { map:, requires: }.compact.keys.first
      if extra
        raise ArgumentError,
          "register_enum(#{graphql_name.inspect}) takes no #{extra}: — that describes a T::Enum of your own, " \
          "so pass one: register_enum(#{graphql_name.inspect}, YourEnum, #{extra}: {...})"
      end

      @requires = []
    end

    # Sorted so generated source is stable across registration order.
    def normalize_aliases!(aliases)
      return {} if aliases.nil?

      unless aliases.is_a?(Hash)
        raise ArgumentError, "alias: is a hash of wire value => wire value, got #{aliases.inspect}"
      end

      pairs = aliases.to_h { |from, to| [from.to_s, to.to_s] }

      self_alias = pairs.find { |from, to| from == to }
      if self_alias
        raise ArgumentError, "register_enum(#{graphql_name.inspect}): alias #{self_alias.first.inspect} => " \
          "#{self_alias.last.inspect} reads a value as itself — drop it"
      end

      chained = pairs.keys.find { |from| pairs.value?(from) }
      if chained
        raise ArgumentError, "register_enum(#{graphql_name.inspect}): #{chained.inspect} is both an alias and " \
          "the value an alias points at — an alias can't chain; point every spelling at the one that goes on the wire"
      end

      pairs.sort.to_h
    end

    # member => the one wire value it serializes to. Two spellings on one
    # member with no alias saying which goes out is ambiguous — invert used to
    # pick whichever came last, which for a deprecation pair was the dead one.
    def to_wire(from_wire, aliases)
      canonical = from_wire.except(*aliases.keys)
      ambiguous = canonical.group_by { |_, member| member }.select { |_, pairs| pairs.size > 1 }
      if ambiguous.any?
        member, = ambiguous.first
        groups = ambiguous.values.map { |pairs| pairs.map(&:first) }
        more = ambiguous.size - 1
        raise GraphWeaver::Error,
          "enum #{graphql_name}: #{groups.first.join(" and ")} both map onto the #{type} member " \
          "#{member.serialize.to_s.inspect}#{" (and #{more} more)" unless more.zero?} — say which spelling " \
          "goes on the wire:\n  #{EnumType.alias_suggestion(graphql_name, groups, type)}"
      end

      canonical.invert
    end

    # "CAT" matches serialize "cat"; "NOT_FOUND" matches "not_found"
    def infer(wire)
      @type.values.find { |member| normalize(member.serialize.to_s) == normalize(wire) }
    end

    def normalize(value)
      value.downcase.delete("_")
    end
  end

  # The enum half of one graph's registrations — see Codegen::Registry.
  class Registry
    # Map a GraphQL enum onto an app-owned T::Enum, fold two of its wire
    # spellings into one value, or absorb the ones the server hasn't told you
    # about yet (see EnumType). The one implementation —
    # GraphWeaver.register_enum is a delegate, so the same call reaches it
    # whichever door you came in by.
    #
    # A value map is a natural third *positional* guess, and Ruby's arity
    # complaint ("given 3, expected 2") never mentions the keyword.
    def register_enum(graphql_name, type = nil, positional_map = nil, map: nil, fallback: nil, requires: nil,
      alias: nil)
      if positional_map
        raise GraphWeaver::Error, "register_enum: the value map is a keyword — " \
          "register_enum(#{graphql_name.inspect}, #{type}, map: {...})"
      end

      # `alias` is a Ruby keyword, so the parameter is only readable through binding
      aliases = binding.local_variable_get(:alias)
      enum_registry[graphql_name.to_s] = EnumType.new(graphql_name, type, map:, fallback:, requires:, aliases:)
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

  # codegen's own record of a register_enum mapping
  private_constant :EnumType
end
