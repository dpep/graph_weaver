# typed: true
# frozen_string_literal: true

require_relative "../internal"

module GraphWeaver
  module Internal
    # Whether an `overrides:` key names something the schema actually has.
    # Both doors need the answer — Testing.configure checks the suite-wide
    # ones while the block that set them is still on the stack, and a fake
    # built with its own checks them then.
    module Overrides
      class << self
        # Override keys name schema coordinates: "Type.field", or a bare
        # field name matching that field on any type. Anything else is a typo
        # that would silently fabricate random data instead of pinning a
        # value.
        def validate!(schema, overrides)
          overrides.each_key { |key| validate_key!(schema, key.to_s) }
        end

        private

        def validate_key!(schema, key)
          type_name, field_name = key.split(".", 2)
          # introspection fields (__typename) are real but absent from #fields
          return if (field_name || type_name).start_with?("__")

          if field_name.nil?
            known = field_names(schema)
            return if known.include?(type_name)

            bad!(key, "matches no field in this schema", known, type_name)
          end

          type = schema.get_type(type_name)
          unless type.respond_to?(:fields)
            bad!(key, "names no object type in this schema", schema.types.keys, type_name)
          end
          return if type.fields.key?(field_name)

          bad!(key, "is not a field of #{type_name}", type.fields.keys, field_name)
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
