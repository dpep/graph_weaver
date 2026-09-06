# typed: true
# frozen_string_literal: true

require "graphql"

require_relative "../schema_loader"

module GraphWeaver
  module Testing
    # Which Ruby schema serves which subgraph.
    #
    # {Router} needs one schema per subgraph in the supergraph. You can name
    # them yourself, but the map is boilerplate you then have to keep right —
    # so by default they're **derived from what each schema defines**. A
    # schema serves subgraph `s` when it defines every type and field the
    # routing table says `s` resolves. That's evidence, not a guess: matching
    # on class names would be one (`Accounts::Schema`, `AccountsSchema`,
    # `Subgraphs::Accounts`), and a wrong guess points a suite at the wrong
    # resolvers and still passes.
    #
    # So exactly one match is used, and anything else refuses: two matches
    # name both, none names what it looked for. The same check runs over a
    # map you pass explicitly, which is how a swapped pair fails at
    # construction rather than as a mystery three fetches later.
    module Subgraphs
      # how many coordinates a message names before it says "and N more"
      SAMPLE = 5

      class << self
        # { "accounts" => Accounts::Schema, … } for every subgraph in the
        # table. Names in `given` skip detection; the rest are derived, and
        # both go through the same check.
        def resolve(table, given = nil, schemas: nil)
          named = (given || {}).to_h { |name, schema| [name.to_s, schema] }
          unknown = named.keys - table.subgraphs
          if unknown.any?
            raise ArgumentError, "subgraphs: names #{unknown.join(", ")}, which this supergraph " \
              "doesn't have (its subgraphs are #{table.subgraphs.join(", ")})"
          end

          searched = schemas || loaded
          table.subgraphs.to_h do |name|
            [name, named.key?(name) ? verify!(table, name, named[name]) : detect(table, name, searched)]
          end
        end

        # every loaded schema that defines what the table says `name` resolves
        def candidates(table, name, schemas = loaded)
          schemas.select { |schema| missing(table, name, schema).empty? }
        end

        # The schema coordinates the supergraph says `name` resolves — "Type"
        # for one it declares, "Type.field" for one it answers. This is the
        # evidence a match is judged on.
        def expected(table, name)
          table.types.flat_map do |type_name|
            next [] unless table.declared_in(type_name).include?(name)

            fields = table.fields(type_name).select { |field| table.owners(type_name, field).include?(name) }
            [type_name] + fields.map { |field| "#{type_name}.#{field}" }
          end
        end

        # which of them `schema` doesn't define
        def missing(table, name, schema)
          expected(table, name).reject { |coordinate| defines?(schema, coordinate) }
        end

        # Every named GraphQL::Schema in the process. An anonymous one is
        # graphql-ruby building from SDL — the router's own view of the
        # supergraph is one — and never an app's subgraph.
        def loaded
          descendants(GraphQL::Schema).select(&:name)
        end

        private

        def detect(table, name, schemas)
          found = candidates(table, name, schemas)
          return found.first if found.one?

          if found.any?
            raise ArgumentError, "#{found.size} loaded schemas define everything the supergraph says " \
              "#{name.inspect} resolves (#{found.map(&:name).sort.join(", ")}) — pass subgraphs: naming " \
              "the one you mean"
          end

          # the Zeitwerk case: detection can only see what's loaded, and a
          # schema nothing has referenced yet isn't. Saying so here is the
          # difference between a puzzle and a one-line fix.
          raise ArgumentError, "no loaded GraphQL::Schema defines everything the supergraph says " \
            "#{name.inspect} resolves (#{sample(expected(table, name))}) — pass " \
            "subgraphs: { #{name.inspect} => YourSchema }. An autoloaded schema isn't loaded until " \
            "something references it, so in Rails either name it or eager-load first " \
            "(rake graph_weaver:federation:subgraphs shows what detection can see)."
        end

        def verify!(table, name, schema)
          gaps = missing(table, name, schema)
          return schema if gaps.empty?

          raise ArgumentError, "subgraphs[#{name.inspect}] is #{schema.name || schema.inspect}, " \
            "which doesn't define #{sample(gaps)} — the supergraph says #{name} resolves them. " \
            "Did two entries get swapped?"
        end

        def defines?(schema, coordinate)
          type_name, field_name = coordinate.split(".", 2)
          type = schema.get_type(type_name) or return false
          return true unless field_name

          type.respond_to?(:fields) && type.fields.key?(field_name)
        end

        def descendants(klass)
          klass.subclasses.flat_map { |subclass| [subclass] + descendants(subclass) }
        end

        def sample(list)
          return list.join(", ") if list.size <= SAMPLE

          "#{list.first(SAMPLE).join(", ")} and #{list.size - SAMPLE} more"
        end
      end
    end
  end
end
