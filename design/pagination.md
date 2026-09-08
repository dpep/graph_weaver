# Pagination — goals, measurements, and a proposal

Status: proposal, not built. Targets 0.6.0.

## The problem

Iterating every page of a Relay connection is boilerplate every user writes:
execute, read `pageInfo.endCursor`, execute again with `after:`, repeat until
`hasNextPage` is false. Nothing about it is interesting, everyone writes it
slightly differently, and getting the termination condition wrong loops forever
against a misbehaving server.

## What we measured before designing

Against 8 real schemas (GitHub, GitLab, Shopify Storefront, Linear, Saleor,
Contentful, Rick & Morty, PokeAPI) and 4 corpora of real application queries
(573 GitHub-consumer `.graphql` files, GitLab's frontend, Saleor's storefront,
Shopify Hydrogen — 424 operations with genuine pagination intent):

| | |
|---|---|
| connection types detected structurally | **716 / 716**, zero misses |
| connection fields accepting a cursor argument | 1545 / 1547 (99.87%) |
| real paginated operations plannable **as written** | **81%** |
| plannable after a one-line fix the error can name | **95%** |
| irreducibly ambiguous (two cursor-bound connections) | 5% |
| connection fields *also* accepting an offset argument | **4 / 1547 (0.26%)** |

Two findings changed the design:

**The naive rule is the trap.** "Refuse if the query contains more than one
connection" plans only **44%** — roughly half of real queries select a second
connection they have no intention of paging (a dropdown's first 20 labels). The
rule that reaches 81% is one sentence with no exceptions:

> The iteration target is the connection whose cursor argument is bound to a
> query variable.

**Non-Relay pagination is a separate world, not a variant.** Three of the eight
schemas (Contentful, Rick & Morty, PokeAPI/Hasura) have zero connection-shaped
types — they paginate by `skip`/`limit`, `page`, or `offset`. This feature does
not cover them and should say "Relay connections", never "pagination".

## Goals

1. Iterate every page of a paginated query without writing a cursor loop.
2. Refuse at **generation** time, naming the fix, when a query is *nearly*
   paginable — the 14% that a one-line edit converts. That refusal is the
   product as much as the iterator is.
3. Never loop forever against a server whose cursor stops advancing.
4. Cost nothing for the queries that don't paginate.

## Non-goals

- **Non-Relay pagination.** See above. Silence there is honest; a half-working
  `skip`/`limit` mode is not.
- **Cheap random access to page N.** Cursors are sequential. Nothing can make
  page 40 cost one request, and pretending otherwise would be the expensive
  kind of wrong.
- **Caching cursors on the user's behalf.** Staleness policy is the app's, and
  a cache we own would be wrong in a way the app can't see.

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
time).

The `first:` kwarg is emitted **only when the query declares a variable for it**
— 46% of real paginated queries hardcode `first: 20`, and inventing a kwarg for
a literal would be a second rule. This is the existing "one kwarg per declared
variable" rule, unchanged.

## Proposal — the refusals

All at generation time, each naming the edit:

| refusal | frequency in the corpus |
|---|---|
| two connections both bound to cursor variables — which did you mean? | 5% |
| no cursor variable declared, or the cursor is a literal | 5% |
| `pageInfo { hasNextPage endCursor }` not selected | 9% |
| the cursor variable is `String!` (can't express the first page) | <1% |

And one at runtime, which cannot be a generation-time check: **the cursor stopped
advancing while `hasNextPage` stayed true.** Break, don't spin. This replaces a
`max_pages:` knob — the guard is free and catches the actual failure mode.

Note a nested connection is *present* in 25–40% of operations but is the
**target** in 1.5%. A blanket refusal on nesting would be another 44%-style trap.

## Page/offset input — what we can honestly offer

An app whose UI takes `?page=3&per_page=25` and whose API is cursor-only cannot
have cheap random access. But it needs less new machinery than it appears,
because **the iterator is the walk**:

```ruby
ProductsQuery.pages(first: per_page).drop(page - 1).first   # page 3 = 3 fetches
```

That already works given `pages`. So the offset story is documentation plus one
decision, not a feature:

- **Document the idiom, with its cost stated in fetches.** Page N costs N round
  trips. That is the truth and users should meet it in the docs, not in an APM
  graph.
- **Expose the cursor at every page boundary** — `pages` yields the `Result`,
  which carries `pageInfo`, so an app that wants to memoise "page 3 → cursor X"
  in its own session or cache can. We don't own that cache.
- **The better fix is usually to stop needing page numbers.** Carrying a cursor
  in the app's own URL (`?after=xyz`) is what cursor-paginated UIs do, and it
  fixes a bug rather than working around one: offset pagination over a shifting
  dataset duplicates and skips rows, which is *why* cursors exist.

### Walking a skeleton, not the real query

The walk to page N does not have to fetch what the real query fetches. A
stripped copy — same connection, same arguments, same variables, but selecting
only what is needed to advance — is far cheaper per page:

```graphql
# the real query, per page: every field, every nested object
{ products(first: 25, after: $c) { edges { node { id title price
    reviews(first: 5) { edges { node { body author { name } } } } } } } }

# the skeleton, per page: enough to know where the next page starts
{ products(first: 25, after: $c) { edges { cursor } pageInfo { hasNextPage } } }
```

Then walk the skeleton to page N and run the **real** query once, with the
cursor the walk landed on. `N` cheap requests plus one expensive one, instead of
`N` expensive ones.

**And `edges { cursor }` makes it better than page-at-a-time.** Every edge
carries its own cursor, so the skeleton can walk in strides the *server* allows
rather than strides the *UI* wants — `first: 100` to reach item 1000 is 10
requests, not the 40 that `first: 25` would take, and the cursor for item 1000
is sitting in the tenth response. The measurement supports leaning on this:
`nodes` without `edges` never occurred in 716 connection types, so `edges` is
reliably available even where `nodes` isn't (Saleor is `edges`-only, 38/38).

**Be precise about what this fixes.** It cuts bandwidth and, usually,
server-side resolution work — the skeleton doesn't make the server load nested
objects. It does **not** cut latency: page 40 is still 10+ round trips, so an
app whose complaint is "deep pages are slow" is not rescued. Say that plainly
rather than letting the optimisation read as making random access cheap.

Two assumptions it rests on, both worth stating:

- **The skeleton must order and filter identically to the real query**, which
  holds when every argument and variable is copied verbatim. A server whose
  ordering depends on which fields were selected would break this, and would be
  pathological.
- **Server-side savings are not guaranteed.** A resolver that loads whole
  records before serializing pays the same either way; the bandwidth saving is
  real regardless.

Cost to build: synthesising a second document per paginated query — keep the
path to the target connection, replace its selection set, carry the same
variable definitions. Mechanical, but it is new codegen machinery and a second
emitted artifact, and it should not gate the basic iterator.

**When to build it.** Not with the iterator. The technique is sound — it is what
a query planner does, and the skeleton is *derived* from the real query rather
than maintained beside it, so it cannot drift the way a hand-kept copy would.
But it optimises deep page-number access, which the corpus says is the rare
need, and it costs a second emitted document per paginated query. Ship the
iterator, find out whether anyone actually asks for page N, and keep this as the
answer if they do. Building it first would be gating a real cost on an assumed
demand — the mistake the measurement at the top of this document exists to
prevent.

**This changes the `page(n)` calculus.** The objection below was that a helper
quietly costing N requests is silently-expensive. Skeleton walking makes those N
requests small and lets them be fewer — which is a different, more defensible
trade. Whether that is enough to ship `page(n)` is still the open question, but
it should be judged against the skeleton cost, not the naive one.

Open question for review: should a `page(n, per_page:)` helper exist at all, or
does shipping it legitimise the expensive path? Argument for: apps with SEO or
deep-link requirements genuinely need it, and doing it themselves gets the
fencepost wrong. Argument against: a helper that quietly makes N requests is
silently-expensive, which in a request path is the same class of problem as
silently-wrong.

## Ergonomics — how far toward ActiveRecord?

Tempting: `res.first(n)`, `res.collection.each`, `each_batch`.

**`each_batch` on the module is good.** Ruby developers know `find_each` and
`in_batches`; matching a convention costs the user nothing to learn, and the
name is honest about what it does.

**Methods on a `Result` that appear to control fetching are a trap**, and the
reason is specific:

> An ActiveRecord relation is chainable because it builds SQL — `.first(n)` adds
> `LIMIT n` *before* the query runs. A `Result` here is past tense: the query
> already ran. So `res.first(n)` either slices data you already paid for (a lie
> about cost) or triggers hidden fetches (spooky action from something that
> reads like a reader).

**The module is a question; the result is an answer.** Pagination verbs belong
on the question. Reading verbs on the answer are fine — `result.products.edges`
is already there and nobody is confused by it — but they must not look like they
can change what was fetched.

### The missing middle is an Enumerator

The module/result split has a gap, and the gap is where ActiveRecord actually
lives. An AR relation is neither a query nor a result — it is a *pending* query
you can refine, and that is exactly what makes chaining honest there.

Ruby already has that object: **`Enumerator`, and `Enumerator::Lazy`.** If
`pages` returns one, the AR ergonomics fall out without a new concept:

```ruby
pages = ProductsQuery.pages(first: 50)   # nothing fetched yet

pages.first(3)                           # three pages, then stops
pages.lazy.map { … }.first(200)          # stops as soon as it has 200
pages.each { |page| … }                  # all of them
```

`Enumerator#first(n)` is already lazy — it stops early without `.lazy`. `map`
and `select` are not, so chaining wants `.lazy`, and the docs should say which
is which rather than leaving it to be discovered.

So there are three things, not two:

| | tense | what it may do |
|---|---|---|
| the module | a question | controls what gets fetched — `pages`, `each_node` |
| the Enumerator | a pending walk | chains, and fetches only as far as it is consumed |
| the `Result` | an answer | reads only; nothing that looks like it controls fetching |

`res.first(n)` is wrong for the same reason `pages.first(n)` is right: one has
already paid for its data, the other has not paid yet. Borrowing AR's *shape*
is fine; what would teach a false model is borrowing it onto the object where
the fetching is already over.

## Prerequisite

`Testing::FakeClient` fabricates `hasNextPage` as a random boolean, so
`each_node` against `graphql: :fake` would terminate arbitrarily or never — the
feature would be untestable through the harness this library recommends. The
fake must synthesise a terminating page sequence before this ships.

## Where it goes

The walk that `Codegen#object_node` already performs visits every selection with
its schema field and builds the `prop` chain an iterator needs. Recording each
connection occurrence during that walk, picking the target and raising the
refusals in `#generate` — beside the existing variable-collision checks, so
refusals land as generation-time `GraphWeaver::Error`s carrying the query path —
requires no new traversal.

Emission is one private method in `Emit`, called from `emit_module` after
`emit_execute`. It closes over nothing: module methods calling the already
emitted `execute!`, with the cursor kwarg and the accessor chain baked in as
literals from the plan.

## Open questions for review

1. Does `page(n, per_page:)` ship, or is documenting `pages.drop(n - 1).first`
   the more honest answer?
2. Is `each_batch` worth having alongside `pages`, or is it a second name for
   one idea?
3. Should the 5% ambiguous case (two cursor-bound connections) be resolvable by
   naming the target — `pages(on: :products)` — or does that knob cost more than
   the 5% is worth?
4. Backwards pagination (`last:`/`before:`) — symmetric support, or refuse and
   see if anyone asks?
