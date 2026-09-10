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

        # A pin that's a proc is handed the seeded Random when it takes one
        # and called bare when it doesn't, so a varying pin still reproduces
        # under `rspec --seed`.
        def resolve(value, rng)
          return value unless value.is_a?(Proc)

          value.arity.zero? ? value.call : value.call(rng)
        end

        private

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
            bad!(key, "matches no type or field in this schema", dictionary, type_name)
          end

          type = schema.get_type(type_name)
          unless type.respond_to?(:fields)
            bad!(key, "names no object type in this schema", schema.types.keys, type_name)
          end
          return if type.fields.key?(field_name)

          bad!(key, "is not a field of #{type_name}", type.fields.keys, field_name)
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

        def bad!(key, problem, dictionary, term)
          suggestion = Util.did_you_mean(dictionary, term)
          hint = suggestion ? " — did you mean '#{suggestion}'?" : ""
          raise GraphWeaver::Error, "override key #{key.inspect} #{problem}#{hint}"
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
