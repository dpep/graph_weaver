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
    schema = GraphWeaver::SchemaLoader.load(GraphWeaver.schema_path)
    GraphWeaver.generate!(schema:).each { |path| puts "wrote #{path}" }
  end

  desc "Verify generated query modules are up to date"
  task :verify do
    schema = GraphWeaver::SchemaLoader.load(GraphWeaver.schema_path)
    GraphWeaver.verify_generated!(schema:)
    puts "generated queries up to date"
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
