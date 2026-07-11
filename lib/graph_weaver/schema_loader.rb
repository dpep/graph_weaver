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
  # server-side validation errors, so pick a ttl that matches how fast
  # the API moves, or delete the file to force a refresh.
  #
  # To cache anywhere else (Rails.cache, redis, ...), use the primitive —
  # introspection_result returns the plain JSON-able Hash:
  #
  #   json = Rails.cache.fetch("gh_schema", expires_in: 12.hours) do
  #     GraphWeaver::SchemaLoader.introspection_result(executor)
  #   end
  #   schema = GraphQL::Schema.from_introspection(json)
  def self.introspect(executor, cache: nil, ttl: nil)
    unless cache
      return GraphQL::Schema.from_introspection(introspection_result(executor))
    end

    if fresh?(cache, ttl)
      GraphQL::Schema.from_introspection(JSON.parse(File.read(cache)))
    else
      result = introspection_result(executor)
      FileUtils.mkdir_p(File.dirname(cache))
      File.write(cache, JSON.generate(result))
      GraphQL::Schema.from_introspection(result)
    end
  end

  # The raw introspection response as a Hash — the cacheable unit.
  def self.introspection_result(executor)
    result = executor.execute(GraphQL::Introspection.query, variables: {}).to_h
    if (errors = result["errors"])
      raise GraphWeaver::Error, "introspection failed: #{errors.inspect}"
    end

    result
  end

  def self.fresh?(path, ttl)
    File.exist?(path) && (ttl.nil? || Time.now - File.mtime(path) < ttl)
  end
  private_class_method :fresh?
end
