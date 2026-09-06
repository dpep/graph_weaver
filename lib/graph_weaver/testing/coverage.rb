# typed: true
# frozen_string_literal: true

require "graphql"

require_relative "router"

module GraphWeaver
  module Testing
    # How much of a query set the local {Router} can plan, and — for the rest
    # — exactly what stopped it:
    #
    #      rake graph_weaver:federation:coverage SUPERGRAPH=supergraph.graphql
    #
    # The router refuses every query that crosses a subgraph boundary, so its
    # worth to a suite is one number: the fraction of *your* queries it can
    # answer. Nobody can guess that from outside — it depends on the shape of
    # your graph and the shape of your queries — so measure it before
    # deciding the router is (or isn't) enough.
    #
    # Planning needs the supergraph and nothing else, so this runs without
    # any subgraph being loadable, in CI or on a laptop with the SDL alone.
    class Coverage
      # One query file's verdict: `category` nil means the router can plan
      # it, and `subgraph` is where it runs — "accounts+reviews" when the
      # plan stitches across a boundary.
      Result = Struct.new(:path, :subgraph, :category, :detail)

      # the label each verdict groups under
      LABELS = Unplannable::CATEGORIES
        .transform_values(&:first)
        .merge(invalid: "doesn't validate against the supergraph")
        .freeze

      attr_reader :results

      def initialize(supergraph:, queries: GraphWeaver.queries_path, fragments: GraphWeaver.fragments_paths)
        source = supergraph.to_s
        table = GraphWeaver::SchemaLoader.routing_table(source)
        unless table.unsupported.empty?
          # the same refusal the Router makes at construction: with the table
          # incomplete, every number this would report is a guess
          raise Unplannable.new(
            "this supergraph uses federation constructs the local router doesn't read: " +
              table.unsupported.join("; "),
            category: :unsupported_federation,
          )
        end

        @planner = Router::Planner.new(table:, schema: GraphWeaver::SchemaLoader.load(source))
        @shared = GraphWeaver::Codegen.load_fragments(fragments)
        @results = Array(queries)
          .flat_map { |dir| Dir[File.join(dir, GraphWeaver::Codegen::DOCUMENT_GLOB)].sort }
          .map { |path| measure(path) }
      end

      def plannable = @results.count { |result| result.category.nil? }

      def refused = @results.reject { |result| result.category.nil? }

      # whole percent: this is a count of a handful of files, and a decimal
      # place would claim precision the sample doesn't have
      def percent = @results.empty? ? 0 : (plannable * 100.0 / @results.size).round

      def report
        return "no queries found" if @results.empty?

        [headline, *breakdown, *refusals].join("\n")
      end
      alias to_s report

      def inspect = "#<#{self.class.name} #{plannable}/#{@results.size} plannable>"

      private

      def headline
        "#{plannable}/#{@results.size} #{(@results.size == 1) ? "query" : "queries"} " \
          "plannable locally (#{percent}%)"
      end

      # where the plannable ones land — a graph whose queries all sit in one
      # subgraph is a different situation from one that's evenly spread
      def breakdown
        by_subgraph = @results.filter_map(&:subgraph).tally.sort_by { |name, count| [-count, name] }
        return [] if by_subgraph.empty?

        ["  " + by_subgraph.map { |name, count| "#{name} #{count}" }.join(", ")]
      end

      def refusals
        return [] if refused.empty?

        groups = refused.group_by(&:category).sort_by { |category, group| [-group.size, category.to_s] }
        names = refused.to_h { |result| [result, result.path.delete_prefix(shared_dir)] }
        width = names.each_value.map(&:length).max

        ["", "refused (#{refused.size})"] + groups.flat_map do |category, group|
          ["", "  #{LABELS.fetch(category, category)} (#{group.size})"] +
            group.map { |result| "    #{names.fetch(result).ljust(width)}  #{result.detail}" }
        end
      end

      # the directory every query came from, so the report's file column is
      # filenames rather than the same path repeated
      def shared_dir
        dirs = @results.map { |result| File.dirname(result.path) }.uniq
        dirs.one? ? "#{dirs.first}/" : ""
      end

      def measure(path)
        document = GraphQL.parse(GraphWeaver::Codegen.inline_fragments(File.read(path), @shared, path))
        errors = @planner.validate(document)
        return Result.new(path, nil, :invalid, errors.first["message"]) if errors.any?

        Result.new(path, @planner.plan(document).where, nil, nil)
      rescue Unplannable => e
        Result.new(path, nil, e.category, e.detail)
      rescue GraphQL::ParseError, GraphWeaver::Error => e
        Result.new(path, nil, :invalid, e.message)
      end
    end
  end
end
