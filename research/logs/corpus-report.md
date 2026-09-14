# Lane report — public schema corpus sweep

Branch `worktree-agent-acd01563ae166f51e`, off main `4fd16d2`. Three commits,
each gated with the full suite + `srb tc` + `bin/generate` + two random rspec
seeds + `bin/round-trip -c 2000` + `bin/federation-diff` + `examples/federation.rb`.

- `5f2e20f` Read a corpus scalar off the registry, not off its name
- `252d66e` Refuse an input type named after a constant the module owns
- `52526e7` Say why the `__typename` inside each member doesn't dispatch
- `4f43755` Call execute with the kwarg a variable really becomes

Cached dumps and scratch live in `/tmp/claude/graph_weaver/corpus/`; nothing
was added to the repo.

## The corpus

23 schemas: 20 newly gathered, plus the three the library had been tested
against (GitHub, PokeAPI, Countries). Everything was read by
`GraphWeaver::SchemaLoader.load`; the introspected ones were fetched with
`GraphWeaver::Transport::HTTP` + `SchemaLoader.introspect` (so the loader and
the transport got a workout too), the SDL ones with `curl` from the project's
own repo.

| schema | source | fetched | types | objects | inputs | enums | result |
|---|---|---|---|---|---|---|---|
| gitlab | gitlab.com/api/graphql | introspect | 4410 | 2686 | 879 | 469 | clean |
| pokeapi | beta.pokeapi.co/graphql/v1beta *(fixture)* | introspect | 4441 | 1997 | 2262 | 177 | clean |
| shopify-admin | raw.githubusercontent.com soenneker/soenneker.shopify.graphqlclient `graphql.schema` | curl (SDL) | 2997 | 1790 | 525 | 569 | clean |
| github *(fixture)* | api.github.com/graphql | dump in repo | 1782 | 1010 | 402 | 253 | clean |
| linear | github linear/linear `packages/sdk/src/schema.graphql` | curl (SDL) | 1285 | 717 | 399 | 129 | **3 bugs** |
| wpcontent (WPGraphQL) | content.wpgraphql.com/graphql | introspect | 924 | 542 | 177 | 63 | clean |
| universe | www.universe.com/graphql | introspect | 512 | 278 | 173 | 48 | **1 bug** |
| kiwi.com | api.skypicker.com/umbrella/v2/graphql | introspect | 380 | 217 | 53 | 58 | clean |
| kitsu | kitsu.io/api/graphql | introspect | 336 | 185 | 58 | 50 | clean |
| anilist | graphql.anilist.co | introspect | 196 | 133 | 10 | 42 | clean |
| opentargets | api.platform.opentargets.org/api/v4/graphql | introspect | 156 | 142 | 2 | 6 | clean |
| spacex | spacex-production.up.railway.app | introspect | 108 | 68 | 20 | 8 | clean |
| hivdb (Stanford) | hivdb.stanford.edu/graphql | introspect | 80 | 53 | 6 | 15 | clean |
| ehri | portal.ehri-project.eu/api/graphql | introspect | 69 | 52 | 0 | 4 | clean |
| swapi | swapi-graphql.netlify.app/graphql | introspect | 66 | 58 | 0 | 2 | clean |
| graphqlzero | graphqlzero.almansi.me/api | introspect | 56 | 26 | 21 | 4 | clean |
| barcelona mobility | barcelona-urban-mobility-graphql-api.netlify.app/graphql | introspect | 47 | 28 | 5 | 3 | clean |
| tcgdex | api.tcgdex.net/v2/graphql | introspect | 32 | 20 | 5 | 2 | clean |
| trygql-web | trygql.formidable.dev/graphql/web-collections | introspect | 28 | 17 | 1 | 3 | clean |
| trygql-basic | trygql.formidable.dev/graphql/basic-pokedex | introspect | 20 | 12 | 0 | 3 | clean |
| countries *(fixture)* | countries.trevorblades.com/graphql | introspect | 23 | 12 | 4 | 2 | clean |
| hasura-poll | realtime-poll.hasura.app/v1/graphql | introspect | 12 | 7 | 0 | 2 | clean |

**Fetches that failed** (dropped after one retry, per the brief's time box):
Artsy metaphysics and Contentful disable introspection or need a token; Monday,
Bitquery, swop.cx, Digitransit and Kitsu-adjacent endpoints want credentials;
Saleor's demo, ghibli.dev, wpgraphqldemo.com, tmdb.apps.quintero.io,
api.everbase.co, graphql.camara.leg.br, api.fabricjs.com and play.dgraph.io are
gone (DNS or 404/405); react-finland fails the TLS handshake; api.mocki.io wants
a subscription; api.apis.guru/v2/graphql is 401. SWAPI and Saleor answer a 301/308
that the transport (correctly) does not follow — `swapi-graphql.netlify.app/graphql`
works, the `.netlify/functions/index` path in the brief redirects.

## What was run

Per schema, in order: `SchemaLoader.load` (all 23 load), then
`bin/round-trip <dump> -c 100` at seeds 1, 101 and 201, then `--hostile -c 100`
at seed 1 — 92 runs (the three cached fixture dumps included), re-run end to
end after every fix; the final pass is 92 green. Plus a wider pass at seeds
301/401/501 and a hostile pass at 301 on the twelve largest: 48 more, all
green — and it was that pass, not the first three seeds, that found the fourth
bug. Every schema in the table is clean in every mode as of `4f43755`.
Real-query passes:

| corpus | operations | trips | refused | failures |
|---|---|---|---|---|
| Linear SDK `_generated_documents.graphql` (split per operation, fragment closure resolved) | 250 | 1356 | 144 | 0 |
| GitLab `app/assets/**/*.query.graphql` (first 120; 62 use webpack `#import` and don't stand alone) | 58 | 834 | 14 | 0 |
| the repo's own `examples/github/queries` | 3 | 590 | 0 | 0 |

## Failures, triaged

### 1. Harness — a custom scalar read off its name (`5f2e20f`)

GitLab and universe both declare `scalar Time`; Linear declares
`DateTimeOrDuration`. Two separate defects, one root cause — the harness
treating a GraphQL name and a Ruby cast type as one namespace.

**(a) `Responder.illegal` / `scalar_value`.** The legal/illegal tables key their
custom-scalar rows by the *Ruby* type a registration casts to (`"Time"`,
`"Date"`, `"Integer"`), and the lookup asked the GraphQL name first. A schema
whose custom scalar happens to be *called* `Time` was therefore spoiled as
though it had a codec, while generated code treated it — correctly — as
`T.untyped` pass-through and accepted the value. 6 failures across universe
(2) and GitLab (4), reported as "accepted `true` at …createdAt". The lookup now
asks the Ruby type, with a built-in's own name allowed to refine it (`ID` is a
`String` the table says more about). Watched failing as
`round_trip_spec.rb` "leaves one nobody has registered alone".

The first attempt at this broke `ISO8601Date`/`ISO8601DateTime` — built-in
names with no row of their own, reachable only through the Ruby type. Caught by
re-running GitLab, pinned by "sends a legal value for a built-in spelled by its
long name".

**(b) `bin/round-trip`'s stand-in registrations.** They spelled out
`serialize: :iso8601` for a timestamp scalar. `Time#iso8601` takes no argument
here and drops the sub-second — while the harness's independently-computed wire
expectation keeps it (`Coerce.timestamp`, which is what the library's own
built-in `DateTime` registration uses, and what docs/scalars.md tells users to
use). 10 failures per seed on Linear, all `expected …30.500000Z, sent …30Z`.
They now name the class and stop, which is the docs' own advice. A bare `Time`
joined the timestamp spellings so those schemas exercise a codec at all — which
is what then found nothing further on GitLab, at 5× the runtime.

The registrations moved from `bin/round-trip` into
`RoundTrip.register_scalars!` so the suite can hold them to it; the bin file had
been the only copy and was untested.

### 2. Codegen — an input type named after a constant the module owns (`252d66e`)

`MODULE_RESERVED` (`Result`, `QUERY`, `Representations`) guards an enum and a
hoisted fragment. Nothing held an **input struct** to it:

- `input Result` emitted `class Result < T::Struct` **twice**. The second
  reopened the first, and one struct then answered for both the variable and
  the response — `execute`'s sig said `Response[Result]` where `Result` was
  also the input type, `cast_data` cast the response into it, and it loaded
  without complaint. A silent wrong answer in code that looks authoritative.
- `input QUERY` raised a bare `TypeError: QUERY is not a class`, Ruby
  complaining about the document heredoc.

Found by static sweep, not by the fuzzer: no schema in the corpus declares such
an input (SpaceX has an *object* named `Result`, which is unaffected — a result
class is named for the response key, not the type). Minimal repro is three
lines of SDL; specs in `codegen_spec.rb`.

### 3. Harness — `execute` called with a kwarg the library never declares (`4f43755`)

Linear declares `Query.comment(hash: String)`. The harness built its kwargs
with `Codegen.prop_name`, which renames `hash` to `hash_`, and `execute` raised
`ArgumentError: unknown keyword: :hash_` — blaming generated code for the
harness's spelling. Two failures per 100 cases on Linear, and only at seed 501:
the first three seeds never drew that field.

The rename exists so a **prop** can't shadow a method its struct answers. An
execute kwarg shadows nothing (`build_variables` uses a plain `underscore`, and
refuses only a Ruby keyword or `client`/`variables`), so the harness now does
the same. The reserved-name fixture carried such names only as input-object
fields, where `prop_name` is right; it now takes them as root arguments too —
the third place such a name lands and the one the rename does not reach.

### 4. Codegen message — the `__typename` you selected six times (`52526e7`)

Not a round-trip failure; a refusal that misleads. **36 of 250 published Linear
SDK operations** are refused for a union without `__typename`, and every one of
them selects it — once inside each member fragment, never on the union itself.
"Select `__typename` on `AgentActivityContent`" is unhelpful advice to someone
looking at six of them.

The rule is right and unchanged: `from_h` reads the tag before it knows which
member is live, and a member the query never named would carry none at all.
Only the message moves, and only when that is the shape in front of it. Stated
in `docs/generated_modules.md` too.

## Reserved-name hit list

Every coordinate in the 23 schemas that `Codegen.prop_name` renames — **11
coordinates, 4 distinct props, 5 schemas**. The rule fires, rarely, and the
renames it picks are all ones a user would want.

| prop | coordinates |
|---|---|
| `display_` | hivdb `BoundSubtype.display`, `DrugResistanceAlgorithm.display`, `HIVBoundSubtype.display`, `Strain.display`; shopify-admin `OrderRisk.display` |
| `method_` | gitlab `StatusAction.method`, `VulnerabilityRequest.method`; opentargets `VariantEffect.method` |
| `class_` | spacex `Ship.class` (field), `input ShipsFind.class` |
| `object_id_` | anilist `ModAction.objectId` |

Arguments are deliberately **not** in that list: a variable becomes an execute
kwarg, where `hash:` is legal Ruby. Linear's `Query.comment(hash:)` and
`Query.customerNeed(hash:)` therefore keep their spelling — which is what the
fourth commit is about; the harness had been renaming them.

The kwarg rules that *do* fire on arguments: **7 GitLab root arguments named
after Ruby keywords** — `Query.issues(not:, or:, in:)`,
`Query.mergeRequests(not:, or:)`, `Query.groups(not:)`,
`Query.adminGroups(not:)`. These refuse only when the user names the variable
after the argument, which is the natural thing to do:
`variable $not would become the kwarg 'not:', which generated code can't
declare (a Ruby keyword) — rename the variable`. `$notFilter` generates.
Correct, and the message is the fix.

Zero hits on `RESERVED_KWARGS` (an argument named `client` or `variables`).
Zero enum or input type names camelizing onto `MODULE_RESERVED`; one **object**
type does (spacex `Result`), which the response-key naming rule makes harmless.

Two neighbouring rules, same sweep:

- **Enum values differing only in case: 72, all GitLab.** `MergeRequestSort`,
  `ProjectSort`, `TimelogSort`, `TodoSort`, `EpicSort` and 20-odd more carry
  both `created_asc` and `CREATED_ASC` (legacy lowercase aliases). Both become
  the constant `CreatedAsc`, so generation refuses:
  `enum MergeRequestSort values CREATED_ASC and created_asc both become the
  constant CreatedAsc — map the enum onto one of yours:
  register_enum("MergeRequestSort", YourEnum)`. Correct, actionable, and the
  message is good — but worth knowing that **a GitLab user meets it on their
  first sorted query**, because `sort:` is on most of GitLab's connections.
  Refusing beats renaming one of the two: an enum constant is what the caller
  types.
- **Fields underscoring onto one prop: 7, all universe.** `AccountBalance` has
  both `totalBalance` and `total_balance`; likewise `CustomReport` and
  `Withdrawal` for `createdAt`/`created_at`. Harmless unless a query selects
  both, which is when the existing refusal fires.

## Investigated and left alone

- **A false refusal the fuzzer finds, 1 case in 100 (kiwi, seed 85).** A
  response key reached twice, both occurrences guarded (`@skip(if: $g)` at the
  root and `@include(if: $g)` through a fragment), each selecting `__typename`.
  Whenever the key is present at all *some* occurrence applies, so `__typename`
  is always there — but `merged_selections` wraps every guarded occurrence's
  sub-selections in a `GUARDED` inline fragment before `dispatchable_typename?`
  sees them, so none reads as unconditional and the union is refused. Safe
  (refuse rather than guess) and conservative. Accepting it means a second way
  to satisfy one rule — "…or on every guarded occurrence of the key" — and the
  occurrence structure has to be threaded past a merge that deliberately
  flattens it. Left as is; recorded here so it isn't rediscovered as a bug.
- **kiwi's 32% refusal rate** at `-c 100` is three documented refusals, all
  fuzzer-shaped: 17 unions without `__typename`, 14 all-`@skip` narrowed
  fragments, 1 the case above. Not a schema-shape problem.
- **The fuzzer builds queries the spec's field-merging rule forbids.** GitLab
  runs emit 24-46 graphql-ruby warnings per 100 cases —
  `mismatched types in this query: Boolean! (at 1:1642) vs. Int! (at 1:1692)`,
  with "will return an error in future GraphQL-Ruby versions". They pass
  `schema.validate` today, so codegen is genuinely exercised on them; when
  graphql-ruby promotes the warning, those cases will start failing validation
  and be counted `undraftable` — coverage will shrink with nothing said. Worth
  a fuzzer fix (don't reuse a response key across type conditions whose field
  types differ) before that lands. Only GitLab is big enough to hit it.
- **`Query._`** (graphqlzero declares a field literally named `_`) generates and
  round-trips: `_` is a legal prop and is not in `RESERVED_PROPS`.
- **Federated / supergraph SDL** — no public supergraph dump found that
  introspects or is published; the fixture supergraph remains the only coverage.

## Was three schemas enough?

No, and the shape of what it missed is the point. Every bug this sweep found
came from a name or a spelling the three fixtures happen not to have: a custom
scalar *called* `Time`, a timestamp scalar *not* called `DateTime`, an input
type named after one of the library's own constants, a union tagged per member
instead of at the top. The three fixtures are structurally rich — GitHub has
the interfaces and the relay shape, PokeAPI the Hasura input explosion — but
they are three points in name-space, and name-space is where a code
*generator* lives. Twenty more schemas cost about two hours, found two harness
defects that were silently failing real schemas, one codegen path that produced
authoritative-looking wrong code, and one error message that misleads 14% of a
major SDK's published operations. It also produced the first real measurement of
the reserved-name rule's hit rate (13 coordinates in 23 schemas), which had been
argued about from first principles. The corpus should be cheap to re-run — the
fetch scripts and the sweep driver are in `/tmp/claude/graph_weaver/corpus/`,
and everything but the dumps is a dozen lines.
