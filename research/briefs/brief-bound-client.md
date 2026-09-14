# Brief: a module bound to its own client, under a test mode

Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, commit trailers and method; its baseline is stale — yours is main **aa5da50** (1204 examples, surface 452, `graphql: :wire` just landed; read `docs/testing.md` and the CHANGELOG `## Unreleased`). Work in your worktree branch; don't push.

## Who you are

The staff engineer who guards "no spooky action at a distance" (CLAUDE.md). The user's words: "can we also handle that case properly so there's consistent and predictable behavior?" The bar is one rule a user can predict without reading the source. If you conclude the simplest consistent rule is worse than today's, say so with the reason and stop.

## The inconsistency

A generated module resolves its client in order (`lib/graph_weaver/query_module.rb`): the per-call `client:`, the module's own (`MyQuery.client =`), the baked `DEFAULT_CLIENT` from `GraphWeaver.graph client:` or `GraphWeaver.new(url).parse`, then `GraphWeaver.client`. The rspec tags `:fake`, `:in_process`, `:router` work by swapping `GraphWeaver.client` for the example (`lib/graph_weaver/rspec.rb`, the before/after hooks; `Testing::RSpecIntegration.client_for`). So a module bound above that slot is untouched by the tag: `it "…", graphql: :fake` runs a bound module against its real client. `:wire` happens to reach it because it stubs the endpoint the bound client posts to — but only if that's the same endpoint as `GraphWeaver.client`'s, which with two graphs it isn't.

## The rule to aim for

**A tag applies to every module the example runs, and each module's stand-in is built from that module's own graph.** A `:fake` for a module bound to graph `:billing` fabricates from the billing schema; `:in_process` runs the billing schema class if it's live; `:wire` serves the billing graph at the billing client's endpoint. Multi-graph apps then get a coherent answer instead of `reference_schema!`'s "more than one graph, name it" refusal — or, if per-graph resolution turns out to be the wrong cut, that refusal gets sharper. You decide; state the rule you shipped in one sentence.

## Mechanism (yours to design; a sketch)

- `Codegen` bakes `DEFAULT_CLIENT` per module; check whether the module also knows its graph (name, schema source). If not, that is likely the missing link — `GraphWeaver.graph` (lib/graph_weaver/graph.rb) and the emitter (`codegen/emit.rb` around `DEFAULT_CLIENT`) are where a `GRAPH`-style constant would come from. Keep whatever you add private, like `DEFAULT_CLIENT`.
- Under a mode, module client resolution consults a test-time override first — something like `Internal::TestClients.for(module)` living in `lib/graph_weaver/internal.rb` or a new `lib/graph_weaver/internal/…` file — that maps a module's graph to the mode's client for that graph, built once per example and reset after. `QueryModule#client_for` asks it before the module's own chain. Off the rspec integration the override is nil and nothing changes.
- The rspec hook then installs the override instead of (or as well as) swapping `GraphWeaver.client`. **You do not own `rspec.rb`** — another agent is renaming things in it right now. Design the override's API so the hook change is two lines, and put those two lines, verbatim, in your report. Cover the end-to-end behavior in a spec that drives the override through `GraphWeaver::Testing` directly, not through the rspec tags.
- Watch `:wire`: its endpoint comes from `GraphWeaver.client`'s url today (`RSpecIntegration.endpoint!`). Per-graph, it should come from each bound client. Report what `endpoint!` needs to become; don't edit it.

## Proof

Spec watched failing first: a module generated with `client:` pointing at a spy transport, `:fake` mode installed via the override, the module executes and the spy sees nothing. Then the two-graph case: two modules bound to two graphs, `:fake` fabricates each from its own schema (assert a field that exists in only one). Regenerate fixtures (`bin/generate`) if the emitter changes; the tree must be clean after.

## Ownership

`lib/graph_weaver/query_module.rb`, `lib/graph_weaver/graph.rb`, `lib/graph_weaver/internal.rb` (+ new `lib/graph_weaver/internal/*.rb`), `lib/graph_weaver/codegen/emit.rb`, `lib/graph_weaver.rb`, `spec/generated/**` (via bin/generate only), new specs of your own, `spec/graphs_spec.rb`, `spec/query_module_spec.rb` if it exists, `docs/generated_modules.md`, `spec/support/public_surface.txt` (your names only — expect a merge conflict on this file; keep your lines contiguous). CHANGELOG: put your entry text in the report; I'll apply it. Do NOT touch `lib/graph_weaver/rspec.rb`, `lib/graph_weaver/testing.rb`, `lib/graph_weaver/testing/**`, `docs/testing.md`.

## Gate and traps

Brief-common gate as separate commands; this touches codegen, so `bin/round-trip -c 2000` too. `private_constant` at class-body level only. Generated code is `# typed: strict` — a new constant needs a `T.let`. `srb tc` must stay clean.

## Report

Shas; the one-sentence rule; the two-line hook for `rspec.rb` verbatim; what `endpoint!` needs; the CHANGELOG entry text; anything you'd change in files you don't own; `git status` clean.
