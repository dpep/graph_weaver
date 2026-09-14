# Brief: `GraphWeaver.graph` becomes a block-only DSL

Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, trailers and method; its baseline is stale — yours is main **d33c014** (1221 examples, surface 451). Read CLAUDE.md, `lib/graph_weaver/graph.rb`, the `graph` method and `default_graph` in `lib/graph_weaver.rb`, `docs/getting_started.md` ("More than one schema"), `bin/generate`, `examples/github/*.rb`, and the CHANGELOG `## Unreleased` + `v0.7.0` entry (which introduced the kwargs form you are replacing — 0.7.0 is tagged but NOT on RubyGems, so this is a change to unshipped API; no upgrade row, rewrite the v0.7.0 entry's example instead). Worktree branch; don't push.

## Who you are

The staff engineer who has to explain this declaration to a Rails developer in one breath. The user decided: **block only, `instance_eval`, a simple DSL** — everything a graph knows is said inside the block, in call style, and the kwargs go. If some part of that is worse than the status quo, say so with the reason and stop on that part; the user has weighed "two spellings" already, so the argument has to be new.

## The shape

```ruby
GraphWeaver.graph :billing do
  schema "config/billing.graphql"          # a path, SDL, a class, a Client, or -> { Billing::Schema }
  queries "app/graphql/billing"
  output "app/graphql/generated/billing"
  client "Billing::CLIENT"
  namespace "Billing"
  types_module "Billing::Types"            # rare; defaults from namespace as today
  register_scalar "Money", BigDecimal
  register_enum ...
  extend_type ...
end
```

Rules to hold:
- **Call style sets, bare call reads.** `schema "x"` sets; `schema` returns the current value. `instance_eval` makes `schema = x` a local assignment that silently does nothing — so the setter-with-`=` form must not exist, and the docs say once, plainly, why (one sentence, no more; this is the graphql-ruby `field :x` convention, so name that).
- **Fallbacks unchanged.** A setting not said falls back to the top-level one, exactly as `Graph#queries`/`#output`/`#types_module` do today. The default graph is still what the settings describe; a single-schema app still never says "graph".
- **Unknown call refuses.** A typo (`schmea "x"`) must not vanish into `method_missing`: the DSL object responds to the settings and the three registrations and nothing else, and an unknown name raises naming the six settings and three registrations it takes. Don't `instance_eval` on the Graph itself if that lets a caller reach its readers/internals — a small DSL object that fills a Graph is fine and is probably what keeps `Graph` honest.
- **Re-declaring a name replaces it**, as today.

## The one hard question — when the block runs

Today the registrations block is **deferred**: it runs the first time anything reads the graph's registry, not at declaration, so `register_scalar "Money", Money` in a Rails initializer doesn't hit an autoload-order `NameError` (see the comment in `Graph#initialize` and `Codegen::AUTOLOAD_HINT`). With settings in the same block, the block has to run at declaration — `rake graph_weaver:graphs` and `generate!` need `schema`/`queries`/`output` without running anything.

Decide the deferral story and state it in one sentence. Options, roughly in order of my preference: (a) run the block at declaration, and make the *registrations* tolerate an unloaded constant the way top-level `GraphWeaver.register_scalar` already must in an initializer — check what it actually does today (a String type name is accepted: `register_scalar "Money", "Money"`; is that enough, and is `AUTOLOAD_HINT` the message a user sees?). (b) Run the block at declaration and document `config.to_prepare` as where a Rails app declares graphs (the existing comment already says re-declaring from `to_prepare` is safe). (c) Something better you find. Whatever you pick, **prove it in a scratch Rails app** (CLAUDE.md: "Drive it from a throwaway app when the host seam changes" — this is exactly that seam, and both prior host-seam bugs were silent): an initializer declaring two graphs with a registration naming an autoloaded constant, `rake graph_weaver:generate` producing output that carries the registration, `RAILS_ENV=production` boot, `rails zeitwerk:check`. Report what you ran and what you saw.

## Call sites to convert

Every `GraphWeaver.graph name, kwargs` in the repo: `bin/generate`, `examples/github/generate.rb` and `setup.rb`, `spec/graphs_spec.rb`, `spec/testing_spec.rb`, `spec/test_clients_spec.rb`, any others `rg -n "GraphWeaver.graph "` finds, `docs/getting_started.md`, `docs/scalars.md` (the `reset_graphs!` sentence and any graph example), `docs/federation.md`, README (the "second schema" paragraph), and `lib/graph_weaver/rspec.rb`/`testing.rb` refusal messages that spell a declaration (`GraphWeaver.graph :api, schema: "supergraph.graphql"` appears in at least one). The kwargs form is deleted, not kept: `GraphWeaver.graph(:x, schema: …)` raises `ArgumentError` naming the block form.

## Ownership and the other agent

You own `lib/graph_weaver/graph.rb`, `lib/graph_weaver.rb`, `lib/graph_weaver/codegen/**` if the emitter needs anything (it shouldn't), `bin/generate`, `examples/**`, `docs/**`, `README.md`, `CHANGELOG.md`, `spec/support/public_surface.txt`, and the call-site conversions in any spec. **Another agent is concurrently editing** `lib/graph_weaver/rspec.rb`, `lib/graph_weaver/testing.rb`, `lib/graph_weaver/testing/**`, `lib/graph_weaver/internal/test_clients.rb`, and specs under `spec/` for `:wire` and fakes. Convert the call sites you find; don't restructure anything else in those files. **Before reporting**: `git fetch` isn't needed (same repo) — check `git log main -1`; if main has moved past d33c014, `git rebase main`, resolve conflicts by converting any new kwargs call sites to the block form, re-run the gate, then report. Say in the report whether you rebased and what you converted.

## Gate

Brief-common gate as separate commands; `bin/generate` must leave the tree clean; `bin/public-surface` diff should be only the names you changed; two random seeds.

## Report

Shas; the DSL in one breath as you'd say it to a Rails dev; the deferral sentence and the scratch-app evidence; the refusal messages verbatim (kwargs form, unknown call); what you converted; whether you rebased; `git status` clean.
