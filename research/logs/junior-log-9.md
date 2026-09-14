# Junior dev lifecycle log — graph_weaver

Task: set up a Rails app outside the gem repo, generate a typed client for
`Catalog::Schema` in-process, write an in_process spec + cassette, commit.
Then make 4 schema changes one at a time and run every maintenance task after
each, recording exact output. Work only from README.md -> docs/, no lib/ or
spec/ unless stuck.

---

## Setup phase

- Created Rails 8.1.3.1 app (--api --skip-active-record --minimal) at
  /tmp/claude/graph_weaver/junior-app-9, ruby 3.4.9, graphql 2.6.10.
- Wrote Catalog::Schema (app/graphql/catalog/...) serving
  Product{id sku name price status}, enum ProductStatus{ACTIVE DISCONTINUED},
  Query.products(status:), backed by an in-memory PRODUCTS array.
- SURPRISE (app-side, not graph_weaver's fault): first draft put
  `Catalog::PRODUCTS = [...]` in its own file app/graphql/catalog/products.rb.
  Zeitwerk only autoloads classes/modules from a file matching the constant
  path, not a plain constant assignment, so the resolver raised
  `NameError: uninitialized constant Catalog::PRODUCTS` at request time (HTTP
  500 from GraphWeaver, wrapped as GraphWeaver::ServerError) the first time the
  spec ran. Fixed by moving the data into QueryType as
  `Catalog::Types::QueryType::PRODUCTS`. Recording verbatim first error below.
- `rails g graph_weaver:install Catalog::Schema` matched the docs exactly:
  wrote initializer (`GraphWeaver.client = GraphWeaver.new(Catalog::Schema)`
  inside `to_prepare`), .keep dirs, graphql.config.yml, inserted
  `require "graph_weaver/rspec"` into spec/rails_helper.rb, introspected
  app/graphql/schema.json from the live class. Printed exactly the doc's
  "Write a query ... rake graph_weaver:generate" footer.
- Wrote app/graphql/queries/products.graphql selecting id sku name price status.
- `rake graph_weaver:generate` -> wrote types/product_status.rb, types.rb,
  products_query.rb. Clean, no warnings (no unregistered scalars, since
  Float/String/ID are built in).
- Wrote spec/requests/products_query_spec.rb: one `graphql: :in_process` group
  with two examples — a plain assertion, and one that records/replays
  spec/cassettes/products.yml via `GraphWeaver::Testing.cassette("products",
  client: GraphWeaver.new(Catalog::Schema))`, explicitly passing `client:` per
  call to step out of the :in_process tag (per testing.md's "two things step
  out of a tag").
- First rspec run FAILED both examples with the Zeitwerk NameError above.
  Verbatim:
  ```
  GraphWeaver::ServerError:
    HTTP 500: NameError: uninitialized constant Catalog::PRODUCTS
  ...
  --- Caused by: ---
  NameError:
    uninitialized constant Catalog::PRODUCTS
    ./app/graphql/catalog/types/query_type.rb:11:in 'Catalog::Types::QueryType#products'
  ```
  After moving PRODUCTS into query_type.rb, `bundle exec rspec
  spec/requests/products_query_spec.rb` -> 2 examples, 0 failures. Cassette
  recorded to spec/cassettes/products.yml (plaintext, not anonymized — no
  config.anonymize set; acceptable, this is fake internal data, not a real
  API).
- Baseline maintenance tasks (before any schema change), all from the repo
  root with `bundle exec rake graph_weaver:<task>`:
  - `verify` -> "generated queries up to date", exit 0.
  - `schema:diff` -> refused: "records no source url — it wasn't introspected
    from one. Pass transport:, or rebuild it from the schema class that
    produced it." exit 1. This is EXPECTED per getting_started.md
    ("`schema:diff` and `:refresh` are for servers you don't own; a dump taken
    from a schema class records no url, and they say so") — but it means
    `schema:diff` is a permanent, unconditional refusal for this in-process
    app: it can never detect a drift here, first change or fourth.
  - `schema:refresh` (no URL) -> refused: "records no source url — pass one:
    rake graph_weaver:schema:refresh URL=... (a dump taken from a schema class
    is rebuilt from code, not re-fetched — see
    docs/getting_started.md#your-apps-own-schema-in-process)" exit 1. Message
    names the exact doc anchor — good error.
  - `queries:check` -> "every query validates against the schema" exit 0.
  - `unused` -> "6 selections, 0 unread — 1 query, 22 files swept under .",
    plus the standing "this is a lint, not a proof" footer. exit 0.
  - `cassettes:check` -> "spec/cassettes/products.yml: 0 stale (1 checked)" /
    "every recording still casts" exit 0.
  Set up `lib/tasks/graphql.rake` with graphql-ruby's own
  `GraphQL::RakeTask.new(schema_name: "Catalog::Schema", ...)` per
  getting_started.md's in-process section, so `rake graphql:schema:json` is
  the real "schema:refresh" for this app (graph_weaver's own schema:refresh
  task is structurally inapplicable in-process).
- Committed initial app state: git commit d9f66c5.

## Change 1: rename `sku` -> `stockCode`

Edited Catalog::Types::ProductType (`field :sku` -> `field :stock_code`, wire
name camelizes automatically to `stockCode`) and the PRODUCTS data hash keys.
Confirmed via `Catalog::Schema.to_definition`: `stockCode: String!`.

Ran the full battery COLD (dump not yet refreshed):

| task | output (condensed) | exit |
|---|---|---|
| schema:diff | same permanent refusal: "records no source url ... rebuild it from the schema class that produced it" | 1 |
| schema:refresh | same permanent refusal, names `URL=` and the doc anchor | 1 |
| queries:check | `4:5 Field 'sku' doesn't exist on type 'Product'` — 1 invalid query | 1 |
| verify | "generated queries up to date" — **BLIND**, reads the stale committed dump, not the live class | 0 |
| cassettes:check | "0 stale (1 checked)" — **BLIND**, replays the OLD query text against the unchanged generated module, which still expects `sku` | 0 |
| unused | 6 selections, 0 unread — unaffected | 0 |
| generate | "3 already up to date" — **BLIND**, same reason as verify | 0 |

**queries:check is the only task of the seven that caught this change**, and
it caught it immediately — because getting_started.md's own claim
("`queries:check` is unaffected [by dump staleness]: running in-process it
validates against the live class, not the dump") held up exactly as written.
Everything else that reads the dump (verify, generate) or a frozen recording
(cassettes:check) is structurally blind until the dump is refreshed by hand —
which for an in-process schema means `rake graphql:schema:json`, not
`graph_weaver:schema:refresh` (that task is a permanent, unconditional refusal
for any schema whose dump came from a live class rather than a URL — it will
refuse identically on change 4 as on change 1; it is dead weight in this
app's CI).

rspec, cold: the plain `:in_process` example FAILED (real resolver rejects the
now-nonexistent `sku` field), verbatim:
```
GraphWeaver::QueryError:
  GraphQL query failed: Field 'sku' doesn't exist on type 'Product' at 4:5
  (path: query ProductsQuery.products.sku) [undefinedField] — the server
  rejected the query shape: the schema may have changed since generation;
  refresh the schema dump and regenerate
  (rake graph_weaver:schema:refresh && rake graph_weaver:generate)
```
Note the error's own advice names `graph_weaver:schema:refresh`, which is
exactly the task that refuses to run for this app — the advice is right for a
URL-backed schema and wrong (or at least incomplete) for an in-process one;
`rake graphql:schema:json` is what actually fixes it here. **The cassette
example PASSED** — it never touches the live schema on replay, so a schema
rename that broke the real resolver path left the cassette test fully green.
This is the sharpest finding of the day: a cassette recorded before a breaking
rename is not just "possibly stale," it is actively lying that the query still
works.

Fix: updated the .graphql query and the two spec assertions to `stockCode`,
then `rake graphql:schema:json` (refresh) -> `queries:check` green ->
`rake graph_weaver:generate` (wrote products_query.rb) -> `verify` green.

`cassettes:check` after generate but BEFORE re-recording: exit 1 —
"0 stale (0 checked, 1 not sent by any query module)" plus: "this checked
nothing, so it proved nothing: no recording in spec/cassettes carries a query
any of the 1 generated modules sends. Drop this task from CI if you don't
record cassettes, or check that spec/cassettes is where yours live." This is
the doc's own documented case ("Checking none of them fails too") firing
exactly as promised, and it is the only one of the seven tasks that goes from
exit 0 to exit 1 across a change with NO code fix needed other than
re-recording — a pure "the fixture is stale" signal, correctly distinguished
from "nothing to check" (fully-unmatched cassette exits 1, not 0).

rspec then failed the cassette example with `GraphWeaver::Testing::MissingRecording`,
naming the variables and the query text, and saying exactly what to do:
"re-record it (GRAPHWEAVER_RECORD=1 with a client:), or delete the cassette to
start over." Re-recorded with `GRAPHWEAVER_RECORD=1 bundle exec rspec`.

SURPRISE: re-recording APPENDS rather than replaces — the cassette file ended
up with both the old `sku`-shaped entry and the new `stockCode`-shaped one.
`cassettes:check` still reported "0 stale ... 1 not sent by any query module"
and exit 0 (a merely-orphaned entry is not "stale," so it doesn't fail the
build) — nothing in the docs says re-recording prunes anything, and none of
the task output tells you to delete the file first. Deleted the cassette file
and re-recorded clean to avoid shipping cruft; `cassettes:check` -> "0 stale
(1 checked)".

Committed as 0635a79.

## Change 2: add enum member `PREORDER`, have a resolver return it

Added `value "PREORDER"` to Catalog::Types::ProductStatus, and a 4th in-memory
product with `status: "PREORDER"` so a resolver actually hands it back (an
enum value added but never returned would be a much weaker test — this is the
"resolver returns it" the task asked for).

Ran the full battery COLD, with the *original* two specs unchanged (both still
filter `status: "ACTIVE"`, so neither one's selection set ever touches the new
member):

| task | output (condensed) | exit |
|---|---|---|
| schema:diff | same permanent refusal | 1 |
| schema:refresh | same permanent refusal | 1 |
| queries:check | "every query validates against the schema" | 0 |
| verify | "generated queries up to date" | 0 |
| cassettes:check | "0 stale (1 checked)" | 0 |
| unused | 6 selections, 0 unread | 0 |
| generate | "3 already up to date" | 0 |

**Every task was green.** This is the change that slips past everything —
adding an enum member is additive and non-breaking by the schema's own rules,
so nothing here has any way to flag it, and correctly so: nothing is actually
broken yet. Ran the existing two specs too: also green, because neither one's
query result set ever includes the PREORDER product.

Added a third spec — `ProductsQuery.execute!` with no status filter, which
does return the PREORDER product — specifically to exercise the new value.
That's the one that failed, with a real cast error against the (still-stale)
generated `T::Enum`, verbatim:
```
GraphWeaver::CastError:
  failed to cast response into ProductsQuery::Result::Products: status:
  "PREORDER" is not a GraphQLTypes::ProductStatus — expected one of: ACTIVE,
  DISCONTINUED; a value the server added since you generated needs a
  regenerate, or register_enum fallback: to absorb them
```
This is the answer to "which change slipped past everything until a spec
failed" — change 2, and only because I went looking for it with a query that
actually reaches the new value. If the app's only query had kept filtering to
ACTIVE/DISCONTINUED, this change would have shipped completely silently
through all seven tasks and the whole spec suite, forever, until whenever a
caller finally asked for PREORDER products in production.

Fix: `rake graphql:schema:json` (refresh) -> `rake graph_weaver:generate`
(wrote types/product_status.rb) -> `verify` green -> rspec 3/3 green,
`cassettes:check` still "0 stale (1 checked)" (the cassette's query never
selected the new value either, so nothing there needed re-recording).

Committed as bc89a03.

## Change 3: drop `price` entirely

Removed `field :price, Float, null: false` from Catalog::Types::ProductType.

Ran the full battery COLD:

| task | output (condensed) | exit |
|---|---|---|
| schema:diff | same permanent refusal | 1 |
| schema:refresh | same permanent refusal | 1 |
| queries:check | `6:5 Field 'price' doesn't exist on type 'Product'` — 1 invalid query | 1 |
| verify | "generated queries up to date" — blind, stale dump | 0 |
| cassettes:check | "0 stale (1 checked)" — blind, frozen recording | 0 |
| unused | 6 selections, 0 unread | 0 |
| generate | "3 already up to date" — blind, stale dump | 0 |

Identical shape to change 1: queries:check is the only task that catches a
field removal, immediately, because it checks the live class rather than the
dump.

rspec, cold: both real `:in_process` examples FAILED with the same
`GraphQL query failed: Field 'price' doesn't exist on type 'Product' ...`
message as the analogous rename case; the cassette example again PASSED
(frozen, never touches the live schema).

Fix: dropped `price` from the .graphql query (neither spec asserted on price
directly, so no assertion edits needed) -> `rake graphql:schema:json` ->
`queries:check` green -> `rake graph_weaver:generate` -> `verify` green.
`cassettes:check` again went to exit 1 with the identical "checked nothing, so
it proved nothing" message before re-recording — this confirms it isn't a
fluke of change 1, it's the mechanical consequence of the query text changing
at all, breaking or not. Deleted and cleanly re-recorded the cassette this
time (learned from change 1's append surprise) -> "0 stale (1 checked)".
`unused` -> "5 selections, 0 unread" (one fewer selection now that price is
gone, otherwise unremarkable).

Committed as 922b55b.

## Change 4: bring `price` back as `Money` (decimal string scalar), registered per scalars.md

Added a real `Money` custom scalar to Catalog::Schema
(`GraphQL::Schema::Scalar` with `coerce_result` -> `value.to_s`,
`coerce_input` passthrough) and re-added `field :price, Money, null: false`.
Per docs/scalars.md's "Registering a stdlib type" table, registered as:
`GraphWeaver.register_scalar("Money", BigDecimal)` — chose BigDecimal over a
bespoke value class because "decimal string on the wire" is exactly the stdlib
row's contract (cast `BigDecimal(v)`, serialize `v.to_s("F")`, `require
"bigdecimal"` inferred automatically), and it's literally the example already
sitting commented-out in the generated initializer. Put the registration at
the initializer's TOP LEVEL, not inside `to_prepare` — getting_started.md is
explicit that `to_prepare` is only needed for registrations naming "one of
your own constants" (an app class not yet autoloaded); `BigDecimal` is a
stdlib class available immediately, so top level is correct and simpler.

First ran the full battery COLD, with the app's query file still NOT selecting
`price` (dropped in change 3, not yet added back) — this simulates the moment
right after the API ships the field, before any app code asks for it:

| task | output (condensed) | exit |
|---|---|---|
| schema:diff | same permanent refusal | 1 |
| schema:refresh | same permanent refusal | 1 |
| queries:check | "every query validates against the schema" | 0 |
| verify | "generated queries up to date" **plus a new line**: `register_scalar("Money") matches no scalar in this schema — a typo, or a registration for another schema` | 0 |
| cassettes:check | "0 stale (1 checked)" | 0 |
| unused | 5 selections, 0 unread | 0 |
| generate | "3 already up to date" **plus the same Money warning** | 0 |

New and interesting: `verify`/`generate` now print a warning about `Money`
because the registry has an entry the (still-stale) dump can't match — exactly
scalars.md's documented case ("a name it simply can't match only warns"). It
is a genuine, correct signal that something is out of step, but it is a
**warning that doesn't fail the build** (exit 0) — so on a CI gate that only
checks exit codes, this would be invisible; only a human reading the log
output would notice it. This is the first change where any task prints
something without exiting non-zero for it.

Then added `price` back to the .graphql query (adopting the new field) with
the dump still stale, to see the picture invert:

- `queries:check` -> still "every query validates against the schema", exit 0
  — it checks the LIVE class, which already has `price`, so it is right.
- `verify` -> **exit 1**: `invalid query in app/graphql/queries/products.graphql:
  6:5  Field 'price' doesn't exist on type 'Product'` — because verify
  validates the query against the STALE DUMP, which doesn't have Money/price
  yet.
- `generate` -> same failure, same reason, exit 1.

This is the sharpest confusion of the whole exercise: **queries:check and
verify can disagree about the same query, in opposite directions, depending on
which of the two changes (query file vs. schema class) has caught up with the
other** — queries:check is always right about the live resolvers, verify is
always right about what codegen would actually produce, and for an in-process
app those two answers are only guaranteed to agree right after a
`graphql:schema:json` refresh. getting_started.md says this in one sentence
("A stale dump makes verify fail on a query that is fine") but living through
both directions of it (blind on removal, falsely-failing on addition) is what
made it click.

Fix: `rake graphql:schema:json` -> `verify` (now correctly says "stale
generated queries — regenerate") -> `rake graph_weaver:generate` -> `verify`
green. Generated code confirmed matching scalars.md's own stdlib table
exactly: `require "bigdecimal"` at the top of the file, `const :price,
BigDecimal`, cast `BigDecimal(data.fetch("price"))`.

rspec: added `expect(result.products.first.price).to eq(BigDecimal("9.99"))`
to the plain example. Both real `:in_process` examples passed immediately
after regenerating. The cassette example failed with `MissingRecording`
(query text changed, same shape as changes 1 and 3) — deleted and cleanly
re-recorded (spec/cassettes/products.yml now shows `price: '9.99'`, a quoted
YAML string, confirming Money round-trips as a decimal string and not a Float
on the wire). `cassettes:check` -> "0 stale (1 checked)". `unused` -> "6
selections, 0 unread".

Committed as 1f61df8.

## CI-shaped script: `schema:diff && queries:check && verify && cassettes:check`

Ran literally, at the FINAL, fully-fixed, all-green state (after all four
changes and fixes are committed):

```
$ bundle exec rake graph_weaver:schema:diff && ... queries:check && ... verify && ... cassettes:check
/private/.../app/graphql/schema.json records no source url — it wasn't
introspected from one. Pass transport:, or rebuild it from the schema class
that produced it.
FINAL CI SCRIPT EXIT: 1
```

**This script never passes for this app, ever, in any state** — `schema:diff`
is an unconditional refusal for a schema whose dump was built from a live
class rather than a URL (documented, expected, not a bug), and `&&` means the
first stage's exit 1 short-circuits the whole line: `queries:check`, `verify`
and `cassettes:check` never even run. As literally specified, this is not a CI
gate, it's a permanently red build for any in-process app — which is a trap
for exactly the audience getting_started.md's own in-process section targets.

Dropped `schema:diff` (the correct fix for this topology, per
getting_started.md's own words: "`schema:diff` and `:refresh` are for servers
you don't own") and re-ran `queries:check && verify && cassettes:check` at the
same final state: all three ran, all printed their success line, script exited
0.

Then simulated mid-drift by editing Catalog::Types::ProductType back to `sku`
(schema drift with no corresponding app fix — the same shape as change 1
before its fix, engineered on top of the finished repo and reverted
immediately after) and re-ran the practical 3-stage script:
`queries:check` failed first (`Field 'stockCode' doesn't exist on type
'Product'`), script exited 1 before `verify`/`cassettes:check` ran. Confirmed
the revert left the working tree byte-identical to HEAD before continuing.

Verdict: the practical, in-process-appropriate version of this script
(`queries:check && verify && cassettes:check`) exits non-zero at exactly the
right moments — 0 when the tree is genuinely in sync, 1 the moment the schema
drifts out from under a query. The script as literally given in the task,
`schema:diff && ...`, exits non-zero unconditionally and would need
`schema:diff` dropped (or replaced with `graphql:schema:json` diffed against
git, which nothing here does automatically) before it could gate anything for
this app's topology.

## Doc searches that found nothing

Navigating via the README's own links ("the schema keeps itself honest" ->
getting_started.md#5-verify-in-ci, testing.md, cassettes.md, scalars.md)
answered every question that came up during this exercise without needing
free-text search — worth noting as a design point in its own right (the docs
are cross-linked well enough that grep wasn't the tool for the job here). To
double check for the honest "found nothing" list, ran `rg -il` across
`docs/` + `README.md` for terms a newcomer chasing a CI setup or a
Ruby-ecosystem convention might reasonably type:

- "GitHub Actions" -> no matches (no worked CI-config example anywhere in the
  docs; the reader is left to translate "five rake tasks" into whatever CI
  system they use)
- "CI script" -> no matches (same gap — the closest is getting_started.md's
  "5. Verify in CI" table, which is prose + a table, not a runnable script)
- "docker" -> no matches
- "rubocop_todo" -> no matches (getting_started.md mentions `.rubocop.yml`'s
  `AllCops: Exclude:` but never the todo-file convention)
- "money gem" -> found (scalars.md, exactly where expected — the "honest hard
  case" section)
- "schema:refresh URL" -> found (getting_started.md)
- "stale dump" -> found (getting_started.md, real_world.md)

## End state

- App: /tmp/claude/graph_weaver/junior-app-9, git log: d9f66c5 (init) ->
  0635a79 (sku->stockCode) -> bc89a03 (+PREORDER) -> 922b55b (-price) ->
  1f61df8 (+price as Money). Working tree clean.
- Never opened lib/ or spec/ in the gem repo itself — every behavior was
  learned from README.md + docs/getting_started.md, testing.md, cassettes.md,
  scalars.md. The one moment closest to "stuck" was the Zeitwerk NameError on
  the very first spec run, which was app-code's own mistake (a plain constant
  in a file Zeitwerk expected to define a class/module), not a graph_weaver
  question — resolved by reasoning about autoloading, no doc or source dive
  needed.
