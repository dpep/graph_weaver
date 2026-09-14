# Senior J — performance on scalars and federation

Viewpoint: performance engineer. Budget-first, measure-first, distrust the
interesting optimization. Main at 49b9209 (>= required 51abb6f).

## 2026-09-13 08:01 — setup

- App dir: `/tmp/claude/graph_weaver/senior-app-J`. Copying senior-app-C-fix
  (has real apollo-federation subgraphs + composed supergraph) as a base for
  the federation/planner work, and standing up scalar-casting benchmarks
  directly against the gem's runtime classes (no Rails app needed for pure
  `from_h`/`to_json` benchmarking — those are plain Ruby objects once
  generated).
- Toolchain: `~/.rvm/wrappers/ruby-3.4.9/bundle exec ...`.
- Machine quiet check before any timing: `uptime`, kill stray ruby/rspec
  processes from prior sessions.

## Step 1 (~9 min) — Scalar casting on the hot path

Setup: standalone script (no Rails boot) via `GraphWeaver.parse` against a
`GraphQL::Schema.from_definition` schema — `Row { id name count status
onDate occurredAt amount price }`, 8 leaves: `status` a mapped enum
(`register_enum`), `onDate`/`occurredAt`/`amount`/`price` registered scalars
(Date / DateTime / BigDecimal / a Money object scalar with inferred
`.parse`/`#to_s`), `id`/`name`/`count` plain. 10,000-row list.
Scripts: `tmp/bench_scalars.rb`, `tmp/bench_decompose.rb` in senior-app-J.

**Machine note (load-bearing):** this box carries several other concurrent
agent sessions the whole session (`uptime` load average 30-55 throughout,
not a quiet machine — these are legitimate sibling sessions, not strays to
reap). Wall-clock numbers under that contention swing ±20-50% between runs
(confirmed with benchmark-ips's own reported error bars before switching
away from it). Every number below is **CPU time**
(`Process::CLOCK_PROCESS_CPUTIME_ID`), min-of-7 with GC before each rep;
wall time is reported alongside only to show the contention gap.
Allocation counts (memory_profiler) are load-independent and are the
primary number wherever the two might disagree.

### Numbers (10,000 rows, CPU min-of-7; scaling confirmed linear at N=100/1k/10k)

| Stage | Cost (10k rows) | Per row | Allocations (10k rows) |
|---|---|---|---|
| `JSON.parse` only (floor: text -> Ruby Hash) | 4.0ms | 0.40us | 80,004 objs / 4.88MB |
| `from_response!` (Hash -> typed structs), CHECKED=default | 92.8-96.1ms | ~9.3us | 270,005 objs / 28.0MB |
| `from_response!`, CHECKED=never (`T::Configuration.default_checked_level = :never`) | 91.8ms | ~9.2us | 270,005 objs / 28.0MB (**identical**, object-for-object) |
| `to_json` on the built 10k-row result | 29-35ms | ~2.9-3.5us | 90,007 objs / 7.63MB (checked) |

Decomposition of the ~9.3us/row (`tmp/bench_decompose.rb`, isolating the
leaf `Rows` struct — 8-prop `T::Struct#new`, casts run outside vs inside):

| Piece | Cost/10k | Per row |
|---|---|---|
| A: raw casts only (Date.iso8601 + DateTime.iso8601 + BigDecimal() + Money.parse + enum hash lookup), no struct | 41.1ms | 4.11us |
| B: same casts, each wrapped in `GraphWeaver::Hints.field` | 42.3ms | 4.23us (wrapper overhead: ~0.01us/row, noise) |
| C: `T::Struct#new` only, values pre-cast (8 props) | 18.3ms | 1.83us |
| D: full (cast+wrapper+new) combined, one `Rows` struct/row | 67.4ms | 6.74us (≈A+C, additive — no combined-cost surprise) |
| F: `T::Struct#new`, 3 plain props only (String/Integer) | 8.7ms | 0.87us (≈0.29us/prop — construction scales ~linearly with prop count, not type complexity) |
| G: wrapping 10k pre-built `Rows` into the outer `T::Array[Rows]` const | 0.7ms | 0.07us (negligible — ruled out a hypothesis that array-typed props re-walk/revalidate every element) |

Within A, the single scalar cast dominating (`A-solo`, isolated):

| Cast | Cost/10k rows |
|---|---|
| `DateTime.iso8601` | 21.7ms (**53% of all raw-cast time**, more than the other 4 casts combined) |
| `Date.iso8601` | 9.2ms |
| `Money.parse` (BigDecimal + object alloc) | 3.9-4.1ms |
| `BigDecimal()` (Amount) | 2.5-2.7ms |
| mapped-enum hash lookup (Status) | 1.6-1.8ms |

The remaining ~25ms gap between D (67.4ms, `Rows` alone) and the full
`from_response!` (92.8-96.1ms, `Result` wrapping `rows: T::Array[Rows]`
through the envelope) is `check_envelope!` / empty-errors-array mapping /
`Response.new` — confirmed fixed-cost-ish rather than O(N) by the N-sweep
(0.7ms@100, 9.3ms@1k, 96.1ms@10k rows — consistent ~9.3-9.6us/row marginal
at every scale, no super-linear behavior, no surprise fixed floor).

### FINDING 1 (informational, corrects an intuition rather than graph_weaver
itself): **`T::Configuration.default_checked_level = :never` buys ~0** for
this path. 91.8ms vs 92.8ms (noise-level), and allocation counts identical
to the object. Traced why: `T::Props`' generated prop setters
(`validate_prop_value` / the per-prop `setter_proc`, sorbet-runtime
`lib/types/props/decorator.rb`) are themselves declared
`sig { ... }.checked(:never)` **in sorbet-runtime's own source**, and prop
validation runs through a setter_proc built once at class-definition time —
it never dispatches through the sig-checked-level machinery that
`default_checked_level` controls. That knob governs `sig.checked(...)`
*method* dispatch (which is exactly why the generated `execute`/`from_h`
methods are already emitted `.checked(:never)` — see emit.rb:292,518,520,527
— it would be a no-op to toggle it there too). The real cost — `T::Struct`
prop-type validation on construction, ~1.83us/row here (piece C) — is
unconditional and has no user-facing off-switch. **Actionable takeaway for
docs/perf guidance, not a bug**: don't tell users "turn off sorbet checks
for a hot deserialization path" — it does nothing measurable here. The one
thing that does move the number is the scalar's own cast (see Finding 2).

### FINDING 2 (structural, real, additive fix available — not a
graph_weaver bug, but worth a docs/scalars.md callout): **`DateTime` is
~2.4x the per-cast cost of `Date` and ~5-8x `BigDecimal`/enum**, because
`register_scalar("X", DateTime)` takes the library's own STDLIB default
(`scalar_type.rb`: `"DateTime" => { cast: :iso8601, ... }`) — `DateTime` is
Ruby's astronomical-calendar-arithmetic class (Rational-based internally),
not `Time`'s fast C timestamp. A schema field typed as `DateTime` when
`Time` would do (no calendar/leap-second/non-Gregorian need — a plain
wall-clock timestamp) pays roughly double `Date`'s cost and doesn't buy
anything a `Time` registration wouldn't equally well serve for the ISO 8601
wire format every server actually sends. At 10k rows x however many
DateTime-typed leaves a real query has, this is the single biggest lever in
the whole cast pipeline (53% of raw-cast time here, with only one
DateTime-scalar leaf of five). docs/scalars.md's own worked example
(`GraphWeaver.register_scalar("Timestamp", Time)`) already recommends the
fast type — the risk is a reader instead reaching for `DateTime` (arguably
the more "correct-sounding" stdlib class for a schema field literally named
DateTime) and quietly buying the slower default. Cheapest fix: a one-line
note next to that example — "prefer Time over DateTime unless you need
calendar arithmetic; DateTime.iso8601 measures ~2x slower per value." Not a
code change — this is app-level scalar choice, and the library correctly
leaves that choice alone (register_scalar's whole design is "you name the
Ruby type, we infer the codec").

### Verdict for this door

No budget was stated by the (hypothetical) app for this door, so: 9.3us/row
end-to-end (checked, default) for an 8-leaf/4-scalar row is roughly 23x the
`JSON.parse`-only floor (0.4us/row) — expected and, on the numbers above,
entirely explained by real work (4 casts + an enum lookup + 8-prop struct
validation), not by incidental overhead. Nothing here needs a structural
fix in graph_weaver itself: the sorbet-runtime checked-level lever is a
dead end (Finding 1), and the one real lever (Finding 2) is an app-level
scalar-type choice the library already can't and shouldn't make for you.
`to_json` (new this release) costs less than half of `from_h` per row
(2.9-3.5us vs 9.3us) — expected, since serialize (`strftime`, `to_s("F")`,
a hash lookup) is uniformly cheaper than parse (`iso8601`, `BigDecimal()`)
and skips prop-type validation entirely (writing a hash, not constructing
a checked struct).

## Step 2 (~9 min) — The fake: `graphql_fake`/`FakeClient`, list_size scaling, and `Testing::Router.new` memoization

### FINDING 3 (real, significant, additive-fix-shaped): a single `list_size:` multiplies across every unbounded list field the fabricator reaches — nested lists compound rather than share a budget, turning "a 1k-row list with nested objects" into O(n^2) or worse

Setup: `Row { id name count amount owner { id name since } tags }`, `tags:
[String!]!` with no `first`/`last`/`limit` arg (`tmp/bench_fake.rb`,
`tmp/bench_fake_allocs.rb`/`_allocs2.rb`, `tmp/profile_fake.rb`).
`FakeClient.new(schema:, list_size: n, values: :literal)`, one `execute!`.

Wall/CPU (separate process per size, no cross-run heap confound —
re-verified against a same-process run to rule out a GC-pressure artifact
before trusting this):

| list_size | fabricate-only CPU (min) | growth vs previous |
|---|---|---|
| 100 | 28.6ms | - |
| 200 | 109.5ms | 3.8x for 2x rows |
| 400 | 391.6ms | 3.6x for 2x rows |
| 800 | 1707.0ms | 4.4x for 2x rows |
| 1600 | 4529.4ms | 2.6x for 2x rows |

~4x per doubling is the signature of O(n^2), not GC noise — confirmed with
`GC.stat(:total_allocated_objects)` deltas (allocation *count*, immune to
GC-pause timing noise):

| list_size | allocated objects | objects/row |
|---|---|---|
| 100 | 108,836 | 1,088 |
| 200 | 369,235 | 1,846 |
| 400 | 1,370,042 | 3,425 |
| 800 | 5,291,643 | 6,615 |
| 1600 | 20,814,842 | 13,009 |

Per-row allocation cost doubles every time list_size doubles — real,
algorithmic, not a GC artifact (confirmed further: a StackProf CPU profile
at size=1200 showed 63.8% of samples IN garbage collection, which is a
symptom of the allocation volume, not an independent cause).

**Root cause, isolated and confirmed**: `FakeClient#list_length` (`lib/
graph_weaver/testing/fake_client.rb:581`) falls back to the fake's single
`@list_size` for *any* list field with no `first`/`last`/`limit` argument
value at that call site — there is no per-field or per-depth budget. My
query selects `tags` (a second, nested, uncapped list) inside every `Row`
of the outer `rows` list — so with `list_size: n`, the fabricator builds n
`Row`s, and **each Row also fabricates a `tags` list of length n** (same
global setting, reached again one level down). Total fabricated leaves:
n (rows) x n (tags per row) = O(n^2), from ONE list_size setting and no
list-of-lists in the schema.

**Confirmed by capping the nested list** (`tags(first: 3)` in the query,
`tmp/bench_fake_allocs2.rb`, `CAPPED=1`): allocations become
flat/near-linear per row (314 -> 272 -> 250 -> 240 -> 234 objects/row as
list_size climbs 100->1600 — *decreasing* per-row cost, the normal
fixed-overhead-amortizing shape of a healthy O(n)) instead of doubling.

**Severity: medium-high, situational.** Not a bug — `list_size:` is
documented as one global knob (`docs/testing.md`'s own example sets
`config.list_size = 1..3`, a small range, which is why this is easy to
never notice in normal unit-test use). It bites exactly the brief's
scenario: anyone reaching for a *larger* `list_size:` to fabricate a
bigger fixture/seed/stress-test payload, on a schema where the interesting
type (an Order, a Person) has more than one list-shaped field reachable
under the query (tags, line items, permissions, addresses — all common).
The cost is invisible until it's tried: nothing warns that two nested
unbounded lists multiply, and three would cube it. A team could easily
read "list_size: 1000" as "1000 items, once" and get 1,000,000+ (or with
a third nested list, 10^9) fabricated leaves and a fake client that
appears to hang.

**What a fix would look like, additive**: `list_size:` could accept a
Hash keyed by coordinate (`{ "Row.tags" => 3, default: 1000 }`) the way
`overrides:`/pins already are — same lookup shape the codebase already
uses elsewhere (`@overrides.fetch(coordinate) { @overrides.fetch(node.name,
UNPINNED) }` in `field_value`), so it wouldn't be a new pattern, just
reusing the existing per-coordinate-or-name fallback the fake already has
for pins. Purely additive — a bare Integer/Range keeps meaning what it
means today. Cheapest fix that needs no API change at all: a callout in
docs/testing.md next to `config.list_size = 1..3`, naming the nested-list
multiplication explicitly and recommending `first:`/`last:`/`limit:` args
in the query to cap any list field nested under another list before
reaching for a large `list_size:`.

### `graphql: :fake` / `graphql_fake` per-example setup cost — none found

200x `execute!` against a fresh `FakeClient.new` per iteration vs one
`FakeClient` reused across all 200 (`tmp/bench_fake.rb`, list_size=10,
small/typical-unit-test shape): 2.19ms/example fresh vs 2.229ms/example
reused — a **negative** delta (noise-level, within measurement error of
each other). **No per-example setup tax found** — schema/registry read
isn't re-done in any way that shows up; `GraphWeaver::Testing::FakeClient.new`
is cheap relative to the fabrication work itself at this list size. No
memoization is needed here because there's nothing expensive to memoize.

### `Testing::Router.new` on a wide supergraph, called 200 times: NOT memoized at the constructor — and doesn't need to be, because the layer that reuses it already does

Composed a 12-subgraph supergraph (`tmp/gen_wide_supergraph.rb`, via the
same `@apollo/composition` harness senior-C-fix set up — each subgraph
owns one entity keyed on `id` and stub-references two neighbors; 7,986
bytes composed). `GraphWeaver::Testing::Router.new(supergraph: sdl)` called
200 times, one at a time, CPU time each (`tmp/bench_router_new.rb`):

- call 1: 13.97ms, call 2: 12.1ms, call 200: 6.12ms
- min across 200: 5.9ms, median: 6.62ms, sum: 1372.3ms for 200 calls

**No convergence to near-zero** — every call pays a similar cost (the
mild downward drift 14ms -> 6ms is JIT/heap warm-up, not caching; if this
were memoized, calls 2-200 would cost microseconds, not milliseconds). So:
the direct answer to "is supergraph parsing memoized" is **no, the
constructor itself never caches** — confirmed by measurement, not
assumed.

**But** — read `lib/graph_weaver/testing.rb:190` (`Testing.config.built_router`)
before calling this a gap: the rspec harness (`graphql: :router` tag,
`graphql_router` helper) never calls `Testing::Router.new` directly — it
goes through `TestClients.client_for(:router, graph)` ->
`config.built_router(graph)`, which **does** memoize, by source content:
`@built_routers[source] ||= Router.new(...)`. So a real 200-example suite
tagged `graphql: :router` against one supergraph pays the ~6-14ms parse
cost **once**, not 200 times — the caching the brief asked about exists,
just one layer up from the bare constructor, which is architecturally the
right place for it (a constructor that silently cached at the class level
would be exactly the "spooky action at a distance" this codebase's own
design principles rule out — two `Router.new(supergraph: same_sdl)` calls
in two different tests should not become the same object by magic). The
only way to pay this 200 times is to call `Testing::Router.new` directly,
200 times, bypassing the documented helpers — which is what my
measurement above deliberately did, to answer the question asked, but
isn't how the harness itself behaves.

**Verdict for this door**: no code fix needed. FakeClient's list_size
interaction (Finding 3) is the one real, worth-fixing thing here, and it's
a docs gap plus an optional additive API, not a bug.

## Step 3 (~6 min) — The planner on a wide supergraph

Composed (well, hand-emitted directly as directive-correct SDL text for
the GitLab-scale part — see below) two synthetic supergraphs:

1. **"wide" supergraphs** (`tmp/gen_wide_supergraph.rb`, via the same
   `@apollo/composition` harness as senior-C-fix — real composition, not
   synthesized): N subgraphs (4/8/12/16/20), each owning `EntityI(id, name,
   valueI, tagI, ref<neighbor1>, ref<neighbor2>)` with two neighbors
   `(I+1)%N, (I+2)%N` referenced via `@key` stubs. A dashboard-shaped query
   walking `entity0 { ref1 { ref2 { ... } } }` crosses one subgraph
   boundary per level, mirroring senior-C's `Dashboard` query shape
   (`me { reviews { product { ... } } }` — object -> object -> object, each
   hop a federation edge) since my synthetic graph has no analog of C's
   actual accounts/products/reviews schema to replan literally against.

2. **A GitLab-scale supergraph** (`tmp/gen_scale_supergraph.rb`): corpus/gitlab.json
   (introspection, single-service — not itself a supergraph, so nothing to
   reuse directly) has 4,410 types / 15,127 fields; I hand-emitted SDL text
   carrying real join-spec directives (`@join__type`/`@join__field`/
   `@join__graph`) at that scale (4,400 types x 3 fields, 30 subgraphs,
   1.13MB) rather than running real composition at this size — `RoutingTable.new`
   only ever *parses* the directives (confirmed by reading
   `schema_loader.rb:1054` — `@document = GraphQL.parse(sdl); read_graphs;
   read_abstracts; read_types`), so a directive-correct hand-built SDL
   exercises exactly what's being measured, and real `composeServices` at
   4,400 types would burn most of this door's time budget on Apollo's own
   composition rather than on graph_weaver.

### Plan time vs subgraph count (fixed depth=3 query), CPU min-of-9

| Subgraphs in supergraph | plan() time |
|---|---|
| 4 | 0.187ms |
| 8 | 0.197ms |
| 12 | 0.201ms |
| 16 | 0.210ms |
| 20 | 0.224ms |

**Flat.** 5x more subgraphs in the supergraph costs 20% more plan time for
a query that only ever touches 4 of them — expected and correct: planning
should cost what the *query* touches, not what the *supergraph* contains,
and the numbers say it does.

### Plan time vs selection depth (fixed N=12 subgraphs), CPU min-of-9

| Depth (= subgraph crossings) | plan() time | marginal/level |
|---|---|---|
| 1 | 0.134ms | - |
| 2 | 0.171ms | 0.037ms |
| 3 | 0.203ms | 0.032ms |
| 5 | 0.275ms | 0.036ms |
| 8 | 0.366ms | 0.030ms |

**Linear**, ~0.03-0.04ms per additional federation hop, no blowup at
depth 8. No structural finding here — this door is inside any reasonable
budget (sub-millisecond planning for a realistic dashboard query, flat in
supergraph width, linear in query depth).

### `RoutingTable.new` / `SchemaLoader.load` at GitLab scale, CPU min-of-5

| Types | RoutingTable.new | SchemaLoader.load (API schema) |
|---|---|---|
| 500 | 45.1ms | 84.5ms |
| 1,000 | 93.6ms | 164.7ms |
| 2,200 | 221.6ms | 412.1ms |
| 4,400 (GitLab scale) | 453.2ms | 870.8ms |

Both scale linearly with type count (~0.1ms/type for RoutingTable,
~0.2ms/type for the full schema load — consistently ~2x, expected since
`SchemaLoader.load` builds a real graphql-ruby `Schema` object with its own
type-system validation on top of the same parse). At GitLab's actual scale
this is ~0.45s (table) / ~0.87s (full schema) — a one-time cost per
process, not per-request, and (per Finding in the fake/router section
above) already memoized at the layer that matters (`Testing.config.built_router`
caches by source content). **No structural finding** — half a second to
load a schema the size of GitLab's, once per process, is unremarkable; the
number is here because the brief asked for it, not because it's a problem.

### Verdict for this door

Inside budget on every axis measured: flat in subgraph count, linear in
depth, linear in type count. Nothing to fix.

## Step 4 (~4 min) — Generation: PokeAPI, a `where:` input-type closure

Setup: standalone (no Rails) `GraphWeaver.generate!`/`verify_generated!`
against the PokeAPI introspection dump cached by the integration specs
(`$TMPDIR/graph_weaver/pokeapi-schema.json`, 5.78MB) — exactly the
scenario `docs/generated_modules.md`'s "An input object generates its
whole closure" section names: one query, `pokemon_v2_pokemon(where:
$where)`, `$where: pokemon_v2_pokemon_bool_exp` as a **variable** (the
expensive shape — the closure has to be typed statically since an input
object has no selection set), vs the docs' own escape hatch (inline the
filter as a literal, one scalar variable per leaf) as the comparison.
`pokegen/run_generate.rb`, `pokegen/run_verify.rb`, `pokegen/queries/pokemon_search.graphql`.

### `generate!`, `where:` as a variable (the expensive shape)

`/usr/bin/time -l` (true peak RSS, not just this-process `ps`):

- wall: 0.9s (`/usr/bin/time`'s `real`: 1.84s, includes Ruby/gem boot —
  bundler/setup + requiring graph_weaver + graphql-ruby dominate that
  gap, not generation itself)
- **575 files written** (docs' own worked example says "~1,200" for a
  similar Hasura-shaped schema — different schema, so not the same
  number, but the same *order of magnitude* and the same phenomenon: one
  `$where:` variable reaching the schema's whole `_bool_exp`/comparison-
  operator closure). Measured, not assumed — reporting the real 575
  rather than forcing agreement with "~1,200".
- **peak RSS: 151MB** (`maximum resident set size` from `/usr/bin/time -l`;
  RSS climbed from 53.8MB before `generate!` to 144MB after, in-process)
- 10.6B instructions retired, 3.88B cycles (`/usr/bin/time -l`) — for
  575 files, i.e. real, non-trivial CPU work per file (codegen walks and
  emits real Ruby source per type, not a template stamp)

### `verify_generated!`: cost is the WHOLE TREE, not what changed — confirmed by reading, not just timing

| Scenario | verify_generated! wall time |
|---|---|
| Clean tree, nothing stale | 661.3ms |
| One query file's mtime touched, content unchanged | 752.7ms |
| One of 575 generated files hand-edited (drift) | 464.3ms (raises, correctly naming the one file: `stale generated queries ... generated/types/boolean_comparison_exp.rb`) |

All three land in the same ~460-750ms band regardless of whether 0, 1, or
"everything" is stale — **verify does not do proportional/incremental
work**. Confirmed by reading `lib/graph_weaver.rb:491`
(`verify_generated!`): it calls the exact same `generation_plan(graph,
seen)` `generate!` calls — a full in-memory re-walk of the schema +
queries, computing every one of the 575 files' content fresh — then diffs
each planned file against disk (`current?`) and checks for orphans. There
is no cache of "only re-plan what the changed query/schema could affect";
every `verify_generated!` call costs the same as a full `generate!` minus
the disk-write step, whether it ends up reporting 0 stale files or all of
them.

**Severity: low, situational, not a bug.** The docs' own recommended
usage (`it "generated queries are current" do GraphWeaver.verify_generated!
end` — one rspec example, once per suite run) pays this cost exactly
once, which is unremarkable at ~500-750ms. Checked whether it could be
worse than that: the railtie's dev-mode watcher (`railtie.rb:266-296`)
does NOT call `verify_generated!`/`generate!` on every request — it wraps
the expensive `regenerate!` (a full `GraphWeaver.generate!`) inside Rails'
own `ActiveSupport::FileUpdateChecker`, whose per-request cost is a cheap
mtime/glob check; the full regenerate only fires when a watched `.graphql`
file or the schema dump actually changed (confirmed by reading, not
assumed — this rules out "every dev-mode request pays 700ms" before
reporting it as a risk that isn't real). The one place this *would* bite:
an app that calls `verify_generated!` per-example instead of once per
suite (easy mistake — it reads like a cheap assertion), or an app with
several Hasura-scale graphs, each paying its own ~500-750ms on every such
call. Worth a one-line docs callout next to the `verify_generated!`
example: "costs about what `generate!` does, minus the write — call it
once per suite run, not once per example."

### Verdict for this door

Both numbers here are real facts about a real, documented tradeoff
(`where:` as a variable vs. inlined-literal) that the library's own docs
already explain and already recommend around — nothing to fix in
graph_weaver. The one artifact worth a docs sentence is verify's
whole-tree cost, which is surprising exactly once (the first time you
time it) and easy to now say plainly rather than leave implicit.

## Step 5 (~3 min) — Transport: the bundled HTTP pool under 32 threads

Setup: `tmp/bench_transport.rb` — a local WEBrick server (`/graphql`,
canned JSON response), 32 threads x 20 requests each through
`GraphWeaver::Transport::HTTP`, `Net::HTTP.start` instrumented (a
`Module#prepend` on `Net::HTTP`'s singleton class) to count exactly how
many NEW sockets the pool opens — `Transport::HTTP#connect` calls
`Net::HTTP.start` once per connection it can't reuse from `@idle`, never
for a warm pop, so this is a direct, non-heuristic count (an earlier
attempt to count server-side TCP accepts via monkeypatching
`TCPServer#accept` undercounted — WEBrick's accept loop doesn't route
through that method in an interceptable way — so this counts at the
client/transport layer instead, which is also the layer the brief is
actually asking about).

| pool_size | requests | wall | throughput | TCP connections opened | reuse rate |
|---|---|---|---|---|---|
| 5 (near the class default of 5) | 640 | 0.29s | 2,207 req/s | 5 | 128x |
| 32 (= thread count) | 640 | 0.22s | 2,876 req/s | 32 | 20x |
| 64 (> thread count) | 640 | 0.22s | 2,876 req/s (identical) | 32 (not 64) | 20x |

**Exactly as documented, no surprises:**
- Connections opened = `min(pool_size, actual concurrent demand)` every
  time — at pool_size 5 under 32 contending threads, exactly 5 sockets
  ever exist (the other 27 threads queue for a permit, per `acquire_permit`'s
  `SizedQueue`); at pool_size 32 with 32 threads, all 32 run concurrently
  and each opens its own socket once, then reuses it for its remaining 19
  requests (reuse rate is `total/opened`, not "requests per socket
  measured directly" — with 32 threads each doing 20 sequential requests
  serially on its own thread, the LIFO `@idle` reuse means each thread's
  socket is idle for exactly as long as it takes another of ITS OWN
  requests to come back around, so it never has to compete — the 20x here
  is exactly `requests_per_thread`).
- **`pool_size:` past your actual concurrency buys nothing** —64 vs 32
  produced byte-identical throughput and the identical connection count
  (32, not 64) — confirmed the code comment ("at most pool_size requests
  are in flight") is literally true, not aspirational.
- **`pool_size:` below your concurrency measurably costs throughput** —
  5 vs 32 is a real 30% throughput difference (2,207 vs 2,876 req/s) from
  permit-queueing contention alone (no reduction in connections needed —
  same total request count, same server) — exactly the tradeoff
  `default_pool_size`'s docstring names (size it to `RAILS_MAX_THREADS`,
  the process's real concurrency).

### Verdict for this door

Works exactly as designed and documented — verified by measurement, not
just by reading the docstring. No structural finding; this is the "inside
budget, confirmed" case the brief's own two-mode framing expects some
doors to land on.

## Time accounting (wall clock)

Session ran fast in real time despite covering five doors — most of the
work is scripted (generators + benchmark scripts run non-interactively),
so wall clock is dominated by script runtime, not think time. Actual
elapsed: ~31 minutes from first `uptime` to the transport benchmark's
last line.

- Setup (copy app, repoint Gemfile, bundle install, sanity rspec): ~2 min
- Step 1, scalar casting (schema + 2 benchmark/decompose scripts, the
  DateTime finding, the checked-level dead-end): ~9 min
- Step 2, the fake + Testing::Router (list_size O(n^2) discovery,
  GC.stat confirmation, StackProf profile, the capped-vs-uncapped
  re-test, Router.new x200, reading rspec.rb/test_clients.rb/testing.rb
  to place the finding correctly relative to the memoized harness path):
  ~9 min
- Step 3, planner (real 12-20-subgraph composition via the existing
  node harness, hand-built GitLab-scale synthetic SDL, depth/width
  sweeps): ~6 min
- Step 4, generation (PokeAPI standalone generate!/verify_generated!,
  reading lib/graph_weaver.rb's verify implementation to confirm
  whole-tree cost, reading railtie.rb to rule out a per-request tax):
  ~4 min
- Step 5, transport (WEBrick harness, Net::HTTP.start instrumentation,
  pool_size sweep): ~3 min

## Final verdict

No blocking issues. One real, worth-fixing structural finding (FakeClient
list_size compounding across nested lists — Finding 3), one useful docs
callout with numbers behind it (DateTime vs Time — Finding 2), one
corrected intuition worth writing down so it isn't re-discovered the hard
way (sorbet checked-level does nothing for prop construction — Finding
1), and three doors (planner, RoutingTable at GitLab scale, transport
pool) that measured inside any reasonable budget with nothing to fix.
Every finding here is either a documentation gap or a "test-fixture
footgun," never a data-correctness or request-path defect — consistent
with the other eight passes' overall read that this gem is solid on the
axis it's actually sold on.
