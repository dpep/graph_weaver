# Project Plan — GraphWeaver, typed GraphQL client for Ruby/Sorbet

_Resume-from-here notes: where the project stands and what's next. The README
documents the product, CHANGELOG records what changed, DECISIONS.md records the
roads not taken, NOTES.md is the research notebook this grew out of. Update on
change._

## Vision

A "graphql-codegen for Ruby": `.graphql` queries + a schema (live class,
introspection JSON, SDL, or an Apollo supergraph) → checked-in `# typed: strict`
Ruby — nested `T::Struct`s, generated casting, a typed `execute` — so `srb tc`
sees the exact shape of every query result. Dynamic mode for consoles, a build
step for CI. Runtime deps: `graphql` + `sorbet-runtime`, nothing else.

## State

`0.7.1` published to RubyGems (2026-09-14), a patch on `0.7.0` (2026-09-13).
0.7.0's CHANGELOG entry is the diff from 0.6.1 — multi-graph codegen, the
test modes, input errors, the local router's refusal boundary; 0.7.1's is the
hardening that followed (redaction channels, concurrency locks, the write
path, file names). The upgrade guide has a checklist per step; every entry
marked **Regenerate** changed emitted code. `research/` holds the user-test
logs that drove both.

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
  verified against a real `@apollo/gateway` (72 identical, 2 refused, 0 wrong),
  refusing at plan time anything it can't answer faithfully. One rspec tag picks
  the mode: `graphql: :fake | :in_process | :router`.
- **Lifecycle.** `generate` / `verify` / `schema:refresh` / `schema:diff` /
  `queries:check` / `federation:diff`, plus `rails g graph_weaver:install`.

## Next

Backlog after 0.7.1, each found by a user-test pass and deliberately not done
in the patch. Roughly by value.

1. **A caller-outcome instrumentation event.** A `CastError` closes
   `execute.graph_weaver` as `:ok` and then raises, and every testing double
   emits no event. Moving the extent up to `dispatch` would collapse `Retry`'s
   per-attempt events (`:retries`, per-attempt `:http_status`), so the shape
   is a second event at the module seam for every client kind, with its own
   docs pass — a contract change, not a fix.
2. **Persisted queries.** No `extensions.persistedQuery` is sent and there is
   no hook; a safelist with `require_id` refuses the client outright. A
   manifest task from the generated modules' `QUERY`/`OPERATION_NAME` and an
   APQ register-on-miss transport option (a twelve-line subclass proved it).
3. **Multipart uploads.** A `File` variable is refused by name in every mode;
   the GraphQL multipart request spec is the feature.
4. **`queries:check` / `schema:diff` against a supergraph URL**, so a federated
   app has a pre-deploy check against the live graph; today every CI task
   compares the app to its own artifacts (docs say so and point at rover).
5. **Asymmetric scalars.** One `serialize:` serves both the outbound variable
   and a result's `as_json`, so an object-out/string-in scalar can't round-trip
   through JSON; and an object pin holding a JSON-shaped scalar class
   (`BigDecimal`) reaches the fake's wire unserialized. Both want a real user
   before growing a knob.
6. **A version matrix in CI** (graphql-ruby floor/lock/latest, Rails 7.1–8.x,
   Sorbet latest): the `@oneOf` and `specifiedByURL` omissions each lived a
   release because one version was ever exercised.
7. **Smaller:** a correlation id in the payload; `QueryError#summary`
   graph-aware ("recompose", not "refresh", for a supergraph);
   `source_transport`'s message for a supergraph; the built-in timestamp cast
   is `Time.parse`, the slowest of four (`:iso8601` is 3× cheaper and
   stricter — a behavior change); `null_chance` per coordinate like
   `list_size`; `merge=union` on `CHANGELOG.md`; two cold clients both writing
   the conventional dump once.
8. **Declined, recorded:** `stub_graphql(key).to_return(value)` (declined after a dogfood;
   `to_return` carries nothing `=>` doesn't and the
   name misleads under `:wire`); batching/async (user); an upgrade-guide drill
   (no real users yet).

## Federation router: what it still refuses

Each refuses at plan time with the type, field, subgraphs and next action. The
cost of moving each boundary, if a real query mix ever demands it:

- **`@requires` needing a chain** — the prefetch's own key must come from the
  subgraph in hand; needs a real dependency DAG.
- **An abstract type the supergraph doesn't break down** — a union or interface
  at a boundary now plans, one branch per concrete type, bucketed on
  `__typename` at execution. What is left is the supergraph that doesn't say
  which concrete types a subgraph answers it with — no
  `@join__unionMember`/`@join__implements`, and the type in more than one
  subgraph. Closing it means reading a join version that predates those
  directives; a modern composition always carries them.
- **A nested field set no one fetch can build** — a nested field set now
  crosses as the object it is, to any depth. What is left is the one whose
  fields are split across subgraphs (`origin` in one and `origin.lat` in
  another, or a `@key`'s object a `@requires` would half-fill from
  elsewhere): a representation comes from one fetch, so the object would
  arrive in pieces. Closing it means merging the pieces, which
  `DECISIONS.md` argues against — the shapes that produce a split are the
  ones where a real gateway stops being an oracle.
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
