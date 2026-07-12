# typed: false
# frozen_string_literal: true

# Shared wiring for the GitHub example: auth, scalar mapping, client.
require_relative "../../lib/graph_weaver"

# GitHub's DateTime scalar deserializes into a real Time
GraphWeaver.register_scalar("DateTime", Time, serialize: :iso8601, requires: "time")

token = ENV["GITHUB_TOKEN"] || `gh auth token 2>/dev/null`.strip
abort "need a token: `gh auth login`, or GITHUB_TOKEN=..." if token.empty?

GraphWeaver.client = GraphWeaver.new(
  "https://api.github.com/graphql",
  auth: token,
  # first run introspects GitHub's (large) schema and dumps it here —
  # gitignored, takes a few seconds once, instant after
  cache: File.join(__dir__, "schema.json"),
)
