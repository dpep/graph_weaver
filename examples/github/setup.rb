# typed: false
# frozen_string_literal: true

# Shared wiring for the GitHub example: auth and the client.
require_relative "../../lib/graph_weaver"

module GithubExample
  # used by generate.rb (and any dynamic parse): the first introspection
  # of GitHub's large schema dumps here — gitignored, a few seconds once,
  # instant after. run.rb's checked-in generated modules never introspect,
  # so running it alone won't create this file.
  SCHEMA_CACHE = File.join(__dir__, "schema.json")

  # Requiring this file reaches nothing, so bin/generate can regenerate from
  # SCHEMA_CACHE with no token; needing GitHub is this call.
  def self.connect!
    token = ENV["GITHUB_TOKEN"] || `gh auth token 2>/dev/null`.strip
    abort "need a token: `gh auth login`, or GITHUB_TOKEN=..." if token.empty?

    GraphWeaver.client = GraphWeaver.new(
      "https://api.github.com/graphql",
      auth: token,
      cache: SCHEMA_CACHE,
    )
  end
end
