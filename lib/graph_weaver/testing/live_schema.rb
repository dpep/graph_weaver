# typed: true
# frozen_string_literal: true

require "graphql"

require_relative "subgraphs"

module GraphWeaver
  module Testing
    # Which loaded schema class serves the graph a client talks to.
    #
    # Only a live schema class has resolvers — an introspected or dumped
    # schema is type information — so :in_process has to find the class
    # behind the schema it was handed. It's **derived from what each one
    # defines**: a schema serves `reference` when it defines every type and
    # field the reference declares. That's evidence, not a guess, and it's
    # the rule {Subgraphs} already matches subgraphs on — matching on class
    # names would be a guess, and a wrong one points a suite at the wrong
    # resolvers and still passes.
    #
    # So exactly one match is used, and anything else refuses: two matches
    # name both, none names what it looked for.
    module LiveSchema
      # how many coordinates a message names before it says "and N more"
      SAMPLE = 5

      class << self
        # the one loaded schema class defining everything `reference` declares
        def detect(reference, schemas = Subgraphs.loaded)
          found = candidates(reference, schemas)
          return found.first if found.one?

          if found.any?
            raise GraphWeaver::Error, "#{found.size} loaded schemas define everything this graph " \
              "declares (#{found.map(&:name).sort.join(", ")}) — set " \
              "GraphWeaver::Testing.config.schema to the one you mean"
          end

          # the Zeitwerk case: detection can only see what's loaded, and a
          # schema nothing has referenced yet isn't
          raise GraphWeaver::Error, "no loaded GraphQL::Schema defines everything this graph " \
            "declares (#{sample(coordinates(reference))}) — set " \
            "GraphWeaver::Testing.config.schema = MySchema. An autoloaded schema isn't loaded " \
            "until something references it, so in Rails either name it or eager-load first. " \
            "(A federated graph has no one schema class — tag those examples graphql: :router.)"
        end

        def candidates(reference, schemas = Subgraphs.loaded)
          wanted = coordinates(reference)
          schemas.select { |schema| wanted.all? { |coordinate| defines?(schema, coordinate) } }
        end

        # "Type" for every type it declares, "Type.field" for every field —
        # the evidence a match is judged on. Introspection is skipped: every
        # schema has it, so it distinguishes nothing.
        def coordinates(reference)
          reference.types.each_value.flat_map do |type|
            next [] if type.graphql_name.start_with?("__")

            fields = type.respond_to?(:fields) ? type.fields.keys : []
            [type.graphql_name] + fields.map { |field| "#{type.graphql_name}.#{field}" }
          end
        end

        private

        def defines?(schema, coordinate)
          type_name, field_name = coordinate.split(".", 2)
          type = schema.get_type(type_name) or return false
          return true unless field_name

          type.respond_to?(:fields) && type.fields.key?(field_name)
        end

        def sample(list)
          return list.join(", ") if list.size <= SAMPLE

          "#{list.first(SAMPLE).join(", ")} and #{list.size - SAMPLE} more"
        end
      end
    end
  end
end
