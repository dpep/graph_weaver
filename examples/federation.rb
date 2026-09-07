#!/usr/bin/env ruby
# typed: ignore — the subgraph schema classes it borrows are themselves ignored
# frozen_string_literal: true

# The only example that needs no network: a federated graph running entirely
# in this process. `Testing::Router` takes the composed supergraph, plans a
# query across the subgraphs, and stitches the answer — so a generated module
# runs against your real resolvers with no gateway, no node, no sockets.
#
#      bundle exec examples/federation.rb
#
# The subgraphs are the suite's own (spec/support/federation_router_graph.rb):
# `accounts` owns User, `products` owns Product, and `reviews` owns Review
# while extending both — the Apollo demo graph, as three real
# apollo-federation schemas. supergraph.graphql beside them is Apollo's own
# composition of the three, recomposed and diffed by the suite, so what runs
# here is the real thing.
#
# Everything the router does beyond this — @requires, a partly-local
# supergraph, the `:fake` opt-in, every refusal — is spec/router_spec.rb.
require_relative "../lib/graph_weaver"
require_relative "../lib/graph_weaver/testing"
require_relative "../spec/support/federation_router_graph"

# Only the supergraph is needed: which Ruby schema serves each subgraph is
# derived from what each loaded schema defines.
router = GraphWeaver::Testing::Router.new(supergraph: RouterGraph::SUPERGRAPH)
GraphWeaver.client = router
puts router.inspect

# me → accounts, reviews → reviews, product → products. Generated the way an
# app's code is — no client baked in, so it runs against GraphWeaver.client.
DashboardQuery = GraphWeaver.parse(schema: router.schema, name: "DashboardQuery", query: <<~GRAPHQL)
  query Dashboard {
    me {
      username
      reviews { body product { name price } }
    }
  }
GRAPHQL

me = DashboardQuery.execute!.me
puts "\n#{me.username} reviewed #{me.reviews.size} products:"
me.reviews.each { |review| puts "  #{review.product.name} ($#{review.product.price}) — #{review.body}" }

# The trace is the mechanism in one read: a root fetch, then one `_entities`
# call per subgraph per level — every node at a level in ONE call, so two
# products are one fetch, not two.
puts "\nfetches:"
router.trace.each do |fetch|
  reps = fetch[:variables]["representations"]
  puts "  → #{fetch[:subgraph].ljust(9)} #{reps ? "_entities × #{reps.size} #{reps.first["__typename"]}" : "root fields"}"
end

# Everything it can't plan *faithfully* raises at plan time, before any
# subgraph runs. Here the alias collides with the @key the planner injects to
# cross the boundary, and Apollo's router and a spec-conformant server answer
# that differently — so there is no one answer to agree with.
begin
  router.execute("{ me { id: username reviews { body } } }")
rescue GraphWeaver::Testing::Unplannable => e
  puts "\nrefused (#{e.label}):\n  #{e.message}"
end
