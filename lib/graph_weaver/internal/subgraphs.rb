# typed: true
# frozen_string_literal: true

require "graphql"

require_relative "../schema_loader"
require_relative "schemas"

module GraphWeaver
  module Internal
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
    # Neither of the two ways detection can come up short is a reason to
    # refuse a whole suite, because neither is a fact about the query in
    # hand. **No match** means the subgraph runs in another process, which is
    # routine mid-migration. **Two matches** means two loaded classes fit the
    # evidence equally, and picking one would be the guess this module exists
    # to avoid. Both leave the subgraph unserved, and {Router} refuses the
    # query that reaches its fields — each with its own fix.
    #
    # `"reviews" => :fake` asks for schema-correct fabricated data instead of
    # that refusal (see {FakeSubgraph}).
    #
    # A map you pass explicitly is a claim rather than a derivation, so it
    # goes through the same check *and refuses at construction* — a swapped
    # pair fails there rather than as a mystery three fetches later.
    module Subgraphs
      # how many coordinates a message names before it says "and N more"
      SAMPLE = 5

      # answer this subgraph with fabricated data rather than refusing
      FAKE = :fake

      # What detection settled and what it couldn't: `served` is
      # { "accounts" => Accounts::Schema, … } (with FAKE for a faked one),
      # `ambiguous` is { "reviews" => ["App::Reviews::Schema", …] } for the
      # ones several loaded classes fit. A subgraph in neither is absent.
      Resolution = Struct.new(:served, :ambiguous)

      class << self
        # Names in `given` skip detection (:fake included); the rest are
        # derived, and both go through the same check.
        def resolve(table, given = nil, schemas: nil)
          named = table.named_subgraphs(given)
          searched = schemas || Schemas.loaded
          resolution = Resolution.new({}, {})
          table.subgraphs.each do |name|
            if named.key?(name)
              resolution.served[name] = check!(table, name, named[name])
              next
            end

            found = candidates(table, name, searched)
            next resolution.served[name] = found.first if found.one?
            # by name: a dev reload leaves two class objects spelled the same,
            # and naming one of them twice reads as a bug in the message
            resolution.ambiguous[name] = found.map(&:name).uniq.sort if found.any?
          end
          resolution
        end

        # every loaded schema that defines what the table says `name` resolves
        def candidates(table, name, schemas = Schemas.loaded)
          wanted = expected(table, name)
          schemas.select { |schema| wanted.all? { |coordinate| Schemas.defines?(schema, coordinate) } }
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
          expected(table, name).reject { |coordinate| Schemas.defines?(schema, coordinate) }
        end

        # Is this subgraph served in this process? Exactly one candidate is
        # what that means: none is somebody else's service, and several is a
        # question only the caller can answer, so neither is something a suite
        # can run against.
        def served?(table, name, schemas = Schemas.loaded)
          candidates(table, name, schemas).one?
        end

        private

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
