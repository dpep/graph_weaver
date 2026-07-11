# typed: true
# frozen_string_literal: true

require "fileutils"
require "graphql"
require "json"
require_relative "errors"

# Load a schema for codegen from either format a remote service can hand
# you — an introspection dump (.json) or SDL (.graphql/.gql) — or fetch
# one straight from a live endpoint via introspect.
module GraphWeaver::SchemaLoader
  def self.load(path)
    case File.extname(path)
    when ".json"
      GraphQL::Schema.from_introspection(JSON.parse(File.read(path)))
    when ".graphql", ".gql"
      GraphQL::Schema.from_definition(File.read(path))
    else
      raise ArgumentError, "unsupported schema format: #{path}"
    end
  end

  # Run the standard introspection query through an executor and build a
  # schema from the result:
  #
  #   executor = GraphWeaver::HttpExecutor.new(url, headers: { ... })
  #   schema = GraphWeaver::SchemaLoader.introspect(executor)
  #
  # Introspecting a large API takes seconds, so cache: (a file path)
  # stores the raw introspection JSON and reuses it until ttl: seconds
  # elapse (no ttl = until the file is deleted). GraphQL has no standard
  # schema-version signal to invalidate on — a stale cache surfaces as
  # server-side validation errors (see QueryError#schema_drift?), so pick
  # a ttl that matches how fast the API moves, or delete the file.
  #
  # To cache anywhere else (Rails.cache, redis, ...), serialize the schema
  # itself — schemas round-trip through their introspection JSON:
  #
  #   json = Rails.cache.fetch("gh_schema", expires_in: 12.hours) do
  #     GraphWeaver::SchemaLoader.introspect(executor).to_json
  #   end
  #   schema = GraphQL::Schema.from_introspection(JSON.parse(json))
  def self.introspect(executor, cache: nil, ttl: nil)
    if cache && fresh?(cache, ttl)
      return GraphQL::Schema.from_introspection(JSON.parse(File.read(cache)))
    end

    result = executor.execute(GraphQL::Introspection.query, variables: {}).to_h
    if (errors = result["errors"])
      raise GraphWeaver::Error, "introspection failed: #{errors.inspect}"
    end

    if cache
      FileUtils.mkdir_p(File.dirname(cache))
      File.write(cache, JSON.generate(result))
    end

    GraphQL::Schema.from_introspection(result)
  end

  def self.fresh?(path, ttl)
    File.exist?(path) && (ttl.nil? || Time.now - File.mtime(path) < ttl)
  end
  private_class_method :fresh?
end
