# typed: true
# frozen_string_literal: true

require_relative "inflect"

module GraphWeaver
  # Included in generated response structs. GraphQL's camelCase fields
  # become snake_case props, and reaching for the wire name is a classic
  # stumble — result.nameWithOwner instead of result.name_with_owner.
  # Catch the miss and point at the prop that does exist. (Typed call
  # sites get this hint earlier, from srb tc.)
  module Hints
    include Kernel # for sorbet: hosts are Objects

    def method_missing(name, *args, &block)
      prop = GraphWeaver::Inflect.underscore(name.to_s)
      if prop != name.to_s && args.empty? && respond_to?(prop)
        raise NoMethodError,
          "undefined method '#{name}' for #{self.class} — GraphQL fields generate snake_case props; use '#{prop}'"
      end

      super
    end
  end
end
