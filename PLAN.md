# Project Plan — GraphWeaver, typed GraphQL client for Ruby/Sorbet

_Resume-from-here notes: where the project stands and what's next. The README
documents the product, CHANGELOG records what changed, NOTES.md is the research
notebook this grew out of. Update on change._

## Vision

A "graphql-codegen for Ruby": `.graphql` queries + a schema (live class,
introspection JSON, SDL, or an Apollo supergraph) → checked-in `# typed: strict`
Ruby — nested `T::Struct`s, generated casting, a typed `execute` — so `srb tc`
sees the exact shape of every query result. Dynamic mode for consoles, a build
step for CI. Runtime deps: `graphql` + `sorbet-runtime`, nothing else.

## State

`0.4.6` on RubyGems. `main` carries a large unreleased body of work headed for
**0.5.0** — see `## Unreleased` in the CHANGELOG, which is long and has a real
upgrade story to tell.

Green gate is in `CLAUDE.md`; `make check` runs the core of it.

**What's built**, in brief — the CHANGELOG has the detail:

- **Codegen.** Queries and mutations, typed variable kwargs, fragments (inline,
  named, shared across queries), unions and interfaces (a struct per named
  condition plus a forward-compatible `Other`), enums as `T::Enum`, custom
  scalars, `@skip`/`@include` nullability. Generated class names derive from the
  response key, so they're stable under unrelated edits. Shared types live once
  per schema in `GraphQLTypes`.
- **Sources.** Live schema class, introspection JSON, SDL, Apollo supergraph
  (composition machinery stripped, `@inaccessible` subtracted to the API schema —
  verified identical to Apollo's own `toAPISchema`), and raw subgraph SDL.
- **Transports.** `Transport::HTTP` (zero-dep, pooled, keep-alive) by default;
  Faraday on explicit opt-in. `InProcess` wraps a live schema class with
  `context:`, logging and branded errors. Composable `Retry` honouring
  `Retry-After`. One instrumentation seam covering both paths.
- **Errors.** A typed `Response` envelope, an error hierarchy split by failure
  site, field-level reporting with entity ids, `schema_stale?`, `#to_h`
  throughout.
- **Testing.** Schema-correct fakes, failure simulation, anonymizing cassettes,
  and an in-process federation router that runs real subgraph resolvers —
  verified against a real `@apollo/gateway` (42 identical, 1 refused, 0 wrong),
  refusing at plan time anything it can't answer faithfully. One rspec tag picks
  the mode: `graphql: :fake | :in_process | :router`.
- **Lifecycle.** `generate` / `verify` / `schema:refresh` / `schema:diff` /
  `queries:check` / `federation:diff`, plus `rails g graph_weaver:install`.

## Next

1. **Cut 0.5.0.** Needs an upgrade guide rather than a changelog dump — the
   breaking list is long, but most of it is caught mechanically, so the guide is
   largely *"regenerate, then follow `srb tc` and `verify_generated!`"*.
   `gem push` needs an OTP.
2. **`extend_type`'s mixin forms can't be statically checked.** A mixin's method
   bodies are checked in the module's scope, not the struct's, so the docs have
   to recommend `# typed: false` or `T.unsafe(self)`. In a library whose pitch is
   static checking, that's a seam worth a design pass. Note `alias:` — which
   emits into the struct body — *is* checked, which suggests the mixin forms are
   the ones carrying the cost.
3. **Nice-to-haves, unclaimed.** `write_timeout` on `Transport::HTTP` (and
   possibly a `net_http:` passthrough rather than more kwargs); a Tapioca DSL
   compiler so dynamic `parse` modules get static types without the build step.

## Federation router: what it still refuses

Each refuses at plan time with the type, field, subgraphs and next action. The
cost of moving each boundary, if a real query mix ever demands it:

- **`@requires` needing a chain** — the prefetch's own key must come from the
  subgraph in hand; needs a real dependency DAG.
- **Abstract type at a boundary** — needs per-possible-type planning to build
  representations from a runtime `__typename`.
- **Nested `@key`/`@requires` field sets** — representations are flat; mostly
  plumbing, ~30 lines.
- **Mutation root fields spanning subgraphs** — root mutation fields run in
  series, so grouping them would run them in plan order.
- **An alias shadowing an injected `@key`** — Apollo resolves the collision in
  favour of its own key and a spec-conformant server doesn't, so there is no one
  answer to agree with. Unfixable by design.

`rake graph_weaver:federation:coverage` reports the refusal rate against a real
supergraph and query set. That number decides whether any of the above is worth
building — on the demo corpus it is 17/17.

## Stated non-goals

Recorded so they read as decisions rather than omissions, with the reasoning in
`REVIEW.md` §7: subscriptions, `@defer`/`@stream`, file uploads, normalized
caching, fragment masking, request batching, and a watch mode.

## Gotchas worth remembering

- graphql-ruby's `to_definition`/`from_introspection` reorder enum values and
  possible types — codegen sorts both; keep any new emission deterministic.
- Schemas built from introspection or SDL have no scalar coercion or resolvers,
  so codegen stays name-keyed and never calls schema runtime hooks.
- A `SchemaDefinition` node reprints without its body when the root type names
  are the GraphQL defaults, so directives on `schema` must be stripped before
  reprinting a supergraph.
- Code the build doesn't exercise rots silently — integration specs excluded from
  the default run, examples the generator skips, doc samples nobody executes.
  Six fabricated doc samples were found in one session by running them.
