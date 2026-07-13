# typed: true
# frozen_string_literal: true

module GraphWeaver
  # GraphQL names are plain camelCase/SCREAMING_SNAKE — no acronym edge
  # cases, so minimal inflection beats an activesupport dependency
  module Inflect
    module_function

    def underscore(name)
      name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def camelize(name)
      # reject: leading underscores split into empty parts (_Service, _and)
      name.split("_").reject(&:empty?).map { |part| "#{part[0].upcase}#{part[1..]}" }.join
    end
  end
end
