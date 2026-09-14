# Brief: the rspec surface — `:live`, helper consolidation, supergraph lookup

Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, commit trailers and method; its baseline is stale — yours is main **aa5da50** (1204 examples, surface 452 names, `graphql: :wire` just landed; read its CHANGELOG entry and `docs/testing.md`). Work in your worktree branch; don't push.

## Who you are

The staff engineer who guards the test harness's conceptual integrity. The user's words: "asymmetry isn't great, proliferation isn't great." Every name on this surface is one a new user has to learn, so the bar is: can the whole tag-and-helper story be stated in three sentences afterwards? If a change makes it longer to state, it's the wrong change. If you conclude any item below is worse than the status quo, say so and stop on that item.

## Decided — implement these

1. **`graphql: false` becomes `graphql: :live`.** The opt-out is the app's own client, untouched, and the tag family names what runs, so the opt-out should too. `config.default_mode = :live` is the suite-level spelling (nil still means the same, since untagged pass-through is the status quo and stays the default). `false` is gone, not aliased — pre-1.0, no deprecation machinery (decided earlier; don't re-raise). The refusal for an unknown tag lists `:live` with the others. Every mention in `lib/graph_weaver/rspec.rb`'s header, `docs/testing.md`, and any README line follows. Upgrade note under `## Unreleased` in CHANGELOG (Breaking).

2. **Delete `graphql_wire`.** It existed only for `fake:`; `:wire` takes no per-example options. Faked subgraphs behind the wire come from `config.router = { fake: }`, suite-wide. Remove the helper, its specs, its doc lines, its surface entries. If deleting it exposes the `@__graph_weaver_served ||=` dance in the hook as now-unneeded, simplify.

3. **The supergraph lookup consults declared graphs first.** `Testing::Config#supergraph!` only checks `SchemaLoader.locate_path` (the conventional dump). An app that declared `GraphWeaver.graph :api, schema: "config/supergraph.graphql"` has already said where the supergraph is. Order becomes: `config.router[:supergraph]` if named → a declared graph whose schema source is composed (carries `@join__*`) → the conventional dump when composed → refuse, with the message updated to mention the graph declaration. With more than one declared graph, use the one(s) that are composed; if two are, refuse naming both (same shape as `reference_schema!`'s multi-graph refusal). Spec watched failing first: a graph declared with a supergraph path and no `config.router`, `:router` plans.

## Evaluate, then implement or report

4. **Helper consolidation.** Today: `graphql_fake(pins)`, `graphql_in_process(Schema)`, `graphql_router(fake:)`, plus `graphql_context`. Each is "the tag, with an argument the tag can't carry". Candidate: one helper spelled like the tag, `graphql(:fake, "Order.total" => "999")`, `graphql(:in_process, MySchema)`, `graphql(:router, fake: { … })`, with the per-mode helpers deleted. Weigh: does one name with a mode-shaped signature read better than four names? Is `graphql` too generic a method to include into every example group (collision with an app's own helper — grep a couple of real Rails apps' spec/support conventions in your head; `graphql_context` would stay as is either way)? Would `graphql :fake, …` at the top of an example read as clearly as the tag? Decide, write the three-sentence story for both shapes, pick, and implement the pick. If you keep the four, say why in the report and leave them. Whichever you choose, the mode/helper contradiction check (`claim_mode!`) and the "a tag and a helper are two spellings of one choice" rule must survive as one rule.

## Not in scope — another agent owns these

`lib/graph_weaver/query_module.rb`, `lib/graph_weaver/internal.rb`, and how a module bound to its own client behaves under a mode. That agent will hand me a hook for `rspec.rb`'s before/after; I'll apply it after your merge. Don't design around it; don't touch those files. If you need something from them, REPORT it.

## Ownership

`lib/graph_weaver/rspec.rb`, `lib/graph_weaver/testing.rb`, `lib/graph_weaver/testing/**`, `spec/rspec_spec.rb`, `spec/wire_mode_spec.rb`, `spec/testing_spec.rb`, `spec/endpoint_spec.rb`, any new spec you add, `docs/testing.md`, `docs/federation.md` (the router lookup paragraph), `README.md`, `CHANGELOG.md`, `spec/support/public_surface.txt`.

## Gate and traps

The gate in brief-common, run as separate commands. Public surface: `bin/public-surface` regenerates the list — diff it, expect only your deletions and renames. Random seeds matter here: the rspec integration mutates global state and four order-dependent failures have hidden in this suite before. Run `--order rand:1` and `--order rand:7`.

## Report

Shas; the three-sentence story of the surface as it now stands; the helper decision and its reasoning; the supergraph lookup order verbatim from the code comment; refusal messages you changed; what you left; `git status` clean.
