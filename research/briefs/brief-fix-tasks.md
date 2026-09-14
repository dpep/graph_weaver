# Brief: the tasks-and-docs findings — a CI gate that proves nothing, a diff that lies, samples that don't run

Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, trailers and method; baseline is main **392c609** (1243 examples, surface 450). Read CLAUDE.md, then `lib/graph_weaver/tasks.rb`, `lib/graph_weaver/internal/tasks.rb`, `lib/graph_weaver/testing/cassette.rb`, `lib/graph_weaver/federation.rb`, `lib/generators/**`. Worktree branch; don't push.

## Who you are

The production engineer who owns the rake tasks, the generator, and the docs samples, reading a new adopter's report. Their standard: a rake task that exits 1 must be right, and one that exits 0 must have checked something. A doc sample must run as pasted. If a fix needs a special case, say so and stop on it.

## The adopter's app is your repro

`/tmp/claude/graph_weaver/dogfood-rails` — Rails app with two graphs (`:catalog`, `:accounts` with a supergraph whose `prefs` subgraph runs elsewhere), namespaced modules, a recorded cassette. `Gemfile` `path:` points at the main checkout — repoint it at your worktree. `NOTES.md` says how to run things. Reproduce each finding there first, then write the durable spec in the gem (`spec/rake_tasks_spec.rb` and `spec/support/rake_harness.rb` are the rake harness; `spec/cassette_spec.rb`, `spec/federation_drift_spec.rb`, `spec/generator_spec.rb` if present).

## Findings, yours

**F5 — `rake graph_weaver:cassettes:check` sees "0 generated modules" when modules are namespaced**, so it exits 1 having checked nothing, and its advice blames the cassette directory. Without `namespace` it checks 1 and exits 0. Find how the task enumerates modules (probably top-level constants only) and make it find every generated module however it's nested — the graphs know their namespaces and outputs, so ask them. Spec: a namespaced module, a cassette it sent, `cassettes:check` reports 1 checked.

**F6 — `rake graph_weaver:federation:diff` calls an absent subgraph "stale" and says recompose**, while `federation:subgraphs` in the same process correctly reports `"prefs" => nil # no loaded schema defines …`. docs/federation.md promises three states — checked, not here, faked — and "only drift fails the task; absence is a supported setup." Make `diff` honor that: a subgraph no local schema defines is "not here", not stale, and doesn't fail. Spec watched failing first.

**F9 — the unregistered-scalars report goes to `Rails.logger` at info while the unmatched-registration warning goes to stdout** from the same task. One task, one destination: both advisories print where the person running the task is looking. Check what `Internal::Tasks.report_unmatched` does and give the unregistered report the same path.

**F10 — `rails g graph_weaver:install` writes the pre-0.6.1 scalar spelling** (`register_scalar("DateTime", Time, serialize: :iso8601, requires: "time")`) as its example comment. `DateTime` needs no registration; replace the comment with the one-argument form for a scalar that does need it (`register_scalar "Money", BigDecimal`) and, if the generator writes a graph declaration anywhere, make it the block form. Read `docs/scalars.md` for the current spelling.

**F7 — `docs/transports.md` "Building blocks" shows `GraphWeaver::Transport::Faraday.new(url) do |conn| … end`, which raises `NameError` from an initializer** because the constant isn't required. Either autoload it (an `autoload :Faraday` on `Transport`, so the constant works when faraday is present and the LoadError names the gem when it isn't — check that this doesn't make `require "graph_weaver"` load faraday) or put `require "graph_weaver/transport/faraday"` in the sample. Prefer the autoload if it's one line and honest; the sample must then run as pasted. Run it.

**F11 — the docs never say what `client` in a graph block *is*.** getting_started shows `client "Billing::Schema"` and `client "GITHUB"` without saying the value is a constant (or its name) baked into generated source, resolved at first use, and that a URL doesn't go there — the constant holds the client built from the URL. One paragraph in getting_started's "More than one schema", where `client` first appears; the graph-block reference in the same section lists what each of the six settings takes in one line each.

## Ownership

`lib/graph_weaver/tasks.rb`, `lib/graph_weaver/internal/tasks.rb`, `lib/graph_weaver/testing/cassette.rb`, `lib/graph_weaver/federation.rb`, `lib/graph_weaver/transport.rb` (autoload only), `lib/generators/**`, `lib/graph_weaver/railtie.rb` if F9 needs it, `spec/rake_tasks_spec.rb`, `spec/support/rake_harness.rb`, `spec/cassette_spec.rb`, `spec/federation_drift_spec.rb`, generator specs, new specs of yours, `docs/transports.md`, `docs/getting_started.md`, `docs/cassettes.md`, `docs/federation.md`, `docs/scalars.md`, `CHANGELOG.md` (one contiguous block under v0.7.0 for the task fixes — 0.7.0 is unshipped; the other agent also edits CHANGELOG, keep yours contiguous), `spec/support/public_surface.txt`. **Another agent owns** `lib/graph_weaver/rspec.rb`, `lib/graph_weaver/testing.rb`, the rest of `lib/graph_weaver/testing/**`, `lib/graph_weaver/internal/test_clients.rb`, `docs/testing.md`. Report anything you'd change there; don't reach.

## Gate

Brief-common gate as separate commands; `bin/federation-diff` and `examples/federation.rb` must still pass after F6; the dogfood app's `rake graph_weaver:cassettes:check`, `federation:diff`, and `generate` output pasted into the report before and after.

## Report

Shas; per finding: fixed / left, with the new output verbatim; the dogfood task outputs before and after; what you'd change in the other agent's files; `git status` clean.
