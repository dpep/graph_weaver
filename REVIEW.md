# Library review — 2026-09-05

A six-agent review of graph_weaver 0.4.6: codegen/runtime corner cases, fresh-install
DX against a live public API, Apollo Federation coverage, transport/performance, a
competitive analysis of the field, and a survey of what users of peer libraries
actually complain about.

Sibling of `PLAN.md` (the roadmap) and `NOTES.md` (the research notebook). This is the
findings document: what's broken, what's missing, and what the field says is worth
building. Items are marked **PROVEN** (a repro was run) or **REASONED** (argued from
code or spec, not executed). Findings verified independently a second time are marked
**✓verified**.

Baseline at review time: 308 examples green, `srb tc` clean, tree clean.

---

## 1. The one-paragraph version

The library is in better shape than its version number suggests, and its instincts are
right: query-driven codegen, a typed error envelope, a real testing harness, and schema
lifecycle management are four of the seven structural problems of this category, and
graph_weaver has independently landed on good answers to all four — while under-selling
every one of them. The defects worth fixing are concentrated and specific: one silent
data-corruption bug in union narrowing, one documented-but-absent nullability behaviour,
a federation loader that rejects the artifact teams actually have, a default HTTP
transport that serializes every request in the process, and one measured violation of
its own stated "generate only what the query touches" invariant that produces 5,386
lines for a two-condition query. Fix those and the remaining gaps are features, not
faults.

---

## 2. Confirmed bugs

Ranked by severity. These are the implementation backlog.

### B1 — Narrowing + `__typename` silently casts members into the wrong struct
**PROVEN ✓verified · HIGH · `codegen.rb:416`, `codegen/nodes.rb:260-262`**

When a selection narrows to a single type condition (`... on Person { … }`) *and* also
selects `__typename`, codegen still takes the narrowing branch. But narrowing's
"this isn't my type" test is *did the object come back empty?* — and selecting
`__typename` guarantees it never is.

```ruby
query { search(term: "el") { __typename ... on Person { email } } }
# emits: v3.empty? ? nil : Person.from_h(v3)

Result.from_h("search" => [{ "__typename" => "Person", "email" => "d@e.f" },
                           { "__typename" => "Pet" }])
# => [Result::Person __typename="Person" email="d@e.f",
#     Result::Person __typename="Pet"     email=nil]   # <- a Pet, typed as a Person
```

If the member has a non-null field you get a confusing `TypeError: key not found`.
If its fields are all nullable you get **silent corruption**. This is the exact shape
of a federation `_entities { __typename ... on Widget { … } }` query, and "always
select `__typename`" is a widespread habit.

`docs/generated_modules.md:252` claims narrowing "skips the dispatch (and the
`__typename`) entirely" — the code allows it anyway.

**Fix:** when `__typename` is present, dispatch on the tag rather than on emptiness:
`data["__typename"] == "Pet" ? Pet.from_h(data) : nil`. Strictly better than the
emptiness heuristic, and it removes the need for the `unconditional_field?` guard in
this case.

### B2 — `@skip`/`@include` on a fragment doesn't make its fields nilable
**PROVEN · HIGH · `codegen.rb:471-475`, `selection.rb:42-53`**

Directive handling inspects *field* nodes only; `Selection#each_field` recurses into
inline fragments and named spreads without carrying their directives down. Fields
reached through a conditional fragment keep non-null typing and get `data.fetch(...)`.

```ruby
query Q($s: Boolean!) { people { id ... on Person @skip(if: $s) { name } } }
Result.from_h("people" => [{ "id" => "1" }])
# => GraphWeaver::TypeError: key not found: "name"
```

Identical for a named spread with a directive. Directive-on-a-spread is legal GraphQL
and the ordinary way to make a whole block conditional; the README advertises
"`@skip`/`@include` nullability" without qualification.

**Fix:** thread a conditional flag through `each_field` so `object_node` strips
`NonNull` for anything under a conditional fragment. `FakeClient` and `Anonymizer` walk
the same `Selection` module, so they stay in step for free.

### B3 — Abstract types generate a struct per schema member, not per selected condition
**PROVEN ✓verified · HIGH · `codegen.rb:693`**

`union_members` maps over `@schema.possible_types(type)`. Measured against the GitHub
schema already committed at `examples/github/schema.json`, where `Node` has 278
possible types:

```
query GetThread($id: ID!) {
  node(id: $id) {
    __typename
    ... on PullRequestReviewThread { isResolved }
    ... on Issue { title }
  }
}
```

→ **5,386 lines / 193 KB**, 278 `T::Struct`s of which **275 hold nothing but
`const :__typename, String`**, and a `T.any` with 278 members. Generation itself is
fast (0.021s); the cost is checked-in volume, `srb tc` load, PR reviewability, and a
`T.absurd` exhaustiveness story that is unwritable at 278 branches.

This violates the stated invariant in `CLAUDE.md` — "codegen is query-driven … only for
the types a query actually touches" — in exactly one place. It has an exact twin in the
wild: [genqlient #416](https://github.com/Khan/genqlient/issues/416), and The Guild
conceded the same disease in
[graphql-codegen v6](https://the-guild.dev/graphql/hive/blog/graphql-codegen-client-v6-202604)
("large generated files filled with types you never use").

**Fix:** emit a member struct only for types the selection actually names, plus **one**
catch-all `Other` carrying the interface-level fields. This answers the maintainer
objection raised on genqlient #416 ("the server can still return a type you have no
fragment on") and mirrors the shape of its PR #419. `T.absurd` becomes writable *and
stays writable* when the schema grows a type. Add a spec asserting generated size is
O(named conditions), not O(possible types) — the bound is the feature.

### B4 — A schema-level directive makes a supergraph unloadable
**PROVEN ✓verified · HIGH · `schema_loader.rb` (`strip_federation`)**

Any directive on the `schema` definition — `@tag`, `@composeDirective`, or a
`@composeDirective`'d custom SCHEMA directive — produces:

```
GraphQL::ParseError: Expected LCURLY, actual: DIRECTIVE ("directive") at [4, 1]
```

Root cause is in graphql-ruby's printer, isolated:

```ruby
GraphQL.parse('schema @foo { query: Query } directive @foo on SCHEMA type Query { hi: String }')
  .definitions.first.to_query_string
# => "schema\n  @foo"     <- directives printed, `{ query: Query }` body omitted
```

`SchemaDefinition#to_query_string` omits the root-types body when root type names are
the GraphQL defaults but still prints retained directives, so the reprint emits a
braceless `schema @tag(...)`. `@link`/`@core` are stripped, so current specs never hit
it; anything else on `schema` does. The error's line number refers to a document the
user never wrote.

**Fix:** strip *all* directives from the `SchemaDefinition` node (codegen never reads
them), or drop the node when root types are conventional.

### B5 — Subgraph SDL cannot be loaded at all
**PROVEN · HIGH · `schema_loader.rb`**

A raw subgraph schema — from `rover subgraph fetch`, `_service { sdl }`, or the
`.graphql` in a service repo — dies with an unbranded
`NoMethodError: undefined method 'get_argument' for an instance of GraphQL::Schema::LateBoundType`.

This is the artifact teams most often have, and it is the *only* way to type an
`_entities` query, since `_entities`/`_service` are deliberately absent from a
supergraph.

**Fix (proven in probe):** detect a subgraph SDL and prepend the federation directive
definitions it references but doesn't define. Add `subgraph_sdl?` alongside
`federation_sdl?` plus a `SUBGRAPH_DIRECTIVE_DEFS` constant; inject only definitions not
already present. Both fed-1-style and `@link`-style subgraphs loaded cleanly once
definitions were injected.

### B6 — Result enums and variable enums are incompatible types
**PROVEN ✓verified · MEDIUM · `codegen.rb:454-462` vs `codegen.rb:745-746`**

A result field's enum builds a fresh nested `EnumNode`; the same GraphQL enum as a
variable registers in `@variable_enums` (hoisted to `GraphQLInputs`). Nothing reconciles
them.

```
result enum class:   M1::Result::Pet::Species
variable enum class: M1::Species
equal?               false
round-trip: TypeError: Parameter 'species': Expected T.any(M1::Species, String),
            got M1::Result::Pet::Species
```

Reading a value out and feeding it back — echoing a filter, re-submitting a status — is
an obvious move and fails at both `srb tc` and runtime. Found independently by two
agents from opposite directions (reading the emitter; hitting it live after a mutation).

**Fix:** when a result field's enum is also a variable type in the same module, reuse
the shared `@variable_enums[name]` node.

### B7 — Enum-in-a-list variables reject wire strings
**PROVEN · MEDIUM**

`docs/generated_modules.md:179` states unconditionally that enum variables "accept the
enum or its wire value". True for a scalar enum, false inside a list:

```ruby
execute!(type: "ANIME")                            # works
execute!(type: "ANIME", sort: ["POPULARITY_DESC"]) # NoMethodError: undefined method 'serialize' for String
```

```ruby
"type" => (type.is_a?(MediaType) ? type : MediaType.deserialize(type)).serialize,   # coerces
variables["sort"] = sort.map { |v1| v1&.then { |v2| v2.serialize } }                # doesn't
```

Sorbet's runtime doesn't deep-check array elements, so the sig doesn't catch it either;
the user gets a raw `NoMethodError` naming neither the variable nor the enum.

**Fix:** emit the same `is_a? ? : .deserialize` inside the map, widen the element type.

### B8 — Cassette recording is broken for the call the docs show
**PROVEN ✓verified · MEDIUM · `testing/cassette.rb:133`**

`docs/cassettes.md:13` shows `Cassette.use("github", client: live)`. Passing a `Client`
— which the kwarg name invites and the doc demonstrates — fails:

```ruby
c = GraphWeaver::Testing::Cassette.use("anilist", client: live)
SearchMediaQuery.execute!(c, search: "x", type: "ANIME")
# ArgumentError: missing keywords: :search, :type
```

`Recorder` calls `@client.execute(query, variables:)`, but `Client#execute` is
`execute(query, **variables)` — the one-shot surface, not the transport contract. So
`variables:` is swallowed as a kwarg named `variables`. This is the duck-typed-client
invariant leaking: every other call site unwraps via `GraphWeaver.resolve_transport`;
the recorder forgot.

**Fix:** `@client = GraphWeaver.resolve_transport(client)` in `Recorder#initialize`.

### B9 — Global registrations are never validated, so typos silently no-op
**PROVEN ✓verified · MEDIUM · `codegen.rb:383-387`**

`validate_registrations!` iterates only the client-scoped `@enums`/`@scalars`/`@types`.
The global registries — the path `getting_started.md` step 3 explicitly recommends — are
never walked.

```ruby
GraphWeaver.extend_type("Medai", MediaHelpers)   # typo
GraphWeaver.generate!                            # SUCCEEDS. Helper never applied. No warning.
```

The good error already exists and fires only on the client-scoped path:
`extend_type("Medai") matches no type in this schema — did you mean 'Media'?`

**Fix:** walk the global registries too.

### B10 — Two result keys that underscore to the same prop emit an unloadable file
**PROVEN · MEDIUM · `codegen.rb:402`**

`prop = underscore(key)` with no collision check — the exact check added for variable
kwargs in v0.4.6. Generation succeeds; the file can't be loaded.

```ruby
query { person(id: "1") { name Name: name } }
# => ArgumentError: Attempted to redefine prop :name
```

Reachable with a plain alias; no exotic schema needed.

**Fix:** mirror the variable-collision check in `object_node`.

### B11 — Output props aren't checked against reserved names
**PROVEN · MEDIUM · asymmetry with `codegen.rb:766-770`**

`input_node` validates props against Ruby keywords and generated methods; output structs
validate nothing. A GraphQL field named `class`, `hash`, `send`, `to_h` or `freeze`
generates a file that raises at `require` time. Fields named `class` are not
hypothetical.

**Fix:** run the same reserved-name check on output props, raising at generation with a
suggestion to alias in the query.

### B12 — A multi-operation document silently types only the first operation
**PROVEN · MEDIUM · `selection.rb:22`**

`load_operation` takes `.first`, `emit_module` puts the *whole* document in `QUERY`, and
no transport sends `operationName`. So a file holding two operations types one and sends
a request the server must reject with "Must provide operation name". Several operations
per file is a common habit.

**Fix:** raise at generation when the document holds more than one `OperationDefinition`
(the small, honest change), or plumb `operationName` through — see F4.

### B13 — `from_response` lets malformed envelopes escape as raw Sorbet `TypeError`
**PROVEN · MEDIUM · `emit.rb:485-493`**

v0.4.6 branded the transport-level malformed-body cases, but `from_response` is
documented public API and is unguarded. A non-Hash `data`, a Hash `errors`, an array of
strings for `errors`, and a non-Hash `extensions` all escape the `GraphWeaver::Error`
umbrella.

**Fix:** shape-check in the emitted `from_response`.

### B14 — `spec/integration/federation_spec.rb:95` calls a method that doesn't exist
**PROVEN ✓verified · LOW (test-only)**

`router.executor` — `Client` exposes `transport`/`transport!`. `executor` survives only
as a generated-`execute` kwarg. Hidden because `:integration` specs are excluded from
the default run; with the call fixed, the spec passes against a live gateway.

**Fix:** rename, and consider a CI job that at least *loads* the integration specs — a
stale method reference survived several releases.

### B15 — Smaller confirmed items

| | Finding | Where |
|---|---|---|
| B15a | `GraphQL::ParseError` escapes unbranded — `inline_fragments` parses before `Codegen#generate`'s rescue | `codegen.rb:336,344` |
| B15b | A custom scalar whose cast raises anything but `TypeError`/`ArgumentError`/`KeyError` escapes the umbrella (`JSON::ParserError`, `Money::ParseError`) | `emit.rb:356` |
| B15c | Enum values differing only in case collide into one constant (`enum E { active ACTIVE }`), raising at load not generation | `emit.rb:303` |
| B15d | `@skip` on the narrowing inline fragment itself isn't caught by the all-conditional guard | `codegen.rb:431`, `659-664` |
| B15e | `@skip` on `__typename` breaks a dispatched union's unguarded `data.fetch("__typename")` | `codegen.rb:687`, `emit.rb:387` |
| B15f | A field selected both conditionally and unconditionally is typed over-nilably (`any?` should be `all?`) | `codegen.rb:473` |
| B15g | `@oneOf` input objects get no exactly-one validation | `codegen.rb:758-777` |
| B15h | `extend_type(requires:)` isn't checked for loadability, unlike `register_scalar(requires:)`; the emitted `require` also needs `$LOAD_PATH` (true in Rails, not a plain app) | |
| B15i | Directive-definition arguments aren't pruned by the `@inaccessible` cascade — bare `RuntimeError`. Composition almost certainly forecloses this; the defect is the unbranded error | |
| B15j | `Hints` defines `method_missing` without `respond_to_missing?` | `hints.rb:43` |

---

## 3. Ergonomics, errors, and documentation

Cheap, high-ratio fixes. Most are a line or two.

### Documentation defects
- **`docs/testing.md:75-79`** passes the client as a `client:` kwarg across five lines;
  generated `execute` takes it **positionally**. The same file gets it right on line 19.
  Highest doc-damage-per-character in the repo. **PROVEN ✓verified**
- **`README.md:84`** — "module names derive from the operation name (`query GetPerson`
  → `GetPerson`)" is true only for `parse` on a *raw string*. For a file — both
  `parse(path)` and the rake task, i.e. the documented production path — the operation
  name is ignored and it's `<FileName>Query`. `docs/generated_modules.md:310` states it
  correctly. **PROVEN**
- **`docs/generated_modules.md:252`** says narrowing skips `__typename` entirely; the
  code allows it (see B1).
- **`docs/generated_modules.md:179`** overstates enum wire-value acceptance (see B7).
- **`docs/federation.md`** doesn't mention that federation **v1** supergraphs
  (`@core`/`@join__owner`) load correctly — proven — and doesn't note that
  `@inaccessible` is only subtracted on the supergraph path.
- **`docs/cassettes.md`** references `MissingRecording` as though nested under
  `Cassette`; it's `GraphWeaver::Testing::MissingRecording`.
- **`schema_loader.rb:214`** recommends `.graphql` for reviewable diffs and says both
  formats "load back identically" — true semantically, misleading on cost: **374 ms vs
  173 ms** on GitHub's schema. One sentence fixes it.

### Error messages worth improving
- **Codegen errors never name the query file**, and drop line/col they already capture.
  `ValidationError` populates `line`/`column` via `validation_detail` then joins only
  `message`; `generation_plan` has `path` in scope and never passes it. Wanted:
  ```
  invalid query in app/graphql/queries/typo.graphql:
    4:5  Field 'titel' doesn't exist on type 'Media' (Did you mean `title`?)
  ```
- **A strict `alias:` breaks unrelated queries** and the message doesn't name its own
  fix. `optional: true` is documented and resolves it; given how consistently this
  library puts the fix *in* the message, this one should end with
  `— pass optional: true to skip selections that don't fit`, and say which query failed.
- **`GraphWeaver.resolve_transport` passes anything through unchecked**, so a bad client
  surfaces as `NoMethodError … for an instance of Hash`. A one-line guard would have
  made the `docs/testing.md` error self-diagnosing.
- **`rake graph_weaver:schema:refresh` can't bootstrap** and says so unhelpfully — it
  needs the url recorded in the dump. Since `GraphWeaver.client` is already a url client
  at that point, refresh could use it.
- **A bare host** (`GraphWeaver.new("graphql.anilist.co")`) reports "unsupported schema
  format"; the cause is the missing scheme. Also an `ArgumentError`, not a
  `GraphWeaver::Error`.
- **Unregistered custom scalars silently become `T.untyped`** with no output. For a
  library whose pitch is exact result shapes, this deserves a line:
  `3 unregistered custom scalars → T.untyped: CountryCode, FuzzyDateInt, Json`.

### Ergonomic gaps
- **`FakeClient` override keys aren't validated.** `@overrides.fetch("Person.nmae")`
  silently does nothing and the test passes against random data — a test that has
  quietly stopped pinning what it thinks it pins. `Codegen.validate_registration!`
  already validates `Type.field` coordinates with spellchecked errors; call it from
  `FakeClient#initialize`. Apollo Kotlin has the same problem
  ([#4435](https://github.com/apollographql/apollo-kotlin/issues/4435), 11 reactions);
  graph_weaver's global `Testing.configure` is already the thing they're asking for.
- **No documented way to reach the schema inside an `auto_fake` spec** —
  `FakeClient#schema` doesn't exist though it holds one, and `Testing.config.schema` is
  documented only as a writer.
- **Mutations generate `…Query` modules** — `SaveListEntryQuery.execute!` reads wrong
  for a write.
- **`load_queries!` silently replaces loaded constants**, so previously-built structs
  become instances of an orphaned class and `is_a?` starts failing. Painful in a console.
- **`Response` has no `ok?`/`success?`** — `errors?` is the idiom, but people reach for
  the positive.
- **`register_enum("X", Y, {…})`** (guessing a positional map) gives a bare
  `ArgumentError: wrong number of arguments` with no hint that `map:` is the kwarg.

### Packaging
The packaged gem installs and runs clean from a scratch `GEM_HOME` — **no `s.files`
gaps**. It does ship `CLAUDE.md`, `PLAN.md`, `NOTES.md`, `Gemfile.lock` and now this
file; harmless, but they're internal.

---

## 4. Feature gaps

### Federation

| Item | Status | Note |
|---|---|---|
| Composed fed-2 supergraph SDL | works | join v0.5, `@join__implements`/`@unionMember`/`@enumValue`/`isInterfaceObject`/`overrideLabel` all strip cleanly |
| Federation **v1** supergraph (`@core`/`@join__owner`) | works | undocumented; docs claim v2 only |
| Router API schema / live introspection | works | integration spec passes against a real `@apollo/gateway` |
| **Raw subgraph SDL** | **broken** | B5 |
| **Any `schema`-level directive** | **broken** | B4 |
| `@inaccessible` cascade | **correct** | stress-tested against Apollo's composition rules; both spec-mandated residual behaviours implemented, the one genuinely-reachable edge (inaccessible Mutation root) handled, loop terminates |
| `@link` `import:` renames, default namespacing (`@federation__inaccessible`) | silently wrong | hidden fields survive into the API schema |
| `federation__Scope` / `federation__Policy` / `context__ContextFieldValue` | leak into `schema.types` | any graph using `@requiresScopes`/`@policy`/`@context` — i.e. fed 2.5+ auth |
| `_entities` representations | read side good, input side untyped | `alias: {entity: "_entities.first"}` works well; `representations:` is bare `T::Array[T.untyped]` |
| `@defer`/`@stream` | unsupported | fails cleanly; see §7 |

**F1 — Derive `@link` namespaces instead of hardcoding prefixes.** Replace
`FEDERATION_PREFIXES = %w[join__ link__ core__]` with prefixes computed from the schema's
own `@link`/`@core` declarations — the URL's penultimate path segment, overridden by
`as:`, plus the `import:` list with `{name:, as:}` renames. This is precisely the
[core spec's](https://specs.apollo.dev/core/v0.1/) API-derivation rule. **One change
fixes four defects**: the `federation__*` leak, the `@link(as:)` leak, renamed
`@inaccessible` being missed, and the `@core`-only leak — and it restores the invariant
`docs/federation.md` already promises. Metadata proven reachable off the parsed
`SchemaDefinition`. *Effort: M.*

**F2 — Typed `_entities` representations.** With B5 fixed, parse `@key(fields:)` during
subgraph load and emit a per-member builder
(`UserQuery::Representations.user(id: "1")` → `{"__typename" => "User", "id" => "1"}`).
Today the user hand-builds representations with no check that `__typename` is present or
that the key field set is satisfied — both hard requirements of the subgraph spec.
Stays within the leaf-codec/decoration invariant: this is generation, not a new
deserializer path. *Effort: M–L; worth a design note first.*

**F3 — Brand `SchemaLoader` failures under `GraphWeaver::Error`.** v0.4.6 made "malformed
inputs stay branded" an invariant; the loader violates it on every federation-shaped
failure — `NoMethodError`, `GraphQL::ParseError`, `InvalidDefaultValueError`, bare
`RuntimeError`. Pairs naturally with B5: *"this looks like a subgraph SDL; weaver can
load it, but you fed it as X."* *Effort: S.*

### Transport

**F4 — Send an `Accept` header and `operationName`.** **PROVEN by wire capture.** Both
transports send only `Content-Type: application/json`; net/http supplies `accept: */*`.
The [GraphQL-over-HTTP draft](https://graphql.github.io/graphql-over-http/draft/) says a
conforming client **MUST** send `application/graphql-response+json`. So a spec-conformant
server has no signal to use the newer media type and we stay on legacy status-code
semantics forever. Add a real `User-Agent` in the same change — server operators
currently can't attribute traffic.

`operationName` is never sent either, so every request is anonymous in Apollo Studio,
Hasura, and every APM that keys traces on it. Codegen already knows the name; emit it as
a constant beside `QUERY` and widen the contract to
`execute(query, variables:, operation_name: nil)` — the optional kwarg keeps the
duck-typed slot intact, and `Schema.execute` happens to accept `operation_name:` too.
*Effort: header, an hour; operationName, ~1 day (ripples to FakeClient/Cassette/Retry).*

**F5 — Connection pool in `Transport::HTTP`.** **PROVEN ✓verified.** `@mutex.synchronize`
wraps the entire round trip, so one transport = one in-flight request process-wide — and
`GraphWeaver.client = api` is the documented pattern. Measured against a 10 ms-latency
server, 8 threads × 5 calls: **488 ms shared vs 72 ms with 8 transports (~6.8×)**. A
prototyped `SizedQueue` pool of 5 gave **1152 ms → 291 ms (4.0×)** at 8 threads × 10
calls. Invisible on localhost because the penalty scales with *server latency*, not CPU.
~40 lines, entirely inside `transport/http.rb`'s private section, plus a `pool_size:`.
*Effort: ~0.5 day. Highest-value transport item.*

**F6 — Faraday timeouts and passthrough.** Faraday is **auto-selected** on
`defined?(::Faraday)` — and Faraday rides in transitively via stripe/octokit — so most
Rails apps get it without choosing it. It opens **a connection per request** (20 TCP
accepts for 20 requests) and `Transport::Faraday.new` takes no timeout knobs, leaving
net/http's **60 s/60 s** — 6× and 2× the documented `Transport::HTTP` defaults, on the
transport you're more likely to get. `GraphWeaver.new(url, …)` exposes no
`open_timeout:`/`read_timeout:` at all. A missing timeout is an outage, not a slowdown.
Also consider preferring `:net_http_persistent` when loadable, or logging which adapter
was auto-picked. *Effort: ~0.5 day.*

**F7 — In-process is a second-class citizen.** **PROVEN.** Correct, but blind:
- **No `context:`** — `Schema.execute` accepts one, nothing supplies it. A resolver
  reading `context[:current_user]` gets `nil` and it surfaces as
  `Cannot return null for non-nullable field Query.me`. For server-side composition,
  context *is* the request.
- **Zero logging** — all logging lives in `Transport#execute`, which an in-process
  schema bypasses entirely. Not one line at DEBUG.
- **Errors unbranded** — a resolver raise surfaces as raw `RuntimeError` in-process vs
  `GraphWeaver::ServerError` over HTTP, so `rescue GraphWeaver::Error` catches one and
  misses the other.

A ~50-line `GraphWeaver::InProcess` wrapper closes all three (verified working), wired
into `Client#initialize` so `GraphWeaver.new(MySchema, context: {…})` works. Logging
belongs to the client slot, not to `Transport` — this is the right home. *Effort: ~0.5 day.*

**F8 — Preserve the HTTP response.** `Transport::HTTP#post` returns `[status, body]`;
`ServerError` carries `status`/`body` only; `Retry` has **zero** references to
`Retry-After` or 429. Real code monkey-patches the transport to recover headers —
libraries.io overrides `GraphQL::Client::HTTP#execute` wholesale to capture
`x-ratelimit-remaining` and build `rate_limited?`/`unauthorized?` predicates. Don't widen
the duck-typed contract: add `headers` to `ServerError` (the `Net::HTTPResponse` is
already in hand), teach `Retry` to honour `Retry-After`, and optionally expose
`last_response_headers` on a transport. This is the difference between being
retry-correct against GitHub/Shopify and not. *Effort: S–M.*

**F9 — An instrumentation seam.** `logging.rb` is the entire observability story: no
`ActiveSupport::Notifications`, no callback, no way for an APM to time a call or count
errors by code. For a gem that ships a railtie, that's the notable omission.
`GraphWeaver.instrumenter = ->(event, payload, &blk) { … }` defaulting to a no-op, called
in `Transport#execute` and in the `InProcess` wrapper — one seam, both paths, and
`ActiveSupport::Notifications` becomes a 2-line adapter. *Effort: ~1 day.*

**F10 — `RateLimitError` / a throttle predicate.** `retry_codes: ["THROTTLED"]` exists
and `THROTTLED` appears three times in the docs as a hand-written string; everyone
writes this class themselves. Promote it to a named `QueryError` subclass recognizing
common codes plus HTTP 429 once F8 lands. *Effort: XS.*

**F11 — CA/mTLS knobs on `Transport::HTTP`.** Today the answer is "use Faraday", which
is a real answer but undiscoverable. Four kwargs forwarded to `Net::HTTP.start`.
*Effort: ~2 h.*

### Category-level features

**F12 — Union `fallback:` for forward compatibility.** `emit_union` generates
`else raise … "unexpected __typename"`. An upstream team adding a union member — a
**non-breaking** change by every schema-evolution convention — hard-fails every response
carrying it, though your selected fields remain valid. `register_enum(…, fallback:)`
already exists for exactly this, and `docs/scalars.md` sells it as letting responses
"keep flowing instead of raising". Enums get forward-compatibility; unions, the more
common evolution point in a federated graph, don't. Both Rust clients treat this as
first-class (cynic *requires* a fallback variant). **Honest tension:** a fallback weakens
the `T.absurd` story — with one, exhaustiveness is over *generated* members rather than
*schema* members. That's the right trade, and it's why it must be opt-in and documented
plainly. Note B3 largely subsumes this: the catch-all `Other` is the same mechanism.
*Effort: S.*

**F13 — Hoist shared object fragments.** Already done for **unions** (v0.4.0: a lone
shared spread hoists into `GraphQLUnions`, aliased per query). Not for object fields, so
`fragment PersonFields on Person` spread into three queries yields three structurally
identical, mutually incompatible structs — a helper written against one won't typecheck
against the others. This is the property that decides whether checked-in codegen scales
past a dozen queries, and 80% of the machinery exists (`lone_shared_spread`,
`generate_unions`, `shared_artifacts`, `derive_module`). genqlient reached the same
answer via its `flatten` directive. *Effort: M, mostly test surface.*

**F14 — A pagination helper.** The most-requested thing nobody in the "typed structs, no
normalized cache" tier has shipped:
[genqlient #357](https://github.com/Khan/genqlient/issues/357) (open since 2024-10,
maintainer agrees, no design), graphql-codegen #5212 (24 reactions), Apollo Kotlin #3807.
Real code hand-rolls it every time — and writes **two near-identical queries** differing
only by `after: $cursor`, which graph_weaver already makes unnecessary (a nil variable
is omitted from the wire).

The structural advantage is real: the genqlient requester named the blocker as "the
field name varies per query" — exactly what a *query-driven* generator knows at build
time. Detect `pageInfo { hasNextPage endCursor }` plus a nullable cursor variable and
emit `each_page`/`each_node` returning a lazy `Enumerator` — a shape Ruby has and Go
argued about for two years.

**The warning, stated plainly:** three ecosystems examined this and declined —
ariadne-codegen closed [#383](https://github.com/mirumee/ariadne-codegen/issues/383) as
"tricky to implement in a way that fits all use cases", and Apollo Kotlin *deleted* its
pagination codegen (PR #6735). Their stated reasons (arbitrary field paths, forward vs
backward, nested connections, `nodes` shorthand vs `edges { node }`) are not obviously
wrong. "Nobody built it" is weaker evidence of opportunity than it looks. This is also
the first feature that turns a generated module into a mini-runtime orchestrating several
requests — defensible, still query-driven, but a real line to cross. Gate behind opt-in.
**Cheap prerequisite worth doing regardless:** a `docs/pagination.md` noting that one
query with a nullable `$cursor` suffices. *Effort: M–H, heuristic-heavy.*

**F15 — Query documents validated against a refreshed schema.** Given a new schema,
report which checked-in operations no longer validate. `Codegen#generate` already calls
`@schema.validate(@query)` and builds per-error detail; the re-introspection machinery
already exists for `graph_weaver:schema:verify`. Add a `graph_weaver:schema:check` task
reporting instead of raising.

Why this is more interesting than it sounds: **it answers a question Apollo's paid tier
structurally cannot.** [GraphOS operations checks](https://www.apollographql.com/docs/graphos/platform/schema-management/checks)
run against *historical usage metrics* — a 7-day window, a 10,000 distinct-operation cap,
requiring a metrics pipeline — so they answer "did anyone *use* this field lately", not
"does my repository still compile". `graphql-inspector validate` is the only
document-driven tool and it's JS. graphql-ruby's own docs point users at
`GraphQL::StaticValidation` and tell them to write the rake task themselves.
*Effort: ~1 day. Best value-per-hour on this list.*

**F16 — `@semanticNonNull`.** Nullability fatigue is a theme in *every* ecosystem
(six of graphql-codegen's top-20 issues). It's measurable in this repo's own showcase:
`examples/rick_and_morty.rb` lines 41–55 is a 15-line loop containing **5 `&.`, 2
`.compact`, 1 `.to_a`**. `@semanticNonNull` is a *schema* directive ("null only on
error"), which fits the model exactly — `SchemaLoader` reads it, `object_node` emits
`String` instead of `T.nilable(String)`, `from_h` raises if a null does arrive. Sorbet is
the type system best served by it, because `T.nilable` is *more* intrusive than TS's `?`.
For schemas you don't own, a local override registry
(`GraphWeaver.non_null("Person.email")`) alongside `register_scalar`.
See [Apollo's nullability docs](https://www.apollographql.com/docs/kotlin/advanced/nullability)
and [graphql/nullability-wg](https://github.com/graphql/nullability-wg/discussions/58).
*Effort: M.*

**F17 — Nil-vs-error, the question nobody has answered.** Relay's maintainers state it
best, in [#4416](https://github.com/facebook/relay/issues/4416): *"An ecosystem-wide
tradeoff (ecosystem-wide because no GraphQL client has addressed this before): discard
queries with errors, or not be able to discern whether a null is error or not."*
Nine years, 64 reactions on the original issue.

graph_weaver is **one step away**: `Response#errors_at(path)`/`#report` already carry
path-indexed errors with entity ids. The missing piece is going from a struct instance
back to its path — `from_h` already knows the path as it descends. Start with a
documented `Response#null_because_of_error?(path)` helper; even the string-based version,
*named and documented*, is ahead of the field. *Effort: M for the honest version.*

**F18 — Persisted-query manifest.** graph_weaver knows every operation at build time,
which is exactly what makes a manifest possible — and **nothing in Ruby generates one
from client documents** (graphql-ruby's OperationStore is GraphQL-Pro at $1,100/yr and
server-side; the free gem is server-side too). **Design note: three manifest formats have
converged** — Apollo's, Relay's, and graphql-codegen's — and GraphQL Hive accepts all
three, while `rover persisted-queries publish` takes `--manifest-format apollo|relay`.
**Emit one of those; do not invent a fourth.** The APQ runtime half fits the duck-typed
slot exactly as `Retry` does — a client wrapping a client, `lib/graph_weaver/persisted.rb`
beside `retry.rb`. Note APQ grants **zero** safelisting (Apollo files it under
*performance*); safelisting requires `apq: {enabled: false}`. *Effort: M.*

**F19 — `graphql.config.yml` in the docs.** Five lines of YAML, zero gem code:

```yaml
schema: app/graphql/schema.json
documents: app/graphql/queries/**/*.graphql
```

[vscode-graphql](https://marketplace.visualstudio.com/items?itemName=GraphQL.vscode-graphql)
(2.8M installs) **requires** a graphql-config file; the JetBrains plugin (6.1M downloads)
reads the same one; graphql-config supports introspection JSON directly. This buys
validation-as-you-type, field/argument autocomplete, go-to-definition into the schema and
hover docs — for a Ruby repo, with no JS project. It also makes `graphql-inspector
validate` and `@graphql-eslint` available over the same globs in CI. Ruby developers
simply don't know this works. *Effort: an hour. Best value-per-line in this document.*

**F20 — Per-operation codegen knobs.** Every graph_weaver knob is schema-wide (global or
client-scoped); there is no per-query escape hatch at all. genqlient's `# @genqlient`
directives are the model — and most of them graph_weaver already has or doesn't need
(`bind` ≈ `register_scalar`, better; `for` ≈ the `Type.field` coordinate; `omitempty`/
`pointer` are Go nil workarounds). Genuinely missing: **`typename`** (name the generated
type for a field) and **`alias`** (a Ruby prop name *without* a GraphQL alias that changes
the wire query). `examples/github/generated/stargazers_query.rb` is six levels deep with
two distinct structs both wanting to be `Repository`; today the only rename lever changes
what you send. *Effort: M. Papercut relief, not new capability.*

**F21 — Smaller items.** A `rake graph_weaver:init URL=… AUTH=…` (the only manual step in
an otherwise copy-paste setup is "open a Rails console and run
`GraphWeaver.new(url, cache: true).schema`"). A shipped CLI (`bin/generate` is fixture
tooling — long-standing PLAN item). Parse/execute memoization (~3× cost re-generating per
call — PLAN item). Shared input structs across modules (one Hasura `bool_exp` drags ~28k
lines into *every* module — PLAN item). Structured logging payload
(`{event:, url:, ms:}` + a scrub hook — PLAN item). An unused-selection lint
(`rake graph_weaver:unused`) — with checked-in structs and Sorbet, "this prop is never
read" is statically answerable in Ruby in a way it isn't in most ecosystems, recovering
the one real benefit graphql-client's data masking bought without its runtime error.

---

## 5. Competitive position

*All external figures checked 2026-09-05.*

**The core claim holds.** No maintained Ruby gem offers per-query static types. Three
independent checks agree: graphql-client's
[Tapioca compiler PR #7](https://github.com/github-community-projects/graphql-client/pull/7)
has been stalled since 2024-11 *and* targets schema-wide RBIs rather than per-operation
result shapes anyway; a GitHub search for Ruby + GraphQL + Sorbet returns exactly two
repos; the other, `yogurt`, last released 2020-11-26 at 3 stars. State it with the
caveat that makes it honest: **this idea was tried once and died** — though yogurt's own
README concedes it lacked named fragments and that the author "probably got a lot of the
decisions wrong", so it isn't a clean verdict on the thesis.

**The market read is the most important correction this review produced.**
graphql-client's 94.2M downloads looks like an entrenched incumbent. It isn't:

- **Shopify removed it.** Gemspec diff, v9.5.1 vs current `main`: v9.5.1 declared
  `graphql-client`; current declares `httparty`, `oj`, `sorbet-runtime` — and no
  `graphql` or `graphql-client` at all.
  [BREAKING_CHANGES_FOR_V10.md](https://github.com/Shopify/shopify-api-ruby/blob/main/BREAKING_CHANGES_FOR_V10.md)
  names the reason: *"There is no need to dump the schema to a local JSON file before
  using it anymore."* The schema-dump requirement — graphql-client's whole validation
  model — was a stated motivation for leaving.
- **A CI bot is a large share of what remains.** `gitlab-triage` alone is 24.1M downloads,
  reinstalled every pipeline run. graphlient's 32.3M is a wrapper, not an independent
  choice.
- **Deliberate adoption today:** graphlient ~1,894/day, artemis ~173/day.

So the frame is **not "a big market with a weak incumbent"** but **"a small, quiet market
where nobody is defending the position"** — 136 Stack Overflow questions tagged
`graphql-ruby` against 20,775 for `graphql` (~0.65%), and zero Reddit or HN threads
discussing Ruby GraphQL client choice. Sentiment isn't negative; the topic doesn't
register.

**Strategic implication:** favour cheap, high-leverage moves over long builds. Winning an
undefended position is mostly a distribution problem, and the payoff for a six-month
feature programme is capped by a demand ceiling no feature will lift. F19 (an hour), F15
(a day), the doc fixes in §3, F4 (an hour) — then spend the reclaimed time on a
comparison page and a post aimed at Sorbet shops.

**The best pitch line available:** Shopify's current SDK depends on `sorbet-runtime` and
still returns GraphQL responses as `Hash{String, Untyped}`. A Sorbet shop, shipping a
Sorbet-typed SDK, with untyped GraphQL — the gap drawn by the biggest vendor in the space.

### Where graph_weaver wins
Per-query static types (uncontested). Custom scalar deserialization — graphql-client has
[an open issue](https://github.com/github-community-projects/graphql-client/issues/17)
since 2024-02 whose workaround is monkey-patching `GraphQL::Schema::BUILT_IN_TYPES`, posted
with a 🤢. Federation (graphql-client has an open
[federated-router crash](https://github.com/github-community-projects/graphql-client/issues/78)).
The error model — graphql-client currently carries
[#67 "Network errors are discarded"](https://github.com/github-community-projects/graphql-client/issues/67)
(a 403 surfacing as `KeyError: key not found: "data"`) and
[#75 "Errors not populating correctly"](https://github.com/github-community-projects/graphql-client/issues/75).
Fragments for plain reuse — graphql-client forces Relay-style data masking and users file
[#76](https://github.com/github-community-projects/graphql-client/issues/76) asking to
escape it. Testing. And `verify_generated!`, which genqlient — its closest peer — lacks.

### Where a competitor is better
**Institutional safety**: graphql-client is GitHub's with a decade of production use, and
"no static types" is a cost many teams accept over "4 stars, one author, two months old".
**graphlient is quietly the healthiest Ruby client** — 0.9.0 shipped 2026-08-02, more
recent than graphql-client's last release — and for "call this API, don't make me think"
it's the right answer while graph_weaver is over-engineered for the job.
**Concurrency** (F5). **Checklist breadth** — no subscriptions, `@defer`, uploads,
batching, persisted queries.

### The honest weakest point
**Bus factor against surface area.** ~5,500 lines, 844 in `codegen.rb` alone, one author.
Codegen is unforgiving: the v0.4.6 changelog is a list of edge cases where generated code
raised `NameError` at runtime, all caught in a single review sweep. That's healthy
diligence *and* a measure of how much surface there is to get wrong. `verify_generated!`
mitigates drift; nothing mitigates the maintainer.

**Second:** the Sorbet bet has a horizon. Sorbet remains dominant, but the direction of
travel is toward RBS, and Sorbet's own RBS comment support is experimental **and does not
do runtime type checking** — precisely the property generated `sig`s depend on. Fine
near-term; worth keeping the emission format pluggable rather than assuming `sig {}`
forever.

### What the field says graph_weaver already got right
Four of the seven structural problems of this category, all under-advertised:

- **Testing** is under-served *everywhere* — genqlient [#108](https://github.com/Khan/genqlient/issues/108)
  open 5 years (wandb wrote a whole `gqlmock` package themselves), Apollo Kotlin's
  [#6076 MegaIssue: testing utilities](https://github.com/apollographql/apollo-kotlin/issues/6076),
  a gql.tada RFC at 11 reactions, a 22-comment confusion thread at graphql-codegen. The
  mechanism is always identical: generation makes result types *precise*, which makes them
  *expensive to construct by hand*, and nobody ships the fabricator. graph_weaver ships
  the most complete answer of anything surveyed — and it's one README bullet.
- **Schema lifecycle**: genqlient's **#1 open issue by reactions (22)** is
  [remote-schema config](https://github.com/Khan/genqlient/issues/207), whose reporter
  describes hand-building the exact CI job that `cache: true` +
  `rake graph_weaver:schema:refresh`/`:verify` already is.
- **Error handling**: the "wrapper destroys information" failure recurs in every
  ecosystem, and real Ruby and Go code hand-rolls a 40-line error layer that
  `Response` + `#report` + `#to_h` deletes.
- **Determinism**: graphql-codegen has four separate issues about non-deterministic
  output ([#5106](https://github.com/dotansimha/graphql-code-generator/issues/5106),
  14 reactions, and friends). graph_weaver sorts throughout and generation is
  byte-identical across runs — but this is **not stated as a guarantee anywhere**. It
  should be, with a spec asserting it. (Also: `verify_generated!` does exact
  `File.read == source`, so a CRLF checkout reproduces graphql-codegen's
  [#10309](https://github.com/dotansimha/graphql-code-generator/issues/10309) —
  normalize line endings.)

**The competitive story is not "typed structs" — everyone has those. It's "typed structs
*and* you can test them *and* the schema keeps itself honest."**

---

## 6. Performance and maintainability

Measured on Apple Silicon, Ruby 3.4, laptop with other things running; ratios trustworthy,
absolute ms ±10–20%.

**Codegen is linear and a non-issue.** ~9–11 µs per field selection, flat across a 16×
range in width and 13× in depth; fragment spreads likewise linear. Real-world: 0.02s for
the pathological 278-type case in B3. **No O(n²) anywhere.** Any refactor of the AST walk
can be judged purely on readability.

**The hot runtime path is proportionate — and the brief's premise was wrong.**
`from_h` costs ~1.8 µs/struct, linear across three orders of magnitude. Where it goes:

- **58% garbage collection** (sweeping + marking), driven by ~6 objects and 2.3 hashes
  per struct — inherent to `T::Struct` keyword construction.
- **Sorbet sig checking is only ~6%**, not the bottleneck. Disabling runtime sig checks
  entirely saved 6%. The real Sorbet cost is `T::Props`' per-prop setter validation,
  which that flag doesn't govern — and even that is ~0.83 µs of the 1.80. A plain
  `Struct` is 0.29 µs, so **`T::Struct` costs ~0.54 µs/struct over plain — that is the
  price of the product, and it's the right price.**
- **`Date.iso8601` is 25% of `from_h`** on a query with one date per three structs — the
  largest *addressable* slice, and it's a docs fix: `register_scalar` with an explicit
  cheaper `cast:` beats the inferred regexp-based `Date.iso8601`.

End to end over localhost, 600 structs: casting is 81% of 1.32 ms — which says "casting
adds ~1.1 ms of CPU", not "the gem is slow". Against a real 30 ms API call it's ~3%.
**Recommendation: do nothing** for typical queries; it matters only for a 10,000-row
report (55 ms) or a 50,000-row export (284 ms).

**Schema loading is the one Rails number worth knowing.** GitHub's 2.87 MB dump:
`SchemaLoader.load(.json)` **173 ms**; the same schema as SDL **374 ms** (2.2×). A cached
schema is fully re-parsed every boot — the cache saves the round trip, not the parse. But
the production path pays **0 ms**: the railtie only `require`s generated `.rb` files and
`client.schema` is lazy. You pay it in dev consoles and CI `verify_generated!`. Worth
documenting, not worth engineering around.

**Memory is clean** — 2 heap slots retained after 10× a 15,000-struct cast. **Per-request
allocation is 9 objects / 1.1 µs** with nothing to hoist; the `rescue` splat is lazily
evaluated (0 calls on 1000 successes). One real waste — `log_tag` runs a regex over the
whole query whenever a logger merely *exists*, costing +1.32 µs/request at `:info` for a
tag nothing prints — is **0.004% of a 30 ms call and not worth a commit.**

### Maintainability
The decomposition is principled; don't undo it. `nodes.rb` is genuinely good — a new leaf
kind is a new class implementing five methods and `emit.rb` doesn't change.

**Load-bearing complexity, leave alone:** `object_node`'s five-way kind dispatch (all four
abstract-type branches draw names from the same `taken` pool and the ordering between them
is semantic — splitting it turns one readable decision table into four coupled files); the
string-append emitter (you can grep a line of *generated output* and land on the line of
`emit.rb` that produced it — for a code generator that beats elegance); `Emit` reading
eight ivars off the host (all "state of one generation run"; revisit only with a second
emission target).

**Worth doing:**
- **R1 — extract `codegen/aliases.rb`** (~130 lines). The alias subsystem has its own
  vocabulary and touches the rest through exactly one seam (`node.aliases =
  resolve_aliases(node)`). Same extraction already made for scalars and enums, so it's
  consistent rather than novel. *1–2 h, mechanical, spec-covered.*
- **R2 — `build_variables(operation)`** (~25 lines out of `generate`'s 72), leaving
  `generate` reading as a seven-line pipeline. *30 min.*
- **R3 — a `QueryModule` mixin** for the identical ~15-line untyped `@client` plumbing
  repeated in every generated file. Precedent and rationale already in
  `input_struct.rb:11-16`. **Scope limit:** `execute`/`from_response` must stay generated —
  their sigs *are* the product. *~0.5 day; regenerates every fixture.*

**Explicitly churn:** rewriting the emitter as templates/AST; strategy objects for
`object_node`; promoting codegen to `# typed: strict` (CLAUDE.md forbids it and the
measurement backs the policy); splitting `emit.rb` further.

---

## 7. Explicit non-goals

Worth recording as decisions rather than omissions.

- **`@defer`/`@stream`.** The spec ratified a
  [September 2025 edition](https://spec.graphql.org/September2025/) — its first since 2021
  — and incremental delivery **was not in it**; it's on its third or fourth attempt (PRs
  #742 and #1034 closed as superseded, #1110 still Stage 2 Draft after six years). Apollo
  Client 4.1 ships **two mutually incompatible handlers** for two wire formats. And in
  Ruby, `@defer` is GraphQL-Pro only at $1,100/yr, so a Ruby client would rarely meet a
  Ruby server that supports it. Implementing this in 2026 means betting on one of two
  unratified formats. Failing cleanly — which it does — is the right level of support.
- **Subscriptions.** A persistent duplex transport, a different response lifecycle, and an
  execution model a request-scoped Rails process doesn't have. Unchecked on
  graphql-client's 1.0 TODO since 2024 with essentially no user pressure. Rejecting at
  *generation* time, as today, is the best possible failure. Make it a **stated non-goal**
  so it reads as a decision, not an omission.
- **File uploads.** Apollo removed built-in support in Server 3.0 on CSRF grounds
  (`multipart/form-data` POSTs without a preflight); the spec repo has been frozen since
  2025-03.
- **Normalized caching.** Apollo's `InMemoryCache`, urql's Graphcache and Relay's store all
  solve *component-graph consistency* — several components rendering the same entity, a
  mutation updating it, all re-rendering without a refetch. A Ruby backend has no component
  tree, no long-lived client-side store, and usually a request-scoped process. You'd import
  normalization, GC, cache policies and a class of staleness bugs to solve a problem the
  deployment shape doesn't have. `Rails.cache` around `execute` is the right size. *(Marked
  as inference: no authoritative source states this directly.)*
- **Fragment masking.** The evidence is unusually direct: graphql-client **already has it**
  and users file issues asking to escape it. Masking enforces component data-colocation in
  a component UI framework; graph_weaver's callers are services and jobs. graph_weaver's
  shared fragments are the feature graphql-client users are asking *for* — adding masking
  would convert an advantage into their complaint. **The mistake to avoid is being talked
  into it.**
- **Watch mode.** graphql-codegen's watch complaints exist because JS builds are slow and
  the loop is long. graph_weaver generated the pathological case in 0.021s, and
  `client.parse`/`load_queries!` already provide a no-build-step dev mode — the gql.tada
  escape hatch, from inside a codegen tool. Say that in the docs and move on.
- **Batching / multiplex.** Doesn't fit the one-query-per-module design; would need a new
  `Batch` object. Skip unless demand appears.
- **`near-operation-file` layout.** Colocation is a *component-tree* concern that pays in
  React. In Rails, queries live in one directory and the flat layout is correct.
- **Formalizing the client slot as a Sorbet interface.** Already in `CLAUDE.md`; the
  research supports it. A graphql-ruby `Schema` class satisfies the contract without
  inheriting anything, and that's what makes `FakeClient`, `Failure.*`, `Sequence` and
  `Cassette` compose. `Retry` is a client wrapping a client; so should an APQ decorator be.
- **A "replace a composite's deserializer" path**, even though genqlient's `bind` can bind
  composite types. It can because a Go struct's shape is fixed by its type; a composite's
  shape here varies per query, so binding one is correct for exactly one selection.
- **Generating the whole schema.** genql is the cautionary example — artifact size scales
  with schema, not query count; its prebuilt SDKs run to 19.7 MB. Query-driven codegen is
  why a supergraph's `join__*` types emit nothing.

---

## 8. Recommended order

**Tier 1 — correctness, do first.**
B1 (silent corruption) · B4, B5 (federation loader) · B2 (documented behaviour absent) ·
B6, B7 (enums) · B8, B9 (silent no-ops) · B14 (dead spec) · the `docs/testing.md` and
`README.md:84` fixes in §3.

**Tier 2 — the measured wins.**
B3 (5,386 → tens of lines; also largely subsumes F12) · F5 (connection pool, ~4×) ·
F4 (`Accept` + `User-Agent`, an hour; then `operationName`) · F6 (Faraday timeouts — a
missing timeout is an outage) · F7 (`InProcess` wrapper: context, logging, branded errors).

**Tier 3 — cheap leverage, disproportionate payoff.**
F19 (`graphql.config.yml`, an hour) · F15 (`schema:check`, a day) · F3, F10, B15 items ·
the error-message and docs work in §3 · state determinism as a guarantee and normalize
line endings in `verify_generated!` · reposition testing and schema-lifecycle as headline
features rather than single bullets.

**Tier 4 — real projects, decide deliberately.**
F1 (`@link` namespaces) · F13 (object-fragment hoisting) · F2 (`_entities`
representations) · F8/F9 (response metadata, instrumentation) · F16 (`@semanticNonNull`) ·
F17 (nil-vs-error) · F18 (persisted manifest) · F14 (pagination — read its warning first) ·
R1–R3.

---

## 9. Method and provenance

Six parallel Opus agents, each required to prove claims by execution rather than
inspection, working read-only against a green baseline (308 examples) with scratch probes
outside the repo. The tree was verified byte-identical after every agent.

Findings marked **✓verified** were independently re-run by the coordinating session:
B1 (the mis-typed `Pet`), B3 (5,386 lines / 275 vacuous structs — the agent reported 278;
the precise count is 275 vacuous, 2 real, 1 incidental), B4 (the braceless `schema @foo`
reprint), B6 (the enum round-trip `TypeError`), B8, B9, B14, and F5's mutex scope.

Two findings were reached **independently by two agents from opposite directions** — B6
(from reading the emitter; from a live mutation round-trip) and the missing `Accept`
header (from a raw-socket wire capture; from reading both transports). Independent
corroboration raises confidence materially.

Calibration notes worth keeping: the perf agent **disproved the brief's premise** that
Sorbet sig checking dominates casting cost (it's 6%), and recommended *doing nothing* on
the hot path. The federation agent separated defects that Apollo's composition rules make
**unreachable** from ones that hit real users, and confirmed the `@inaccessible` cascade —
the thing most expected to break — is correct. The competitive agent argued **against its
own earlier draft** on market size after checking Shopify's gemspec directly. Reports that
only confirm the hypothesis they were given are worth less than these were.

External figures checked 2026-09-05; every external claim in §5 and §7 carries a citation
in the source reports.
