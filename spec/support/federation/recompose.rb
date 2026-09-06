# typed: ignore — harness plumbing
# frozen_string_literal: true

# Regenerate the committed supergraph from the three subgraph classes:
#
#      ruby spec/support/federation/recompose.rb
#
# supergraph.graphql is what Testing::Router, the coverage corpus and the
# parity gateway all route over, so it has to be Apollo's own composition of
# spec/support/federation_router_graph.rb rather than hand-written. Needs node
# and the harness deps (npm install in this directory).
require "json"
require "open3"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "graph_weaver"
require_relative "../federation_router_graph"

HERE = __dir__

input = JSON.generate(
  RouterGraph::SUBGRAPHS.map { |name, schema| { name:, sdl: schema.federation_sdl } },
)
out, err, status = Open3.capture3("node", "compose.mjs", stdin_data: input, chdir: HERE)
abort "composition failed: #{err}" unless status.success?

File.write(File.join(HERE, "supergraph.graphql"), JSON.parse(out).fetch("supergraph"))
puts "wrote #{File.join(HERE, "supergraph.graphql")}"
