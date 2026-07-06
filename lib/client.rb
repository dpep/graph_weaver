require "graphql/client"
require_relative "schema"

module Demo
  # execute: any object responding to #execute — the schema itself works,
  # so no HTTP adapter is involved
  Client = GraphQL::Client.new(schema: Schema, execute: Schema)
end
