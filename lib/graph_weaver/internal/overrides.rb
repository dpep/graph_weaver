# typed: true
# frozen_string_literal: true

require_relative "../internal"

module GraphWeaver
  module Internal
    # What a pin is: the key it may be written under, and how its value is
    # read. Both doors need the answer — Testing.configure checks the
    # suite-wide ones while the block that set them is still on the stack,
    # and a fake built with its own checks them then.
    module Overrides
      # The key a per-field Hash (`list_size:`, `null_chance:`) says its
      # fallback under — everything it doesn't name.
      DEFAULT_KEY = "default"

      class << self
        # A pin key names something in the schema: a type ("Money",
        # "Person"), a "Type.field" coordinate, or a bare field name
        # matching that field on any type. Anything else is a typo that
        # would silently fabricate random data instead of pinning a value.
        def validate!(schema, overrides)
          overrides.each do |key, value|
            validate_arity!(key, value)
            validate_key!(schema, key.to_s)
          end
        end

        # Whether `key` reads as a reference into the schema rather than a
        # plain word — what tells a pin from an option at a fake's door, where
        # both arrive as the same keywords. A "Type.field" coordinate can only
        # be a pin; a bare word is one when the schema knows it. Whether the
        # reference RESOLVES is validate!'s question, so a coordinate naming
        # no type is still a pin and gets that refusal rather than "unknown
        # option".
        #
        # Casing can't decide it: Hasura's types are lowercase, and
        # `pokemon_v2_pokemon` read as a misspelled option.
        def schema_reference?(schema, key)
          key = key.to_s
          return true if key.include?(".") || key.start_with?("__")

          !schema.get_type(key).nil? || field_names(schema).include?(key)
        end

        # Every name a pin may be keyed by — the dictionary a refusal guesses
        # from when a key is neither a pin nor an option.
        def pin_names(schema) = schema.types.keys + field_names(schema)

        # A Hash `list_size:` sizes one list at a time, keyed the way a pin is
        # minus the bare type name: a type says nothing about how long any one
        # of its fields is.
        def validate_list_size!(schema, list_size)
          reaches = ->(type) { type.list? }
          validate_per_field!(schema, list_size, "list_size",
            reaches:, unreached: "is not a list and has no length to set — name a list field") do |value|
            "an Integer or a Range of them, neither negative — how long an unbounded list is" unless
              length?(value)
          end
        end

        # A Hash `null_chance:` is keyed the same way, one nullable field at a
        # time.
        def validate_null_chance!(schema, null_chance)
          reaches = method(:nullable_anywhere?)
          validate_per_field!(schema, null_chance, "null_chance",
            reaches:, unreached: "can never come back null — name a nullable field") do |value|
            "a number from 0 to 1 — how often a nullable field comes back null" unless
              value.is_a?(Numeric) && (0..1).cover?(value)
          end
        end

        # A pin that's a proc is handed the seeded Random when it takes one
        # and called bare when it doesn't, so a varying pin still reproduces
        # under `rspec --seed`.
        def resolve(value, rng)
          return value unless value.is_a?(Proc)

          value.arity.zero? ? value.call : value.call(rng)
        end

        private

        # The two shapes both per-field options take: one value for every
        # field, or a Hash keyed by field — a "Type.field" coordinate or a
        # bare field name — with DEFAULT_KEY for the rest. The block says
        # what a value has to be, in the words the refusal uses, and says it
        # of both shapes: a plain `null_chance: 7` used to sail through and
        # null everything, a plain `list_size: "3"` to die inside the
        # fabricator.
        def validate_per_field!(schema, option, name, reaches:, unreached:)
          unless option.is_a?(Hash)
            refuse_value!(name, nil, option, yield(option))
            return
          end

          option.each do |key, value|
            refuse_value!(name, key, value, yield(value))
            next if key.to_s == DEFAULT_KEY

            label = "#{name}: key"
            validate_field_key!(schema, key.to_s, label)
            reaches!(schema, key.to_s, label, reaches, unreached)
          end
        end

        # A key naming a field the option can never reach is inert, which is
        # the silent green every other key check exists to stop: the
        # fabricator asks `null_chance` at nullable positions only and
        # `list_size` at lists only, so it never looks this key up.
        def reaches!(schema, key, label, reaches, unreached)
          types = field_types(schema, key)
          return if types.empty? || types.any? { |type| reaches.call(type) }

          spelled = types.map(&:to_type_signature).uniq.sort.join(", ")
          raise GraphWeaver::Error, "#{label} #{key.inspect} (#{spelled}) #{unreached}, " \
            "or drop the key"
        end

        # Every field a per-field key names: the one a coordinate points at,
        # or every field of that name in the schema for a bare one.
        def field_types(schema, key)
          type_name, field_name = key.split(".", 2)
          # introspection fields (__typename) are real but absent from #fields
          return [] if (field_name || type_name).start_with?("__")
          return [schema.get_type(type_name).fields.fetch(field_name).type] if field_name

          schema.types.each_value.filter_map do |type|
            type.fields[type_name]&.type if type.respond_to?(:fields)
          end
        end

        # Whether null_chance has a position in this type to reach. #non_null?
        # sees through a list wrapper, so `[Pet]!` reads as non-null while its
        # ELEMENTS are what the fabricator nulls.
        def nullable_anywhere?(type)
          return true unless type.non_null?

          inner = type.of_type
          inner.list? && nullable_anywhere?(inner.of_type)
        end

        def refuse_value!(name, key, value, wanted)
          return unless wanted

          raise GraphWeaver::Error, "#{name}:#{" #{key.to_s.inspect}" if key} must be #{wanted} — " \
            "got #{value.inspect}"
        end

        # A length is a count the fabricator can build an Array of: Array.new(-1)
        # is "negative array size" out of its guts, and a Range the seeded rng
        # can't sample (endless, or beginless) is worse.
        def length?(value)
          case value
          when Integer then !value.negative?
          when Range then [value.begin, value.end].all? { |edge| edge.is_a?(Integer) && !edge.negative? }
          else false
          end
        end

        # A proc taking anything else can't be called at fabrication time,
        # and the ArgumentError it would raise there names no pin.
        def validate_arity!(key, value)
          return unless value.is_a?(Proc) && value.arity > 1

          raise GraphWeaver::Error, "the pin for #{key.inspect} takes no arguments, or one — the " \
            "seeded Random (-> (rng) { ... }); this one takes #{value.arity}"
        end

        def validate_key!(schema, key)
          type_name, field_name = key.split(".", 2)
          # introspection fields (__typename) are real but absent from #fields
          return if (field_name || type_name).start_with?("__")

          if field_name.nil?
            return if (type = schema.get_type(type_name)) && pinnable!(schema, key, type)

            known = field_names(schema)
            return if known.include?(type_name)

            # a leading capital names a type, as it does wherever a pin is written
            dictionary = type_name.match?(/\A[A-Z]/) ? schema.types.keys : known
            bad!("override key", key, "matches no type or field in this schema", dictionary, type_name)
          end

          coordinate!(schema, "override key", key, type_name, field_name)
        end

        # A key naming one FIELD — a "Type.field" coordinate, or a bare field
        # name matching that field on any type.
        def validate_field_key!(schema, key, label)
          type_name, field_name = key.split(".", 2)
          return if (field_name || type_name).start_with?("__")

          if field_name.nil?
            known = field_names(schema)
            return if known.include?(type_name)

            # a type name reads like a reasonable key here — `null_chance: {
            # "Person" => 1.0 }` looks like "null the whole subtree" — and
            # did_you_mean sent it to the nearest FIELD ('person') instead of
            # saying these options are keyed by field
            named = schema.get_type(type_name)
            type_key!(label, key, named) if named
            bad!(label, key, "matches no field in this schema", known, type_name)
          end

          coordinate!(schema, label, key, type_name, field_name)
        end

        def type_key!(label, key, type)
          reach = type.respond_to?(:fields) ? "#{type.graphql_name}.<field>".inspect : "a \"Type.field\" coordinate"
          raise GraphWeaver::Error, "#{label} #{key.inspect} names " \
            "#{type.kind.name.downcase.tr("_", " ")} #{type.graphql_name}, and a key here names " \
            "one field — #{reach}, or a bare field name"
        end

        def coordinate!(schema, label, key, type_name, field_name)
          type = schema.get_type(type_name)
          unless type.respond_to?(:fields)
            bad!(label, key, "names no object type in this schema", schema.types.keys, type_name)
          end
          unless type.fields.key?(field_name)
            bad!(label, key, "is not a field of #{type_name}", type.fields.keys, field_name)
          end

          concrete!(schema, label, key, type, field_name)
        end

        # The abstract-type refusal, in the coordinate form. An interface
        # declares the field, so "Named.name" reads as a key that must work
        # — and it matches nothing: the walk picks a member before it builds
        # a coordinate, so every key it looks up is "Person.name".
        def concrete!(schema, label, key, type, field_name)
          return unless type.kind.abstract?

          members = schema.possible_types(type)
            .map { |member| "#{member.graphql_name}.#{field_name}".inspect }.sort
          raise GraphWeaver::Error, "#{label} #{key.inspect} names #{type.kind.name.downcase} " \
            "#{type.graphql_name}, and a fake only ever holds a concrete type: name the " \
            "concrete type — #{members.join(", ")}"
        end

        # A type pin says what every value of that type is, and the fake only
        # ever holds a concrete one: at an interface or union the walk has
        # already picked a member, so a pin keyed on the abstract name would
        # match nothing and leave the example green.
        def pinnable!(schema, key, type)
          return true if %w[SCALAR ENUM OBJECT].include?(type.kind.name)

          advice = if type.kind.abstract?
            members = schema.possible_types(type).map { |member| member.graphql_name.inspect }.sort
            "pin the concrete type — #{members.join(", ")}"
          else
            "only output types are fabricated"
          end
          raise GraphWeaver::Error, "override key #{key.inspect} names #{type.kind.name.downcase.tr("_", " ")} " \
            "#{type.graphql_name}, and a pin fabricates a scalar, enum or object: #{advice}"
        end

        def bad!(label, key, problem, dictionary, term)
          suggestion = Util.did_you_mean(dictionary, term)
          hint = suggestion ? " — did you mean '#{suggestion}'?" : ""
          raise GraphWeaver::Error, "#{label} #{key.inspect} #{problem}#{hint}"
        end

        # Every output field name in the schema — walked only when a bare key
        # asks for it.
        def field_names(schema)
          schema.types.each_value.flat_map { |type| type.respond_to?(:fields) ? type.fields.keys : [] }.uniq
        end
      end
    end
  end
end
