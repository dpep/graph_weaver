# typed: true
# frozen_string_literal: true

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
  def self.introspect(executor)
    result = executor.execute(GraphQL::Introspection.query, variables: {}).to_h
    if (errors = result["errors"])
      raise GraphWeaver::Error, "introspection failed: #{errors.inspect}"
    end

    GraphQL::Schema.from_introspection(result)
  end
end
