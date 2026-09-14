# Brief: finish the per-graph rule — `:wire` endpoints, fake registries, one client_for

Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, trailers and method; its baseline is stale — yours is main **d33c014** (1221 examples, surface 451). Read CLAUDE.md, then `lib/graph_weaver/internal/test_clients.rb`, `lib/graph_weaver/rspec.rb`, `lib/graph_weaver/testing.rb`, `lib/graph_weaver/testing/endpoint.rb`, and the CHANGELOG `## Unreleased`. Worktree branch; don't push.

## Who you are

The staff engineer who just shipped this rule and is finishing it: **under a test mode, a generated module runs against the mode's client for the graph it was generated from; a per-call `client:` and `MyQuery.client =` still win; `:live` and `:wire` leave every client where it is.** Three loose ends were reported by the agent who built `Internal::TestClients` and are yours. Same bar: one rule, stated in a sentence, no exceptions. If any item is worse than the status quo, say so and stop on it.

## The three items

1. **`:wire` per bound client.** `RSpecIntegration.serve!` stubs one endpoint, read off `GraphWeaver.client`. With two graphs whose modules bake different clients, the second graph's endpoint is unstubbed and its request goes to the network. Under `:wire`, stub every distinct endpoint the example's modules can post to — the app client's, plus each declared graph's bound client — each with `Testing::Endpoint.new(<that graph's stand-in>)`, and take every stub down after. The stand-in per graph is what `TestClients` builds (expose its private `build` as `TestClients.client_for(mode, graph)`, or whatever shape reads best; keep the router built once). A graph declared `client: "Billing::CLIENT"` holds a constant *name*; resolve it the way `QueryModule#default_client` does. `endpoint!`'s refusal must name *which* client posts to nothing. Spec: two graphs, two spy-able endpoints, one `:wire` example, both stubbed, both requests seen, both torn down.

2. **A fake for a file-backed graph uses that graph's registry.** `GraphWeaver.graph :billing, schema: "billing.graphql" do register_scalar "Money", BigDecimal end` then `graphql: :fake`: `Internal::Util.registry_for(schema)` can't match a dump-backed graph (it matches on `live_schema.equal?`), so the fake fabricates `Money` with the default registry and the generated `BigDecimal(...)` cast chokes on what it invents. `TestClients` knows the graph, so `FakeClient` should be able to take the registry (`FakeClient.new(schema:, registry:)`, or the graph itself — pick the one that doesn't leak `Codegen::Registry`, which is `private_constant`, onto the surface). Spec watched failing first: a file-backed graph with a registered scalar, `:fake`, the value casts.

3. **One `client_for`.** `RSpecIntegration.client_for(mode)` (config-derived, single-graph) and `TestClients` (per-graph) are two answers to "what client does this mode use", agreeing by construction today. Make the deeper one canonical: `client_for(mode)` delegates to `TestClients` with "the app's single graph" as the graph, or `TestClients` reads through `client_for` — you decide which direction leaves one implementation, and delete the other. `graphql_fake`'s return value must stay the object the modules run against (spec exists: "hands back the client, so the request is assertable").

## Ownership

`lib/graph_weaver/rspec.rb`, `lib/graph_weaver/testing.rb`, `lib/graph_weaver/testing/**`, `lib/graph_weaver/internal/test_clients.rb`, `lib/graph_weaver/internal.rb`, `lib/graph_weaver/query_module.rb`, `spec/**`, `docs/testing.md`, `docs/transports.md`, `CHANGELOG.md` (fold into the existing Unreleased entries where they already describe the rule; a new bullet only for the `:wire` change), `spec/support/public_surface.txt`. Nobody else is running.

## Gate and traps

Brief-common gate as separate commands; three random seeds — the rspec integration mutates globals and an order-dependent failure hid in exactly this area yesterday (`:live` installing a mode). `private_constant` at class-body level only. WebMock stubs must be removed per example, never `reset!` (a spec asserts a suite's own stub survives). `INTEGRATION=1 bundle exec rspec spec/integration/router_parity_spec.rb` if router.rb changes.

## Report

Shas; the rule sentence as it now stands; what `serve!` stubs, in one sentence; which `client_for` survived and why; refusal messages changed; what you left; `git status` clean.
