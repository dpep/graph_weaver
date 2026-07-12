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
#      rake graph_weaver:generate   # queries_path -> generated_path
#      rake graph_weaver:verify     # fail if generated files are stale (CI)
require_relative "../graph_weaver"

namespace :graph_weaver do
  desc "Generate typed query modules (#{GraphWeaver.queries_path} -> #{GraphWeaver.generated_path})"
  task :generate do
    # schema auto-located at GraphWeaver.schema_path, any supported extension
    GraphWeaver.generate!.each { |path| puts "wrote #{path}" }
  end

  desc "Verify generated query modules are up to date"
  task :verify do
    GraphWeaver.verify_generated!
    puts "generated queries up to date"
  end

  namespace :schema do
    # both tasks re-introspect from the url recorded in the dump
    # (GRAPHWEAVER_AUTH supplies a token for private APIs)

    desc "Fail when the server's schema has drifted from the local dump"
    task :verify do
      path = GraphWeaver::SchemaLoader.locate_path or abort "no schema dump at #{GraphWeaver.schema_path}"
      if GraphWeaver::SchemaLoader.stale?(path)
        abort "#{path} is stale — the server's schema has drifted (rake graph_weaver:schema:refresh)"
      end

      puts "#{path} matches the server"
    end

    desc "Re-introspect the recorded url and rewrite the local dump"
    task :refresh do
      path = GraphWeaver::SchemaLoader.locate_path or abort "no schema dump at #{GraphWeaver.schema_path}"
      meta = GraphWeaver::SchemaLoader.provenance(path) or abort "#{path} records no source url"

      executor = GraphWeaver.new(meta["url"], auth: ENV["GRAPHWEAVER_AUTH"]).executor
      GraphWeaver::SchemaLoader.introspect(executor, cache: path, ttl: 0)
      puts "refreshed #{path} from #{meta["url"]}"
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
