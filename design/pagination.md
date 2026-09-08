# Pagination — goals, measurements, and a proposal

Status: proposal, not built. Targets 0.6.0.

## The problem

Iterating every page of a Relay connection is boilerplate every user writes:
execute, read `pageInfo.endCursor`, execute again with `after:`, repeat until
`hasNextPage` is false. Nothing about it is interesting, everyone writes it
slightly differently, and getting the termination condition wrong loops forever
against a misbehaving server.

## What we measured — schemas

8 real schemas: GitHub, GitLab, Shopify Storefront, Linear, Saleor, Contentful,
Rick & Morty, PokeAPI. A connection is an OBJECT with `pageInfo` and either
`edges { node }` or `nodes`.

| | |
|---|---|
| connection types detected structurally | **717 / 717**, zero misses |
| connection fields accepting a cursor argument | 1545 / 1547 (99.87%) |
| connection fields *also* accepting an offset argument | **4 / 1547 (0.26%)** |
| schemas with **zero** connections (non-Relay) | **3 / 8** |
| connection types exposing `nodes` but not `edges` | **0 / 717** |

**Non-Relay pagination is a separate world, not a variant.** Contentful, Rick &
Morty and PokeAPI/Hasura paginate by `skip`/`limit`, `page`, or `offset` and have
no connection-shaped type at all. This feature does not cover them and should say
"Relay connections", never "pagination".

### Nullability of the walk path — 717 connection types

This decides how much `&.`/`compact` the generated walk carries, and whether it
stays `# typed: strict` without `T.must`.

| field | NON_NULL | nullable |
|---|---|---|
| `pageInfo` | **717 / 717** | 0 |
| `pageInfo.hasNextPage`, `.hasPreviousPage` | **717 / 717** | 0 |
| `pageInfo.endCursor`, `.startCursor` | 0 | **717 / 717** |
| `edges[].cursor` | **717 / 717** | 0 |
| `edges` list, `edges[]`, `edge.node` | 135 / 717 | 582 / 717 |

Three consequences, all forced rather than chosen:

- **The cursor is `T.nilable(String)` everywhere.** Not one schema of eight makes
  `endCursor` non-null. The walk cannot `T.must` it; it must stop on nil. The
  live walk below shows this is not pedantry — it is a real infinite loop.
- **`edges[].cursor` is the only non-null cursor in the vocabulary**, on every
  schema. When a query selects it, it is strictly the better thing to advance on.
- **`compact` is per-schema and known at generation time.** Shopify (28/28),
  Linear (69/69) and Saleor (38/38) make `edges`, the edge, and `edge.node`
  non-null; GitHub (0/158) and GitLab (1/424) make all three nullable. The plan
  carries a literal per query, so `# typed: strict` holds with no `T.must`.

## What we measured — real queries

4 corpora of real application queries: `.graphql` files from GitHub code search
(GitHub-API consumers), GitLab's frontend (`app/assets/javascripts`, `#import`
closure resolved), Saleor's storefront, and Shopify Hydrogen's inline `#graphql`
literals.

**Method.** Every operation is parsed and walked against its own schema.
Excluded: operations whose root fields do not exist in that schema (wrong API),
operations with an unresolved fragment spread (a single-file code-search download
whose fragments live in a sibling file — 62 operations, 3.6%; leaving them in
inflates every "didn't select `pageInfo`" count, because the missing file *is*
the `PageInfo` fragment), and exact duplicate operation bodies. **Denominator:
1664 operations** — GitHub 714, GitLab 820, Hydrogen 70, Saleor 60. GitHub code
search returns near-duplicates from the same repo, so every figure below was
re-run with a ≤5-ops-per-repo cap (1426 operations); the capped figure never
moves a conclusion, and is given where it moves the number at all.

| | share of **all 1664** | share of the **531 with pagination intent** |
|---|---|---|
| selects at least one connection | 59.7% | — |
| binds a cursor variable (= pagination intent) | 31.9% | 100% |
| plannable **as written** | — | **85.9%** |
| two cursor-bound connections — irreducibly ambiguous | — | 5.1% |
| target inside a list (`edges { node { reviews(after:) } }`) | — | 2.6% |
| binds **both** `after:` and `before:` on one connection | — | **17.3%** |
| touches `before:` or `last:` at all | **10.0%** | 31.4% |

**The naive rule is the trap.** "Refuse if the query contains more than one
connection" plans only **43%** — roughly half of real queries select a second
connection they have no intention of paging (a dropdown's first 20 labels). The
rule that reaches 86% is one sentence with no exceptions:

> The iteration target is the connection whose cursor argument is bound to a
> query variable.

Note a nested connection is *present* in 25–40% of operations but is the
**target** in 2.6%. A blanket refusal on nesting would be another 43%-style trap.

### What a generation-time refusal would cost

A refusal fires on every query, not only the paginating ones. Over all 1664
operations — the denominator is the point:

| | all ops | capped |
|---|---|---|
| **any** proposed refusal fires | **5.8%** | 6.1% |
| ... `pageInfo` incomplete, cursor variable bound (intent established) | 2.8% | 2.9% |
| ... **no cursor variable bound, yet pagination-shaped** | **3.0%** | 3.2% |
| ... of those, cursor-aware (selects `endCursor` or `edges { cursor }`) | 2.3% | 2.4% |
| ... of those, **"more…" affordance only** (`hasNextPage`, no cursor field anywhere) | **0.7%** | 0.8% |

The 0.7% is the 43%-trap read from the other side, and it is not hypothetical —
all 11 are the shape the design feared, e.g.

```graphql
comments(first: 100) { nodes { id body } pageInfo { hasNextPage } }
```

A truncation check, not a paginating query. It generates in 0.5.0 and would stop.

The 2.3% above it is a **judgement, not a measurement**: an operation that
selects `endCursor` but binds no variable may be a paginating query missing one
line, or may be a shared `...PageInfoFields` fragment spread into a
single-page selection. Nothing in the source distinguishes them.

### The `pageInfo`-not-selected refusal is mostly wrong

Of the 567 cursor-bound connection selections, 50 (8.8%) do not select
`pageInfo { hasNextPage endCursor }`. Refusing them with "select `pageInfo`"
would be wrong advice for **37 of the 50 (74%)**, because they already paginate
correctly by a route this iterator doesn't implement:

| | |
|---|---|
| `endCursor` selected, `hasNextPage` not — advances fine, stops on an empty page | 16 |
| backward walk with `pageInfo { hasPreviousPage startCursor }` selected | 14 |
| `edges { cursor }` selected (3 of them with `hasNextPage` too) | **7** |
| genuinely stuck — knows there is more, has no cursor to resume from | 13 |

Real examples of the third row, both working code today:

```graphql
starredRepositories(first: 100, after: $after) { nodes { nameWithOwner } edges { cursor } totalCount }
labels(first: 100, after: $after) { pageInfo { hasNextPage } edges { cursor node { name url } } }
```

So the refusal's *trigger* is right (these queries are not walkable by our plan)
but its *advice* is wrong. The fix is to widen what counts as walk-ready — any
(cursor source, stop signal) pair — which leaves 13 selections (2.3% of targets,
0.8% of all operations) genuinely unable to walk.

### One live walk — the semantics, not the shape

717/717 structural detection says the shape is right; only a real walk says the
semantics are. Hand-written cursor loops against `api.github.com/graphql`
(`rails/rails` issues; `dpep/graph_weaver` labels and `rmosolgo/graphql-ruby`
releases, both walked to exhaustion). Confirmed as assumed: `endCursor` equals
the last edge's `cursor` on every page; cursors never repeat; the last page
returns `hasNextPage: false` with a non-null `endCursor`; `edges { cursor }`
alone walks and terminates (one extra request). Four things were **not** as
assumed:

- **`after: null` restarts from page 1.** Past the end, `endCursor` comes back
  **null** with `edges: []` — as it does for an empty connection and for
  `first: 0`. A loop that assigns `cursor = pageInfo.endCursor` before
  re-checking `hasNextPage` therefore loops forever, live, on a well-behaved
  server. The nullability row above, with teeth: check the stop signal first.
- **`first: 0` returns `hasNextPage: true`, `endCursor: null`, zero edges** — so
  a cursor-stall guard fires on correct server output. The guard is still right,
  but its message must name `first: 0` rather than accuse the server.
- **`hasNextPage: false` is a stop signal, not a completeness guarantee.**
  `search` ends cleanly at exactly 1000 of 7598 results; a connection the token
  can't read returns `totalCount: 0`, `edges: []`, no `errors`, while the sibling
  scalar says 58757. So `totalCount` is no reconciliation check either, and the
  iterator must promise "every page the server gave", not "every item".
- **A stale or wrong cursor is not reliably rejected.** Same server, same cursor:
  `milestones` returned `null` plus `INVALID_CURSOR_ARGUMENTS`, `releases`
  returned an empty page with no error, and `labels(after: "not-a-cursor")`
  silently returned page 1.

## Goals

1. Iterate every page of a paginated query without writing a cursor loop.
2. Diagnose at **generation** time, naming the fix, when a query is *nearly*
   paginable. That diagnosis is the product as much as the iterator is.
3. Never loop forever against a server whose cursor stops advancing.
4. Cost nothing for the queries that don't paginate — including not breaking
   them.

## Non-goals

- **Non-Relay pagination.** See above. Silence there is honest; a half-working
  `skip`/`limit` mode is not.
- **Cheap random access to page N.** Cursors are sequential. Nothing can make
  page 40 cost one request, and pretending otherwise would be the expensive
  kind of wrong.
- **Caching cursors on the user's behalf.** Staleness policy is the app's, and
  a cache we own would be wrong in a way the app can't see.
- **Promising completeness.** The walk yields the pages the server gave. See the
  live walk: `hasNextPage: false` can mean "capped at 1000" or "you can't see
  this".

## Proposal — the surface

Emitted on a generated module **only when the query is plannable**:

```ruby
ProductsQuery.pages(first: 50)                        # Enumerator of typed Results
ProductsQuery.each_node(first: 50) { |product| … }    # typed nodes, all pages
ProductsQuery.each_node(first: 50).lazy.select { … }.first(200)
```

`pages` yields the whole typed `Result`, not just the connection, so the query's
other selections — including its other connections — stay reachable. `each_node`
flattens `edges { node }` or `nodes`, whichever the query selected, applying
`compact` only where the schema's nullability requires it (known at generation
time — 582 of 717 connection types need it, 135 provably don't).

The `first:` kwarg is emitted **only when the query declares a variable for it**
— 40% of cursor-bound targets hardcode their page size (229 of 567), and
inventing a kwarg for a literal would be a second rule. This is the existing
"one kwarg per declared variable" rule, unchanged.

### The walk

Stated once, because the live walk showed each clause earning its place:

> Advance on `edges[].cursor` when the query selects it, otherwise on
> `pageInfo.endCursor`. Stop when the direction's `hasNextPage`/`hasPreviousPage`
> is false, when the cursor is nil, or when the page is empty — **checked before
> the cursor is read**. Raise if the cursor did not advance.

`edges[].cursor` is preferred because it is non-null on 717/717 connection types
where `endCursor` is nullable on 717/717. The nil check is not defensive
programming; it is the difference between terminating and restarting from page 1.

### Direction

**v1 walks both directions.** The earlier plan — recognise `after:` only, defer
backward — was written before the number: `before:`/`last:` appears in **10.0%**
of all operations and `before:` is bound to a variable in 6.6%, which is nowhere
near the "under 1% and defer it" threshold. It is also not a fringe: 17.3% of
paginating operations bind **both** `after:` and `before:` on one connection
(GitLab's frontend 70% of its cursor-bound selections, Hydrogen 100% — a
bidirectional paginator is what a UI framework generates).

The cost of both directions is one substitution, not a second design: swap
`after`/`endCursor`/`hasNextPage` for `before`/`startCursor`/`hasPreviousPage`.
All four fields exist and are present on 717/717 `PageInfo` types. The rule:

> The walk goes forward. It goes backward only when the query binds `before:`
> and not `after:`.

A query that binds both is walked forward, with `before:` as an ordinary declared
kwarg bounding the range — which is what a bidirectional paginator's forward mode
already is. One sentence, no exceptions, and it removes a refusal rather than
adding one.

## Proposal — the refusals, and how they are delivered

**Delivered at the call site, not at generation** — the change the false-positive
measurement forces. Hard refusal at `generate` would stop 5.8% of operations that
generate today, of which 3.0% never asked to paginate and 0.7% demonstrably have
no pagination intent at all: a breaking change to working code, paid by users who
will never call `pages`.

So: **when a query is not plannable, emit no `pages`/`each_node` method.** The
generation-time analysis still runs and still produces the full diagnosis; it is
carried into the generated module's `method_missing`, which raises it when
someone asks. `Representations.method_missing` in `codegen/emit.rb` already has
exactly this shape — a `T.noreturn` sig, a message naming what this query *does*
support and the edit that would add the missing one — and the `T.noreturn` sig is
what makes `srb tc` flag `.pages` statically, at the call site, where the intent
lives. Nothing that generates today stops generating.

The diagnoses, over the 531 operations with pagination intent:

| diagnosis | frequency |
|---|---|
| two connections both bound to cursor variables — which did you mean? | 5.1% |
| the target is inside a list — one variable can't hold a per-node cursor | 2.6% |
| no cursor source: `pageInfo { endCursor }` or `edges { cursor }` | 2.3% of targets |
| no stop signal: `pageInfo { hasNextPage }`, or an empty page | (subsumed above) |
| the cursor variable is `String!` (can't express the first page) | <1% |

Note the third row is what remains of the old "9% `pageInfo` not selected" once
the walk accepts any (cursor source, stop signal) pair — 74% of that refusal was
firing on queries that already paginate correctly.

Two runtime raises, which cannot be generation-time checks:

- **The cursor stopped advancing while the walk claimed more.** Raise, naming the
  connection and the stalled cursor — breaking quietly would hand back a
  truncated result with no signal. This replaces a `max_pages:` knob. The message
  must name `first: 0` as a likely cause: the live walk shows a correct server
  returning `hasNextPage: true` with a null cursor and zero edges for it.
- **A nil on the path to `pageInfo`** — `repository(owner:, name:)` is nullable —
  ends the walk after yielding that `Result`. Defined out of existence in one
  sentence rather than handled as a case.

A genuinely endless connection whose cursor keeps advancing is *essential*, not a
bug — `first(n)` and `.lazy` are the caller's tools there.

## Page/offset input

An app whose UI takes `?page=3&per_page=25` and whose API is cursor-only cannot
have cheap random access. But **the iterator is the walk**, so it needs no new
machinery:

```ruby
ProductsQuery.pages(first: per_page).take(page).last   # page 3 = 3 fetches
```

**Not `drop(page - 1).first`.** `Enumerable#drop` is eager, so that idiom fetches
*every* page: measured, `drop(2).first` → 10 fetches, `take(3).last` → 3. The
first draft of this document recommended the eager one, in the paragraph written
to make the cost honest — which is the argument for documenting it carefully.

So the offset story is documentation plus one decision:

- **Page N costs N round trips**, and the docs say so in fetches.
- **The cursor kwarg on `pages` is the *start* cursor**, which falls out of the
  existing "one kwarg per declared variable" rule and answers the deep-link case:
  `ProductsQuery.pages(first: 25, after: params[:after])` is one request. The app
  carries the cursor in its own URL; `rel=next`, deep links and SEO work. Only
  page 3 *by number* is lost — which the server cannot do and we should not fake.
  (Per the live walk, a stale cursor may come back as an error, an empty page, or
  a silent restart from page 1; the app must not assume the server validates it.)
- **The better fix is usually to stop needing page numbers.** Offset pagination
  over a shifting dataset duplicates and skips rows, which is *why* cursors exist.

**Skeleton walking — later, if anyone asks.** The walk to page N needn't fetch
what the real query fetches: a stripped copy — same connection, arguments and
variables, selecting only `edges { cursor } pageInfo { hasNextPage }` — advances
just as well, and can stride at `first: 100` where the UI wants 25. It cuts
bandwidth and usually server work, but **not latency**, so an app whose complaint
is "deep pages are slow" is not rescued. It costs a second emitted document per
paginated query to optimise the access pattern the corpus says is rare. Ship the
iterator; keep this as the answer if page-N demand turns out to be real.

## Ergonomics — how far toward ActiveRecord?

**Methods on a `Result` that appear to control fetching are a trap**, and the
reason is specific:

> An ActiveRecord relation is chainable because it builds SQL — `.first(n)` adds
> `LIMIT n` *before* the query runs. A `Result` here is past tense: the query
> already ran. So `res.first(n)` either slices data you already paid for (a lie
> about cost) or triggers hidden fetches (spooky action from something that
> reads like a reader).

**The module is a question; the result is an answer.** Pagination verbs belong on
the question; reading verbs on the answer are fine, but must not look like they
can change what was fetched. The gap between the two is where an AR relation
lives — a *pending* query — and Ruby already has that object:

| | tense | what it may do |
|---|---|---|
| the module | a question | controls what gets fetched — `pages`, `each_node` |
| the Enumerator | a pending walk | chains, and fetches only as far as it is consumed |
| the `Result` | an answer | reads only; nothing that looks like it controls fetching |

**Teach it as one sentence, not three rows:**

> `pages` returns an Enumerator. Each element it yields is one request.
> `first(n)`, `take(n)` and `break` stop early; `map`, `select`, `drop`, `count`
> and `to_a` walk every page unless you `.lazy` first.

A developer given that sentence knows "a yield is a request", which is the whole
curriculum. `Enumerator` is not a new concept to them — `find_each` without a
block returns one, so do `each_slice`, `File.foreach` and `Dir.each_child`.

**No purpose-built enumerator class.** It would re-implement `first`/`take`/
`each`/`lazy` with identical semantics, and every `Enumerable` method omitted
becomes a support question. ActiveRecord built `BatchEnumerator` only because it
needed relation verbs (`delete_all`, `update_all`) with no analogue here.

**`each_batch`: cut.** A second name for `pages.each`, and not even the
convention it was reaching for — ActiveRecord spells those `find_each` and
`in_batches`. `pages` and `each_node` are enough.

## Prerequisite

`Testing::FakeClient` fabricates `hasNextPage` as a random boolean, so
`each_node` against `graphql: :fake` would terminate arbitrarily or never — the
feature would be untestable through the harness this library recommends.

The fix is one line, not a design: fabricate `hasNextPage`/`hasPreviousPage` as
`false` in the existing name-keyed table in `testing/values.rb`. Deterministic,
terminates, one page. "My code handles three pages" is a real gap, but reach for
overrides or a cassette first and only build something if that fails someone.

## Where it goes

The walk that `Codegen#object_node` already performs visits every selection with
its schema field and builds the `prop` chain an iterator needs. Recording each
connection occurrence during that walk, and picking the target in `#generate`,
requires no new traversal.

**The loop belongs in `QueryModule`, not in every generated file.** That class
exists precisely because every module's copy of a thing was identical, and this
is the first feature that would otherwise turn a generated module into a
mini-runtime. Generate thin typed wrappers — the sigs (`Enumerator[Result]`, the
node yield type) are genuinely per-query — that hand the plan to one gem-side
method as literals: the cursor kwarg, the direction, the cursor-source and
stop-signal chains, the node chain, and whether the node list needs `compact`. A
bug in the loop is then a gem fix rather than a regeneration, and it is tested
once. This is still "closes over nothing": the plan remains literals in the
generated file.

**Partial errors mid-walk need no design.** Pages 1..k are already yielded before
page k+1 raises `QueryError`, so nothing is lost. Worth a sentence so nobody
later adds a "collect, then raise" mode.

## Settled

1. **`page(n)`: no.** Resume-from-cursor covers the real case for free, and the
   remaining "page 3 by number" is what the server cannot do.
2. **`each_batch`: no.** A second name for `pages.each`.
3. **`pages(on:)`: no.** The knob models neither reading of the ambiguity —
   sibling connections would walk in lock-step, which nobody wants, and a nested
   target's cursor is per-node, which `on:` cannot express. Refuse, and say
   "this query paginates two things; split it".
4. **Backward pagination: in v1.** `before:`/`last:` is 10.0% of operations, not
   the <1% that would have justified deferring it, and it costs one substitution.
5. **Refusals are delivered at the call site**, not at generation. Hard refusal
   would break 3.0% of operations that never asked to paginate.
6. **The walk accepts any (cursor source, stop signal) pair.** Demanding
   `pageInfo { hasNextPage endCursor }` would reject 37 of 50 selections that
   already paginate correctly.
7. **`pages` returns a plain `Enumerator`, not `Enumerator::Lazy`.** See below —
   this one is a judgement, and the argument against it is real.

## Still open — and each is a judgement, not a missing number

1. **Plain `Enumerator` vs `Enumerator::Lazy`.** Recommending **plain**, on two
   grounds. `Enumerator::Lazy#map` returns a `Lazy`, not an Array, so every user
   of every paginated query — including the ones who fetch two pages and never
   think about cost — pays a surprise in their code and in their Sorbet sigs;
   and plain is what `find_each`, `each_slice` and `File.foreach` return, so it
   costs zero learning. `.lazy` is one word away, and `first(n)`/`take(n)` are
   already lazy without it.

   **The argument against, which is not weak:** `pages.select { … }.first` walks
   every page, and "silently expensive is silently wrong" is a stated principle
   here. The methods people reach for by reflex — `select`, `map`, `count`,
   `sort_by` — are exactly the ones that become an unbounded fetch loop, and the
   failure is invisible in development, where `FakeClient` returns one page (and
   will be *made* to return one page, per the prerequisite above) and only
   surfaces in production against a large account. `Lazy` inverts the default so
   the expensive thing is the one you ask for.

   The recommendation rests on making "silently" false rather than on the cost
   being small: every page fetch goes through the existing logging seam, so the
   walk is visible in a log and in an APM trace. If that turns out not to be
   enough — if someone ships a `select` over 400 pages — the answer is to revisit
   this, not to add a knob.

2. **The 2.3% of operations that select `endCursor` but bind no cursor
   variable.** Whether those are paginating queries missing one line or shared
   `PageInfo` fragments in single-page selections cannot be read off the source.
   Call-site delivery makes the question moot for now — nothing breaks either way
   — which is a good reason to prefer it while the question stays open.

3. **What `pages` promises.** The live walk shows `hasNextPage: false` can mean
   "no more", "capped at 1000", or "you can't see this". The docs must say "every
   page the server gave", and it is a judgement whether that is enough or whether
   the iterator should also surface `totalCount` when the query selected it, so
   the caller can notice a shortfall. Leaning toward: say it plainly, add
   nothing — `totalCount` was wrong too (0 against a real 58757).
