# typed: ignore — Rake DSL at top level, loaded from Rakefiles
# frozen_string_literal: true

# Rake tasks — add to your Rakefile:
#
#      require "graph_weaver/tasks"
#
# The tasks use the conventional paths (GraphWeaver.queries_paths /
# generated_paths / schema_path — override in your Rakefile or an
# initializer). Register custom scalars before the tasks run — they're
# baked into generated source.
#
# Each task names its own subject — generated code, the schema dump, the
# queries — so which question you're asking is the task name:
#
#      rake graph_weaver:generate        # queries_paths -> generated_paths.first
#      rake graph_weaver:verify          # fail if generated files are stale (CI)
#      rake graph_weaver:queries:check   # fail if a query no longer validates (CI)
#      rake graph_weaver:schema:diff     # fail if the server has drifted from the dump
#      rake graph_weaver:schema:refresh  # re-introspect and rewrite the dump
#      rake graph_weaver:federation:diff       # fail if the supergraph wasn't recomposed
#      rake graph_weaver:federation:coverage   # what the local test router can plan
#      rake graph_weaver:federation:subgraphs  # which schema serves which subgraph
#      rake graph_weaver:cassettes:check       # fail if a recording no longer casts
require_relative "../graph_weaver"

module GraphWeaver
  # helpers the rake tasks share; not part of the library's API
  module Tasks
    # The composed supergraph a federation task reads: SUPERGRAPH=, else the
    # conventional dump when that is what it is. Aborts naming the task, so
    # the message says the command to retype.
    def self.supergraph!(task)
      ENV["SUPERGRAPH"] || GraphWeaver::SchemaLoader.locate_path ||
        abort("pass the composed supergraph: rake graph_weaver:federation:#{task} " \
          "SUPERGRAPH=supergraph.graphql")
    end

    # Registrations the run couldn't match, once each. The logger is the
    # runtime channel and is silent by default; this task's own output is the
    # build channel, and the build is where someone regenerating is looking.
    def self.report_unmatched
      GraphWeaver.unmatched_registrations.each { |message| puts message }
    end

    # Neither task that needs the committed dump can take one itself, so both
    # say which task can — the same sentence SchemaLoader gives on refresh.
    def self.no_dump
      "no schema dump at #{GraphWeaver.schema_path} — take one: " \
        "rake graph_weaver:schema:refresh URL=https://api.example.com/graphql"
    end
  end
end

namespace :graph_weaver do
  # In Rails, boot the app first — initializers register scalars/enums/
  # helpers and they're baked into generated source. Rails defines
  # :environment *after* every railtie's rake_tasks block (see
  # Rails::Application#run_tasks_blocks), so whether it exists can only be
  # asked when the task runs, not when this file loads.
  task :environment do
    # These tasks read queries, the schema and the registrations, not a
    # generated module. Saying so lets the railtie skip loading them, so a
    # stale generated file can't block the task that repairs it. It's reset
    # below, so cassettes:check — which does read them — loads them itself.
    GraphWeaver.skip_generated_load = true
    Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
  ensure
    # only meaningful while booting — leaving it set would silently disable
    # loading for anything that boots later in the same process
    GraphWeaver.skip_generated_load = false
  end

  desc "Generate typed query modules (#{GraphWeaver.queries_paths.first} -> #{GraphWeaver.generated_paths.first})"
  task generate: :environment do
    output = GraphWeaver.generated_paths.first
    before = Dir[File.join(output, "**/*.rb")]

    # schema auto-located at GraphWeaver.schema_path, any supported extension
    written = GraphWeaver.generate!
    written.each { |path| puts "wrote #{path}" }
    # generated files are checked in, so a delete this task made is a diff the
    # user is about to find; a run that printed nothing at all had done both
    (before - Dir[File.join(output, "**/*.rb")]).each { |path| puts "pruned #{path}" }
    puts "no queries in #{GraphWeaver.queries_paths.join(", ")}" if written.empty?
    GraphWeaver::Tasks.report_unmatched
  rescue GraphWeaver::Error => e
    # a typo'd query is a user error — the message names file, position and
    # fix, and a rake backtrace through codegen only buries it
    abort e.message
  end

  desc "Verify generated query modules are up to date"
  task verify: :environment do
    GraphWeaver.verify_generated!
    puts "generated queries up to date"
    GraphWeaver::Tasks.report_unmatched
  rescue GraphWeaver::Error => e
    abort e.message
  end

  namespace :schema do
    # both re-introspect from the url recorded in the dump
    # (GRAPHWEAVER_AUTH supplies a token for private APIs)

    desc "Fail when the server's schema has drifted from the local dump"
    task diff: :environment do
      path = GraphWeaver::SchemaLoader.locate_path or abort GraphWeaver::Tasks.no_dump
      diff = GraphWeaver::SchemaLoader.diff(path)
      if diff.empty?
        puts "#{path} matches the server"
      else
        puts diff.report
        # abort writes to unbuffered stderr; the summary above went to
        # block-buffered stdout, so a piped CI log shows it first
        $stdout.flush
        abort "#{path} is stale — the server's schema has drifted (rake graph_weaver:schema:refresh)"
      end
    rescue GraphWeaver::Error => e
      # e.g. a dump with no recorded url — same clean exit as :refresh
      abort e.message
    end

    desc "Re-introspect and rewrite the local dump (URL= to bootstrap the first one)"
    task refresh: :environment do
      # anything else in URL= reaches introspection as a schema *source*, and
      # fails talking about file extensions rather than the flag just typed
      if ENV["URL"] && !ENV["URL"].match?(GraphWeaver::Client::URL)
        abort "URL= takes an endpoint: rake graph_weaver:schema:refresh URL=https://api.example.com/graphql"
      end

      path, url = GraphWeaver::SchemaLoader.refresh!(url: ENV["URL"])
      puts "refreshed #{path} from #{url}"
    rescue GraphWeaver::Error => e
      abort e.message
    end
  end

  namespace :queries do
    desc "Report checked-in queries that no longer validate against the server's schema"
    task check: :environment do
      failures = GraphWeaver.check_queries
      failures.each do |path, errors|
        puts path
        errors.each do |error|
          position = [error["line"], error["column"]].compact.join(":")
          puts "  #{position.empty? ? "" : "#{position}  "}#{error["message"]}"
        end
        puts
      end

      # abort writes to unbuffered stderr; the detail above went to
      # block-buffered stdout, so a piped CI log shows the verdict first
      $stdout.flush
      abort "#{failures.size} invalid #{(failures.size == 1) ? "query" : "queries"}" if failures.any?
      puts "every query validates against the schema"
    end
  end

  namespace :federation do
    # Every task here answers "which loaded schema serves which subgraph",
    # and Rails leaves config.rake_eager_load false in every environment —
    # so without this each of them reports on zero subgraphs, and :diff
    # exits 0 having compared nothing. Asked when the task runs, not when
    # this file loads: :environment doesn't exist yet at load time.
    task loaded: :environment do
      Rails.application.eager_load! if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
    end

    # needs no network, so it gates a PR the way verify does
    desc "Fail when a subgraph here changed and the supergraph wasn't recomposed (SUPERGRAPH=)"
    task diff: :loaded do
      require "graph_weaver/federation"

      supergraph = GraphWeaver::Tasks.supergraph!("diff")
      drift = GraphWeaver::Federation::Drift.new(supergraph:)
      puts drift.report

      # A partly-local supergraph is a supported setup, so a subgraph this
      # process doesn't serve isn't a failure — but comparing against NONE
      # of them is: the gate passes whatever the subgraphs say, which is
      # worse than failing.
      $stdout.flush
      abort "the supergraph is out of date — recompose it and commit the result" if drift.drift?
      if drift.vacuous?
        abort "this checked nothing, so it proved nothing. No schema in this process defines what " \
          "the supergraph says any of its subgraphs resolves — load them (in Rails, that is " \
          "config.eager_load / config.rake_eager_load), or, if they all run elsewhere, drop this " \
          "task from CI: there is nothing here for it to gate."
      end
    rescue GraphWeaver::Error => e
      abort e.message
    end

    desc "Show which loaded schema serves each subgraph, as a paste-ready map (SUPERGRAPH=)"
    task subgraphs: :loaded do
      require "graph_weaver/testing"

      supergraph = GraphWeaver::Tasks.supergraph!("subgraphs")

      # Testing::Router derives this map itself; this is for reading what
      # detection sees when it refuses, and for committing the map instead.
      table = GraphWeaver::SchemaLoader.routing_table(supergraph)
      rows = table.subgraphs.map do |name|
        found = GraphWeaver::Testing::Subgraphs.candidates(table, name)
        sought = GraphWeaver::Testing::Subgraphs.expected(table, name)
        [name, found, sought]
      end
      width = rows.map { |name, found, _| %("#{name}" => #{found.first&.name || "nil"},).length }.max

      puts "subgraphs: {"
      rows.each do |name, found, sought|
        entry = %(  "#{name}" => #{found.one? ? found.first.name : "nil"},).ljust(width + 2)
        # fields first: every schema has a Query, so only the fields say why
        evidence = (sought.grep(/\./) | sought).first(3).join(", ")
        note = if found.one?
          "# matched: defines #{evidence}"
        elsif found.any?
          "# AMBIGUOUS: #{found.map(&:name).sort.join(", ")} all match — pick one"
        else
          "# no loaded schema defines #{evidence} — fill this in"
        end
        puts "#{entry}  #{note}"
      end
      puts "}"
    rescue GraphWeaver::Error => e
      abort e.message
    end

    desc "Report how many queries the local test router can plan (SUPERGRAPH=, QUERIES=)"
    task coverage: :loaded do
      require "graph_weaver/testing"

      puts GraphWeaver::Testing::Coverage.new(
        supergraph: GraphWeaver::Tasks.supergraph!("coverage"),
        queries: ENV["QUERIES"] || GraphWeaver.queries_paths,
      ).report
    rescue GraphWeaver::Error => e
      # a supergraph the routing table can't read fully is itself the answer:
      # nothing is plannable, and the message says which construct
      abort e.message
    end
  end

  namespace :cassettes do
    # The drift the other checks structurally can't see. verify, queries:check
    # and schema:diff all ask about the local side; a cassette is the one
    # artifact recorded from someone else's server, and when that server's
    # answers stop fitting the generated structs the failure surfaces mid-spec
    # as a cast error naming a struct and a sorbet frame — nothing points at
    # the stale file.
    desc "Fail when a recorded response no longer casts into the generated structs"
    task check: :environment do
      require "graph_weaver/testing"

      # unlike its siblings this task reads generated modules — they are what
      # a recording is checked against
      GraphWeaver.load_generated!
      modules = GraphWeaver.query_files.filter_map do |path|
        name = GraphWeaver.module_name(path, File.read(path))
        Object.const_get(name) if Object.const_defined?(name)
      end

      # Testing.cassette_dir, not config.cassette_dir: the configured path is
      # relative by default and rake runs from wherever it runs from
      dir = GraphWeaver::Testing.cassette_dir
      checks = Dir[File.join(dir, "*.yml")].sort.map do |path|
        GraphWeaver::Testing::Cassette.new(path).check(modules)
      end
      checks.each { |check| puts check.report }

      stale = checks.sum { |check| check.stale.size }
      $stdout.flush
      if stale.positive?
        abort "#{stale} stale #{(stale == 1) ? "recording" : "recordings"} — the recorded server's " \
          "answers no longer fit the structs generated from your schema. Re-record " \
          "(GRAPHWEAVER_RECORD=1, with a live client:), or regenerate if it was the schema dump " \
          "that moved: rake graph_weaver:generate."
      end
      if checks.sum(&:checked).zero?
        # a green run that compared nothing is worse than a failure: it would
        # pass whatever the recordings said (see federation:diff)
        abort "this checked nothing, so it proved nothing: no recording in #{dir} carries a query " \
          "any of the #{modules.size} generated modules sends. Drop this task from CI if you " \
          "don't record cassettes, or check that #{dir} is where yours live."
      end

      puts "every recording still casts"
    end

    desc "Anonymize every cassette in Testing.config.cassette_dir (PII-safe to commit)"
    task anonymize: :environment do
      require "graph_weaver/testing"

      # locate, not schema_path: the dump is whichever supported extension is
      # actually on disk, and every sibling task asks the same way
      schema = GraphWeaver::SchemaLoader.locate or abort GraphWeaver::Tasks.no_dump
      Dir[File.join(GraphWeaver::Testing.cassette_dir, "*.yml")].sort.each do |path|
        GraphWeaver::Testing::Cassette.new(path).anonymize!(schema:)
        puts "anonymized #{path}"
      end
    end
  end
end
