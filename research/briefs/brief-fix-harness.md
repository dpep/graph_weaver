# Brief: the harness findings — helpers that lose, modes that guess, a wire that leaks

Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, trailers and method; baseline is main **392c609** (1243 examples, surface 450). Read CLAUDE.md, then `lib/graph_weaver/rspec.rb`, `lib/graph_weaver/testing.rb`, `lib/graph_weaver/internal/test_clients.rb`, `lib/graph_weaver/testing/endpoint.rb`, `docs/testing.md`. Worktree branch; don't push.

## Who you are

The staff engineer who owns the rspec harness and just read a new adopter's report. Their closing sentence is your acceptance test: **"Every `graphql_*` helper applies to the example you call it in, and if it cannot reach the module you are about to run, it raises instead of letting the example pass on data nobody pinned."** The library's stated principle is refuse rather than guess; every finding below is a place it guessed. If a fix would need a rule with an exception, say so and stop on it.

## The adopter's app is your repro

`/tmp/claude/graph_weaver/dogfood-rails` (Rails app, `Gemfile` `path:` at the main checkout — repoint it at your worktree: edit the `path:` line, `BUNDLE_GEMFILE=… bundle install` if needed). `NOTES.md` says how to run it. Its specs are the repros, marked `FINDING n` / `REPRO FINDING n`; `spec/support/graph_weaver_workarounds.rb` holds the workarounds. **Run the app's suite before and after**: the `REPRO` examples assert the bug and must start failing; the workarounds should become deletable. Add the durable version of each repro to the gem's own specs (two declared graphs, bound clients, spies — `spec/graphs_spec.rb` and `spec/wire_mode_spec.rb` already have the fixtures).

## Findings, yours, worst first

**F0 — `:wire` makes a real network call when webmock isn't enabled.** `serve!` gates on `defined?(WebMock)`, which Bundler.require makes true in every Rails app with webmock in `:test` — while only `require "webmock/rspec"` (or `WebMock.enable!`) actually installs the adapters. Refuse *before the first request* unless the adapters are enabled, and say `require "webmock/rspec"`. Find the honest signal (WebMock's own API for "am I enabled" if it has one; otherwise whether `Net::HTTP` is the adapter class) and pin it with a spec that loads `webmock` without enabling it. The adopter's probe: `spec/probes/plain_webmock_check.rb`.

**F1 — `graphql_fake` pins are silently ignored in a two-graph app.** The helper installs at `GraphWeaver.client`; under a tag each module resolves its per-graph stand-in, which outranks it. So the pins never apply, and worse, `graphql_fake(pins)` in a multi-graph app refuses without `schema:` and the advice (`graphql_fake(schema: MySchema)`) leads straight into the silent drop. The rule to ship: **a helper called in an example is the stand-in for the module it names — for every graph when it names a schema shared by one, for that graph when `schema:` picks one — and it raises if there is no module it could reach.** Concretely, the helper hands its client to `TestClients` (the `override!` the previous agent sketched), keyed so `graphql_fake(schema: Catalog::Schema)` overrides the catalog graph's stand-in and leaves accounts' alone; `graphql_fake` with no `schema:` in a multi-graph app either refuses (naming `schema:`) or overrides every graph — pick the one you can state in a sentence; I lean refuse, since pins are schema-shaped. `spec/graphql/fake_spec.rb:19`.

**F2 — `graphql_context` never reaches resolvers under `:in_process`, and raises `NoMethodError` under `:router` (`undefined method 'context' for nil` / `for an instance of Transport::HTTP`).** Same root cause: it writes to `GraphWeaver.client`. It must reach every stand-in the example's modules will run through (all graphs' in-process/router clients), and refuse with a message where there is none. `spec/graphql/in_process_spec.rb:22`, `spec/graphql/router_spec.rb:20`.

**F3 — `:router` plans a non-federated graph's module against the *other* graph's supergraph**, then blames a stale dump (`schema may have changed since generation; refresh…`). `:router` must be per graph: a module whose graph has no composed supergraph is refused by name ("graph :catalog isn't in a supergraph — tag it :in_process, or…"), never routed into someone else's. `spec/graphql/router_spec.rb:26`.

**F4 — `:wire` decides "router or live class" once for the suite, so catalog's endpoint is answered by accounts' router; and it refuses outright when `GraphWeaver.client` is unset even though every graph bakes its own client.** Per graph, both: each stubbed endpoint gets *that graph's* stand-in (router when that graph's schema is composed, its live class otherwise), and an app whose graphs all bake clients needs no app-default client for `:wire`. Docs already claim the per-graph behavior — make it true. `spec/graphql/wire_spec.rb:28`.

**F8 — `config.context` set in an rspec `before` is silently ignored** (works from `configure` at load and from `around`). Find out why (hook order: the integration's `before` copies config.context onto the client before the example's `before` runs?) and either make a `before`-set context take effect at execute time (read config lazily) or refuse when it's set too late. Silent is the one outcome not allowed. `spec/graphql/wire_spec.rb:12`.

## Ownership

`lib/graph_weaver/rspec.rb`, `lib/graph_weaver/testing.rb`, `lib/graph_weaver/testing/**` EXCEPT `testing/cassette.rb`, `lib/graph_weaver/internal/test_clients.rb`, `lib/graph_weaver/in_process.rb`, `spec/rspec_spec.rb`, `spec/wire_mode_spec.rb`, `spec/graphs_spec.rb`, `spec/test_clients_spec.rb`, `spec/testing_spec.rb`, `spec/endpoint_spec.rb`, new specs of yours, `docs/testing.md`, `CHANGELOG.md` (fold into the v0.7.0 entries that describe these modes — 0.7.0 is unshipped — one contiguous block), `spec/support/public_surface.txt`. **Another agent owns** `lib/graph_weaver/tasks.rb`, `lib/graph_weaver/internal/tasks.rb`, `lib/graph_weaver/testing/cassette.rb`, `lib/graph_weaver/federation.rb`, `lib/generators/**`, `docs/transports.md`, `docs/getting_started.md`, `docs/cassettes.md`, `docs/federation.md`, `docs/scalars.md`. Report what you'd change there; don't reach.

## Gate and traps

Brief-common gate as separate commands, three random seeds (this area has hidden order-dependent failures twice this week), plus the dogfood app's suite green with its `REPRO` examples flipped to assert the fix or deleted. WebMock stubs removed per example, never `reset!`. `private_constant` at class-body level. `INTEGRATION=1 bundle exec rspec spec/integration/router_parity_spec.rb` if router.rb changes.

## Report

Shas; the rule for helpers in one sentence; per finding: fixed / refused-instead / left, with the message verbatim; the dogfood suite result before and after; what you'd change in the other agent's files; `git status` clean.
