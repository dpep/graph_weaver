# typed: true
# frozen_string_literal: true

require "graphql"
require "json"

# Load a schema for codegen from either format a remote service can hand
# you: an introspection dump (.json) or SDL (.graphql/.gql).
module SchemaLoader
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
end
