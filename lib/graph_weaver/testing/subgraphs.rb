# typed: true
# frozen_string_literal: true

require "graphql"

require_relative "../schema_loader"
require_relative "../schemas"

module GraphWeaver
  module Testing
    # Which Ruby schema serves which subgraph — for the subgraphs this
    # process serves at all.
    #
    # You can name them yourself, but the map is boilerplate you then have to
    # keep right — so by default they're **derived from what each schema
    # defines**. A schema serves subgraph `s` when it defines every type and
    # field the routing table says `s` resolves. That's evidence, not a
    # guess: matching on class names would be one (`Accounts::Schema`,
    # `AccountsSchema`, `Subgraphs::Accounts`), and a wrong guess points a
    # suite at the wrong resolvers and still passes.
    #
    # Two matches refuse, naming both — both fit the evidence, so picking
    # either would be the guess this module exists to avoid. **No match is
    # not a refusal**: a supergraph is routinely only partly local, the rest
    # served by another process, so a subgraph nothing here defines is left
    # out of the map. Only a query that reaches its fields fails, at plan
    # time — see {Router}.
    #
    # `"reviews" => :fake` asks for schema-correct fabricated data instead of
    # that refusal (see {FakeSubgraph}).
    #
    # The same check runs over a map you pass explicitly, which is how a
    # swapped pair fails at construction rather than as a mystery three
    # fetches later.
    module Subgraphs
      # how many coordinates a message names before it says "and N more"
      SAMPLE = 5

      # answer this subgraph with fabricated data rather than refusing
      FAKE = :fake

      class << self
        # { "accounts" => Accounts::Schema, … } for the subgraphs this
        # process serves — one nothing defines is absent, and left out.
        # Names in `given` skip detection (:fake included); the rest are
        # derived, and both go through the same check.
        def resolve(table, given = nil, schemas: nil)
          named = table.named_subgraphs(given)
          searched = schemas || GraphWeaver::Schemas.loaded
          table.subgraphs.filter_map do |name|
            served = named.key?(name) ? check!(table, name, named[name]) : detect(table, name, searched)
            [name, served] if served
          end.to_h
        end

        # every loaded schema that defines what the table says `name` resolves
        def candidates(table, name, schemas = GraphWeaver::Schemas.loaded)
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
          expected(table, name).reject { |coordinate| GraphWeaver::Schemas.defines?(schema, coordinate) }
        end

        private

        # The schema serving `name`, or nil when nothing here does — the
        # subgraph is somebody else's, which is not an error until a query
        # asks for it.
        def detect(table, name, schemas)
          found = candidates(table, name, schemas)
          return found.first if found.one?
          return if found.empty?

          # by name: a dev reload leaves two class objects spelled the same,
          # and naming one of them twice reads as a bug in the message
          names = found.map(&:name).uniq.sort
          raise GraphWeaver::ConfigurationError, "#{names.size} loaded schemas define everything the " \
            "supergraph says #{name.inspect} resolves (#{names.join(", ")}) — pass subgraphs: naming " \
            "the one you mean"
        end

        def check!(table, name, schema)
          return FAKE if schema == FAKE

          if schema.is_a?(Symbol)
            raise GraphWeaver::ConfigurationError, "subgraphs[#{name.inspect}] is #{schema.inspect} — " \
              "the only symbol an entry takes is #{FAKE.inspect}, which answers it with fabricated data"
          end

          verify!(table, name, schema)
        end

        def verify!(table, name, schema)
          gaps = missing(table, name, schema)
          return schema if gaps.empty?

          raise GraphWeaver::ConfigurationError, "subgraphs[#{name.inspect}] is " \
            "#{schema.name || schema.inspect}, which doesn't define #{sample(gaps)} — the supergraph " \
            "says #{name} resolves them. Did two entries get swapped?"
        end

        def sample(list)
          return list.join(", ") if list.size <= SAMPLE

          "#{list.first(SAMPLE).join(", ")} and #{list.size - SAMPLE} more"
        end
      end
    end
  end
end
