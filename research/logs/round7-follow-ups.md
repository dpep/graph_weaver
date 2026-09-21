# Follow-ups — declined and deferred, with reasons (don't re-report)

- Long result type names (`Foo::BarQuery::Result::Baz`): no codegen change; the
  app-side constant alias is the documented answer (research/naming-options.md).
- A custom name for a generated enum's fallback member: declined; `fallback: true`
  gives `Other`/`Other2` by the union rule; map onto your own T::Enum to name it.
- Graph-aware `QueryError#summary`: declined; the error can't reach the module's graph.
- An `alias:` path reading THROUGH a hoisted fragment struct: refused by design (may end on one).
- Recursive hoisting of a spread nested inside a hoisted fragment: inlines, as unions do.
- `stub_graphql(key).to_return`, request batching/async, a Tapioca compiler: declined (PLAN.md).
- `:wire` on an app where NO graph posts anywhere: still refused whole (by design).
- Bare `null_chance: 50` / `list_size:` scalar forms aren't range-validated (known, deferred).
- Backlog, not bugs: persisted queries/APQ, multipart uploads, correlation id,
  two cold clients writing the dump once, caller-outcome event (a lane is building it now).
