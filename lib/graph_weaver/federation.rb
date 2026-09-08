# typed: true
# frozen_string_literal: true

require "graphql"

require_relative "schema_loader"
require_relative "schemas"

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
    # A supergraph is routinely only **partly local** — the rest served by
    # another process, or answered with fabricated data ({Testing::Subgraphs}
    # `=> :fake`). Neither can be compared against anything, so the report
    # names three states rather than two: checked, not here, and faked. A
    # clean result that didn't say what it couldn't see would be actively
    # misleading on the graphs this is for.
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

      # subgraphs answered with fabricated data, so there's no real schema
      # behind them to compare against
      attr_reader :faked

      # every subgraph that was actually compared
      attr_reader :checked

      # supergraph: the composed SDL (a path or the content); defaults to
      # the conventional dump. subgraphs: the same map {Testing::Router}
      # takes — a named schema skips detection, `:fake` (like anything else
      # that isn't a schema class) says there's nothing real to compare.
      # schemas: overrides which loaded schemas detection searches — by
      # default every named GraphQL::Schema in the process.
      def initialize(supergraph: nil, subgraphs: nil, schemas: nil)
        source = (supergraph || GraphWeaver::SchemaLoader.locate_path).to_s
        @table = GraphWeaver::SchemaLoader.routing_table(source)
        # SDL passed as content has no name to print — asked the way the
        # loader asks it, which a one-line supergraph doesn't fool
        @source = GraphWeaver::SchemaLoader.sdl_content?(source) ? "the supergraph" : source
        @given = @table.named_subgraphs(subgraphs)
        @schemas = schemas || GraphWeaver::Schemas.loaded
        @stale = {}
        @uncomposed = {}
        @skipped = {}
        @faked = []
        @checked = []
        compare
      end

      # whether the supergraph and the code here disagree — what CI gates on
      def drift? = @stale.any? || @uncomposed.any?

      # Nothing was compared, so "no drift" is vacuous: the gate would pass
      # whatever the subgraphs said. Categorically different from "checked 3
      # of 4" — that one checked something, and a partly-local supergraph is
      # a supported setup.
      def vacuous? = @checked.empty?

      # JSON-ready: the drift, keyed by coordinate, and what wasn't compared.
      # Empty stale + uncomposed means every subgraph reached was accurate;
      # `skipped` and `faked` say which weren't reached, and why.
      def to_h
        {
          "stale" => @stale,
          "uncomposed" => @uncomposed,
          "skipped" => @skipped,
          "faked" => @faked,
        }
      end

      def report
        return "#{@source} names no subgraphs" if @table.subgraphs.empty?

        [headline, *section(STALE, @stale), *section(UNCOMPOSED, @uncomposed),
          *skipped_section, *faked_section].join("\n")
      end
      alias to_s report

      def inspect
        "#<#{self.class.name} #{@stale.size} stale, #{@uncomposed.size} uncomposed, " \
          "#{@checked.size}/#{@table.subgraphs.size} checked>"
      end

      private

      STALE = "stale — the supergraph carries these, no schema here defines them (recompose):"
      UNCOMPOSED = "not composed in — a schema here defines these, the supergraph doesn't carry them:"

      def compare
        @table.subgraphs.each do |name|
          next unless (fitting = comparable(name))

          @checked << name
          record_stale(name, fitting)
          record_uncomposed(name, fitting)
        end
      end

      # The schemas to compare this subgraph against, or nil when there are
      # none — recording why. A named schema is taken as given; otherwise
      # the schemas defining every type the supergraph says it declares are
      # the ones that could be it.
      def comparable(name)
        if @given.key?(name)
          schema = @given[name]
          # :fake, and anything else that isn't a schema class, has nothing
          # real behind it
          return [schema] if schema.is_a?(Class)

          @faked << name
          return
        end

        anchors = identifying_types(name)
        fitting = anchors.empty? ? [] : @schemas.select { |s| anchors.all? { |t| s.get_type(t) } }
        return fitting if fitting.any?

        @skipped[name] = anchors
        nil
      end

      def declared_types(name)
        @table.types.select { |type| @table.declared_in(type).include?(name) }
      end

      # The types that recognize this subgraph's schema: the ones it
      # declares, minus the roots every subgraph has.
      def identifying_types(name) = declared_types(name) - ROOTS

      # Fields the supergraph says this subgraph resolves, but none of its
      # candidate schemas still defines. Every declared field, not only the
      # explicitly routed ones — a field with no @join__field lives wherever
      # its type does, and dropping one is exactly the drift this looks for.
      def record_stale(name, fitting)
        declared_types(name).each do |type_name|
          @table.declared_fields(type_name).each do |field_name|
            next unless @table.owners(type_name, field_name).include?(name)

            coordinate = "#{type_name}.#{field_name}"
            next if fitting.any? { |schema| GraphWeaver::Schemas.defines?(schema, coordinate) }

            (@stale[coordinate] ||= []) << name
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
        members =
          if type.respond_to?(:fields) then type.fields.keys
          elsif type.respond_to?(:arguments) then type.arguments.keys
          else []
          end

        members.reject { |field| field.start_with?("_") }
      end

      def headline
        counts = [
          ("#{@stale.size} stale" if @stale.any?),
          ("#{@uncomposed.size} not composed in" if @uncomposed.any?),
        ].compact
        # "matches the schemas here" over nothing compared is the one verdict
        # that reads as a pass and isn't one
        verdict =
          if counts.any? then counts.join(", ")
          elsif vacuous? then "compared against nothing here"
          else "matches the schemas here"
          end
        "#{@source}: #{verdict} " \
          "(checked #{@checked.size} of #{@table.subgraphs.size} subgraphs)"
      end

      def section(title, entries)
        return [] if entries.empty?

        ["", title, *entries.sort.map { |coordinate, who| "  #{coordinate} (#{who.join(", ")})" }]
      end

      # Not an error — a supergraph is routinely only partly local — but a
      # clean report has to say what it didn't look at.
      def skipped_section
        return [] if @skipped.empty?

        ["", "not checked — nothing here defines what the supergraph says these declare " \
          "(running elsewhere, or the type is gone):",
          *@skipped.sort.map { |name, types| "  #{name} (#{types.empty? ? "root types only" : types.join(", ")})" }]
      end

      def faked_section
        return [] if @faked.empty?

        ["", "not checked — answered with fabricated data:", *@faked.sort.map { |name| "  #{name}" }]
      end
    end
  end
end
