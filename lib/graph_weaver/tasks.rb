# typed: ignore — Rake DSL at top level, loaded from Rakefiles
# frozen_string_literal: true

# Rake tasks — add to your Rakefile:
#
#      require "graph_weaver/tasks"
#
# The tasks use the conventional paths (GraphWeaver.queries_path /
# generated_path / schema_path — override in your Rakefile or an
# initializer). Register custom scalars before the tasks run — they're
# baked into generated source.
#
# Each task names its own subject — generated code, the schema dump, the
# queries — so which question you're asking is the task name:
#
#      rake graph_weaver:generate        # queries_path -> generated_path
#      rake graph_weaver:verify          # fail if generated files are stale (CI)
#      rake graph_weaver:queries:check   # fail if a query no longer validates (CI)
#      rake graph_weaver:schema:diff     # fail if the server has drifted from the dump
#      rake graph_weaver:schema:refresh  # re-introspect and rewrite the dump
require_relative "../graph_weaver"

namespace :graph_weaver do
  # In Rails, boot the app first — initializers register scalars/enums/
  # helpers and they're baked into generated source. Rails defines
  # :environment *after* every railtie's rake_tasks block (see
  # Rails::Application#run_tasks_blocks), so whether it exists can only be
  # asked when the task runs, not when this file loads.
  task :environment do
    Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
  end

  desc "Generate typed query modules (#{GraphWeaver.queries_path} -> #{GraphWeaver.generated_path})"
  task generate: :environment do
    # schema auto-located at GraphWeaver.schema_path, any supported extension
    GraphWeaver.generate!.each { |path| puts "wrote #{path}" }
  rescue GraphWeaver::Error => e
    # a typo'd query is a user error — the message names file, position and
    # fix, and a rake backtrace through codegen only buries it
    abort e.message
  end

  desc "Verify generated query modules are up to date"
  task verify: :environment do
    GraphWeaver.verify_generated!
    puts "generated queries up to date"
  rescue GraphWeaver::Error => e
    abort e.message
  end

  namespace :schema do
    # both re-introspect from the url recorded in the dump
    # (GRAPHWEAVER_AUTH supplies a token for private APIs)

    desc "Fail when the server's schema has drifted from the local dump"
    task :diff do
      path = GraphWeaver::SchemaLoader.locate_path or abort "no schema dump at #{GraphWeaver.schema_path}"
      if GraphWeaver::SchemaLoader.stale?(path)
        abort "#{path} is stale — the server's schema has drifted (rake graph_weaver:schema:refresh)"
      end

      puts "#{path} matches the server"
    rescue GraphWeaver::Error => e
      # e.g. a dump with no recorded url — same clean exit as :refresh
      abort e.message
    end

    desc "Re-introspect and rewrite the local dump (URL= to bootstrap the first one)"
    task :refresh do
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

      abort "#{failures.size} invalid #{(failures.size == 1) ? "query" : "queries"}" if failures.any?
      puts "every query validates against the schema"
    end
  end

  namespace :cassettes do
    desc "Anonymize every cassette in Testing.config.cassette_dir (PII-safe to commit)"
    task :anonymize do
      require "graph_weaver/testing"

      schema = GraphWeaver::SchemaLoader.load(GraphWeaver.schema_path)
      Dir[File.join(GraphWeaver::Testing.config.cassette_dir, "*.yml")].sort.each do |path|
        GraphWeaver::Testing::Cassette.new(path).anonymize!(schema:)
        puts "anonymized #{path}"
      end
    end
  end
end
