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

Proposed line:

- on the module (future tense, controls fetching): `pages`, `each_node`,
  and possibly `each_batch` as an alias for page-at-a-time iteration
- on the result (past tense, reads only): nothing new

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
