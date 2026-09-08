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
      # plan stitches across a boundary. `absent` names the subgraphs that
      # plan reaches which nothing in this process serves — plannable and
      # runnable-here are different questions.
      Result = Struct.new(:path, :subgraph, :absent, :category, :detail) do
        def servable? = category.nil? && absent.empty?
      end

      # the label each verdict groups under
      LABELS = Unplannable::CATEGORIES
        .transform_values(&:first)
        .merge(invalid: "doesn't validate against the supergraph")
        .freeze

      attr_reader :results

      def initialize(supergraph:, queries: GraphWeaver.queries_paths, fragments: GraphWeaver.fragments_paths)
        source = supergraph.to_s
        table = GraphWeaver::SchemaLoader.routing_table(source)
        # with the table incomplete, every number this would report is a guess
        Unplannable.unsupported!(table)

        # Planning still runs with `absent` empty — a query is plannable or
        # not whoever is serving. Which subgraphs are *here* is asked
        # separately, from evidence (a loaded schema defining what the table
        # says one resolves), and never refuses: with nothing loaded the
        # answer is simply "none", which is the SDL-alone CI run.
        @planner = Router::Planner.new(table:, schema: GraphWeaver::SchemaLoader.load(source))
        @absent = table.subgraphs.reject { |name| Subgraphs.served?(table, name) }
        @local = @absent.size < table.subgraphs.size
        @shared = GraphWeaver::Codegen.load_fragments(fragments)
        @results = GraphWeaver.query_files(queries).map { |path| measure(path) }
      end

      def plannable = @results.count { |result| result.category.nil? }

      # plannable *and* every subgraph the plan reaches is served here
      def servable = @results.count(&:servable?)

      # plannable, but reaching a subgraph another process serves
      def elsewhere = @results.select { |result| result.category.nil? && result.absent.any? }

      def refused = @results.reject { |result| result.category.nil? }

      # whole percent: this is a count of a handful of files, and a decimal
      # place would claim precision the sample doesn't have
      def percent = @results.empty? ? 0 : (plannable * 100.0 / @results.size).round

      def report
        return "no queries found" if @results.empty?

        [headline, *breakdown, *served_here, *refusals].join("\n")
      end
      alias to_s report

      def inspect = "#<#{self.class.name} #{plannable}/#{@results.size} plannable>"

      private

      def headline
        counted = "#{plannable}/#{@results.size} #{(@results.size == 1) ? "query" : "queries"} " \
          "plannable locally (#{percent}%)"
        @local ? "#{counted}, #{servable} servable here" : counted
      end

      # Plan-only is by design — a query is plannable whoever serves it — but
      # the question this report exists to answer is whether wiring the router
      # up is worth it, and a suite can only *run* what this process serves.
      # A partly-local supergraph is the usual migration shape, so the second
      # number has to be here rather than inferred from a refusal later.
      def served_here
        unless @local
          return ["", "nothing here serves any of this supergraph's subgraphs " \
            "(#{@absent.join(", ")}), so this counts planning only"]
        end
        return [] if elsewhere.empty?

        example = elsewhere.first.absent.first
        ["", "plannable, but nothing here serves what they reach (#{elsewhere.size}) — name a " \
          "schema for those subgraphs, fake them (subgraphs: { #{example.inspect} => :fake }), " \
          "or run these against a real router:"] +
          elsewhere.map { |result| "  #{name(result)}  #{result.absent.join(", ")}" }
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

        ["", "refused (#{refused.size})"] + groups.flat_map do |category, group|
          ["", "  #{LABELS.fetch(category, category)} (#{group.size})"] +
            group.map { |result| "    #{name(result)}  #{result.detail}" }
        end
      end

      # the file column: filenames when every query came from one directory,
      # padded so what sits beside them lines up
      def name(result) = basename(result).ljust(width)

      def basename(result) = result.path.delete_prefix(shared_dir)

      def width = @width ||= @results.map { |result| basename(result).length }.max

      # the directory every query came from, so the report's file column is
      # filenames rather than the same path repeated
      def shared_dir
        @shared_dir ||= begin
          dirs = @results.map { |result| File.dirname(result.path) }.uniq
          dirs.one? ? "#{dirs.first}/" : ""
        end
      end

      def measure(path)
        document = GraphQL.parse(GraphWeaver::Codegen.inline_fragments(File.read(path), @shared, path))
        errors = @planner.validate(document)
        return Result.new(path, nil, [], :invalid, errors.first["message"]) if errors.any?

        plan = @planner.plan(document)
        Result.new(path, plan.where, plan.subgraphs & @absent, nil, nil)
      rescue Unplannable => e
        Result.new(path, nil, [], e.category, e.detail)
      rescue GraphQL::ParseError, GraphWeaver::Error => e
        Result.new(path, nil, [], :invalid, e.message)
      end
    end
  end
end
