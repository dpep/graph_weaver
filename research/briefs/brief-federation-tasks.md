# Brief: the federation rake tasks ask the declared graphs, like everything else now does

Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, trailers and method; baseline is main **c9b131f** (1264 examples, surface 451). Read CLAUDE.md, `lib/graph_weaver/tasks.rb` (the `federation:*` tasks), `lib/graph_weaver/federation.rb`, `lib/graph_weaver/internal/tasks.rb`, and `Testing::Config#supergraph!` in `lib/graph_weaver/testing.rb` — the per-graph lookup you are matching. Worktree branch; don't push.

## The finding (two agents flagged it independently)

`rake graph_weaver:federation:diff`, `federation:subgraphs`, and `federation:coverage` locate the supergraph with `SchemaLoader.locate_path` (the conventional dump) or `SUPERGRAPH=`. An app that declared `GraphWeaver.graph :accounts do schema "app/graphql/accounts/supergraph.graphql" end` has already said where it is, but the tasks don't look, so the adopter needed `SUPERGRAPH=` and the default failure ("no routing table here") described the wrong file and named neither the flag nor the graph. `:router` had the same bug and now asks each graph; `federation.rb`'s drift check may also be app-wide where it should be per graph.

## The rule to ship

**The federation tasks run once per declared graph whose schema is a composed supergraph, reporting each by graph name; `SUPERGRAPH=` overrides for one run; a single-schema app with a composed dump behaves exactly as today.** An app with no composed schema anywhere gets one refusal that names the graphs it looked at and the flag. Reuse the lookup `Testing::Config` has rather than writing a second (move it somewhere both can reach — `Internal::Util` or `Graph#composed?` — if that's the honest home; one implementation).

Spec watched failing first in `spec/rake_tasks_spec.rb` (the harness is `spec/support/rake_harness.rb`): two declared graphs, one composed, `federation:diff` with no env var checks that one and names it. The adopter's app at `/tmp/claude/graph_weaver/dogfood-rails-tasks` (Gemfile `path:` — repoint at your worktree) is the live repro: the three tasks with no `SUPERGRAPH=` must work there.

## Ownership

`lib/graph_weaver/tasks.rb`, `lib/graph_weaver/internal/tasks.rb`, `lib/graph_weaver/federation.rb`, `lib/graph_weaver/graph.rb`, `lib/graph_weaver/internal.rb`, `lib/graph_weaver/testing.rb` (only to move the lookup out, if you do), `spec/rake_tasks_spec.rb`, `spec/federation_drift_spec.rb`, `spec/testing_spec.rb` (only if the lookup moves), `docs/federation.md`, `CHANGELOG.md` (a bullet inside the existing federation-tasks block under `### v0.7.0`; nothing under `## Unreleased`), `spec/support/public_surface.txt`. Nobody else is running.

## Gate

Brief-common gate as separate commands; `bin/federation-diff` and `examples/federation.rb` must pass; two random seeds; the dogfood-tasks app's three task outputs pasted before and after.

## Report

Shas; the rule sentence; the refusal verbatim; dogfood outputs before/after; `git status` clean.
