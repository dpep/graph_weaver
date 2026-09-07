# typed: true
# frozen_string_literal: true

require "graphql"

require_relative "schema_loader"

module GraphWeaver
  # Federation checks that need no network — the supergraph you committed,
  # read against the subgraph schemas running in this process.
  module Federation
    # Has someone changed a subgraph without recomposing the supergraph?
    #
    #      rake graph_weaver:federation:diff SUPERGRAPH=supergraph.graphql
    #
    # A committed supergraph is a snapshot of a composition. Change a
    # subgraph and skip the recompose and it quietly describes a graph that
    # no longer exists — the failure this catches, locally and before merge,
    # where {SchemaLoader.stale?} needs the server and answers a different
    # question (has the *server* drifted from my dump).
    #
    # Both directions, because they mean opposite things:
    #
    # - **stale** — the supergraph carries `Product.weight` and no schema
    #   here defines it any more. Recompose.
    # - **not composed in** — a schema here defines `Product.dimensions` and
    #   the supergraph doesn't carry it. Publish the subgraph.
    #
    # What "defines" means: a coordinate is compared only against the
    # schemas that could *be* the subgraph the supergraph attributes it to —
    # the ones defining every non-root type it declares. Exact field-set
    # equality would be too strict in both directions: a subgraph carries
    # federation plumbing (`_entities`, `_service`) the supergraph never
    # has, and a field can legitimately sit in more than one subgraph
    # (`@external` copies, `@shareable`). So the uncomposed side reports
    # only a field the supergraph's type doesn't carry **at all** — not one
    # it merely attributes elsewhere — and underscore-prefixed fields never
    # count.
    #
    # Subgraphs whose schemas aren't in this process can't be checked, so
    # they're skipped and listed: a clean report that quietly checked half
    # the graph is worse than no report.
    class Drift
      # Composition names the root types conventionally, and every subgraph
      # declares one — so a root can't tell subgraphs apart, and a schema
      # is recognized by the other types it defines.
      ROOTS = %w[Query Mutation Subscription].freeze

      # { "Product.weight" => ["products"] } — the supergraph says these
      # subgraphs resolve it, and no schema of theirs here defines it
      attr_reader :stale

      # { "Product.dimensions" => ["Products::Schema"] } — defined here,
      # absent from the supergraph
      attr_reader :uncomposed

      # { "inventory" => ["Warehouse"] } — subgraph => the types that would
      # identify it, which nothing here defines
      attr_reader :skipped

      # every subgraph that was actually compared
      attr_reader :checked

      # supergraph: the composed SDL (a path or the content); defaults to
      # the conventional dump. schemas: overrides which loaded schemas
      # count — by default every named GraphQL::Schema in the process.
      def initialize(supergraph: nil, schemas: nil)
        source = (supergraph || GraphWeaver::SchemaLoader.locate_path).to_s
        @table = GraphWeaver::SchemaLoader.routing_table(source)
        # SDL passed as content has no name to print
        @source = source.include?("\n") ? "the supergraph" : source
        @schemas = schemas || loaded_schemas
        @stale = {}
        @uncomposed = {}
        @skipped = {}
        @checked = []
        compare
      end

      # whether the supergraph and the code here disagree — what CI gates on
      def drift? = @stale.any? || @uncomposed.any?

      # JSON-ready: the three lists, keyed by coordinate (subgraph, for
      # skipped). Empty stale + uncomposed means every subgraph reached was
      # accurate; `skipped` says which weren't reached.
      def to_h
        { "stale" => @stale, "uncomposed" => @uncomposed, "skipped" => @skipped }
      end

      def report
        return "#{@source} names no subgraphs" if @table.subgraphs.empty?

        [headline, *section(STALE, @stale), *section(UNCOMPOSED, @uncomposed), *skipped_section]
          .join("\n")
      end
      alias to_s report

      def inspect
        "#<#{self.class.name} #{@stale.size} stale, #{@uncomposed.size} uncomposed, " \
          "#{@skipped.size} skipped>"
      end

      private

      STALE = "stale — the supergraph carries these, no schema here defines them (recompose):"
      UNCOMPOSED = "not composed in — a schema here defines these, the supergraph doesn't carry them:"

      def compare
        @table.subgraphs.each do |name|
          anchors = identifying_types(name)
          fitting = anchors.empty? ? [] : @schemas.select { |s| anchors.all? { |t| s.get_type(t) } }
          if fitting.empty?
            @skipped[name] = anchors
            next
          end

          @checked << name
          record_stale(name, fitting)
          record_uncomposed(name, fitting)
        end
      end

      def declared_types(name)
        @table.types.select { |type| @table.declared_in(type).include?(name) }
      end

      # The types that recognize this subgraph's schema: the ones it
      # declares, minus the roots every subgraph has.
      def identifying_types(name) = declared_types(name) - ROOTS

      # fields the supergraph says this subgraph resolves, but none of its
      # candidate schemas still defines
      def record_stale(name, fitting)
        declared_types(name).each do |type_name|
          @table.fields(type_name).each do |field_name|
            next unless @table.owners(type_name, field_name).include?(name)
            next if fitting.any? { |schema| defines?(schema, type_name, field_name) }

            (@stale["#{type_name}.#{field_name}"] ||= []) << name
          end
        end
      end

      # fields those schemas define on this subgraph's types that the
      # supergraph's own type doesn't carry
      def record_uncomposed(name, fitting)
        declared_types(name).each do |type_name|
          fitting.each do |schema|
            local_fields(schema, type_name).each do |field_name|
              next if @table.declares?(type_name, field_name)

              entry = (@uncomposed["#{type_name}.#{field_name}"] ||= [])
              entry << schema.name unless entry.include?(schema.name)
            end
          end
        end
      end

      # a schema's own fields on a type, minus federation's and
      # introspection's plumbing (_entities, _service, __typename) — which
      # no supergraph carries and which is never drift
      def local_fields(schema, type_name)
        type = schema.get_type(type_name)
        return [] unless type.respond_to?(:fields)

        type.fields.keys.reject { |field| field.start_with?("_") }
      end

      def defines?(schema, type_name, field_name)
        type = schema.get_type(type_name)
        type.respond_to?(:fields) && type.fields.key?(field_name)
      end

      def loaded_schemas
        require "graph_weaver/testing"
        GraphWeaver::Testing::Subgraphs.loaded
      end

      def headline
        counts = [
          ("#{@stale.size} stale" if @stale.any?),
          ("#{@uncomposed.size} not composed in" if @uncomposed.any?),
        ].compact
        verdict = counts.empty? ? "matches the schemas loaded here" : counts.join(", ")
        "#{@source} vs #{@checked.size} of #{@table.subgraphs.size} subgraphs: #{verdict}"
      end

      def section(title, entries)
        return [] if entries.empty?

        ["", title, *entries.sort.map { |coordinate, who| "  #{coordinate} (#{who.join(", ")})" }]
      end

      def skipped_section
        return [] if @skipped.empty?

        # not necessarily an error — a service composed into the graph can
        # run somewhere else entirely — but a clean report has to say what
        # it didn't look at
        ["", "skipped — nothing loaded here defines what the supergraph says these declare " \
          "(running elsewhere, or the type is gone):",
          *@skipped.sort.map { |name, types| "  #{name} (#{types.empty? ? "root types only" : types.join(", ")})" }]
      end
    end
  end
end
