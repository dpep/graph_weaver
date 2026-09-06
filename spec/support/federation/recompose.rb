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
#
# spec/support is on the suite's load glob, so this only composes when it is
# the program being run.
return unless $PROGRAM_NAME == __FILE__

require "json"
require "open3"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "graph_weaver"
require_relative "../federation_router_graph"

input = JSON.generate(
  RouterGraph::SUBGRAPHS.map { |name, schema| { name:, sdl: schema.federation_sdl } },
)
out, err, status = Open3.capture3("node", "compose.mjs", stdin_data: input, chdir: __dir__)
abort "composition failed: #{err}" unless status.success?

File.write(RouterGraph::SUPERGRAPH, JSON.parse(out).fetch("supergraph"))
puts "wrote #{RouterGraph::SUPERGRAPH}"
