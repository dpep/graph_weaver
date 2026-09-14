# Senior L — the supergraph owner (platform expert)

Main at 49b9209. App: senior-app-L (copied from senior-app-C-fix, Gemfile
repointed at the read-only checkout). 4 real apollo-federation-ruby
subgraphs: accounts, products, reviews, inventory. federation_harness/ has
node + @apollo/composition installed (no `rover` binary on this machine —
using `@apollo/composition`'s `composeServices` directly as the composition
oracle, same as senior C/F/H's compose.mjs and the same engine `rover
subgraph check`/`compose` shell out to).

08:00 - read brief-senior-L.md + brief-senior4-common.md.
08:00-08:10 - skimmed senior-log-C.md (planner matrix, gateway parity —
nearest to "rover-shaped workflow" and federation:diff) and senior-log-H.md
(federation directives — nearest to contracts/@tag territory, though H
didn't actually touch @tag/contracts). Confirmed via CHANGELOG.md/git log
that everything C/F/H found is fixed on main (progressive @override refusal,
@fromContext single-subgraph refusal, @key-list representations, @link
aliasing, retired-subgraph `unplaced`, shape-diff in federation:diff).
08:10-08:20 - read docs/federation.md in full (826 lines). No mention of
@tag or contracts anywhere in it.
08:20-08:30 - read lib/graph_weaver/federation.rb (Drift) and
lib/graph_weaver/internal/schemas.rb (Schemas.loaded) — confirms Drift's
`schemas:`/`subgraphs:` param always resolves to a `GraphQL::Schema`
*class* (`Internal::Schemas.loaded` walks `GraphQL::Schema.subclasses`);
there is no path that hands it a subgraph SDL file/string directly.
08:30 - baseline: bundle install against the real checkout, rspec 23/23
green, federation:diff clean (4/4), federation:subgraphs clean.

## rover-shaped workflow: subgraph changes composition accepts

08:35 - `tmp/l/lib.rb` — helper that composes {name=>sdl} via the app's own
`federation_harness/compose.mjs` (`@apollo/composition`, no `rover` binary on
this machine — same engine `rover subgraph check`/`compose` shell out to).
`tmp/l/baseline.rb` confirms recomposing the app's own 4 real subgraphs
byte-matches the checked-in `supergraph.graphql`.

08:35-08:50 - **field removed** (`tmp/l/scenario_field_removed.rb`).
First attempt picked `Product.popularity` and got a false read: `products`
still declares `popularity` as dead code (the pre-`@override` owner), so
removing reviews' copy doesn't remove the field from the graph at all — it
just reverts ownership to `products`, and every check (rightly) reported
clean. Real finding in its own right, filed below. Redid it against
`Warehouse.supportContact` (owned by exactly one subgraph, no `@override` in
play):
- composition: **accepted** (removing a field is always composable).
- `federation:diff` against the **old, not-yet-recomposed** dump, with an
  explicit `subgraphs:` map pointing "reviews" at the new (SDL-loaded, via
  `GraphWeaver::SchemaLoader.load`) schema: catches it immediately as
  **stale** — `Warehouse.supportContact (reviews)` — before any recompose,
  before any client is touched.
- `queries:check` against the **old** dump: clean (expected — the dump
  hasn't moved yet, matches docs' stated separation of duties).
- Recompose (accepted, produces the new supergraph) → `queries:check` against
  the **new** dump: catches `warehouse.graphql` — `Field 'supportContact'
  doesn't exist on type 'Warehouse'`.
- `rake graph_weaver:generate`-shaped codegen against the new dump: **raises**
  `GraphWeaver::QueryValidationError` naming the same line — a hard,
  loud failure, not a silent bad build.
- Trying the SAME `federation:diff` call but via **auto-detection** (no
  `subgraphs:` given) in the same process, where the real unmodified
  `Reviews::Schema` is *also* still loaded alongside the SDL-loaded
  replacement missing the field: reports **clean, `drift? => false`** — see
  Finding below.

08:50-09:00 - **`@inaccessible` added to a field a client currently selects**
(`tmp/l/scenario_inaccessible.rb`, same `Warehouse.supportContact`, still
selected by `warehouse.graphql`). Composition accepts it; composed SDL:
`supportContact: String! @inaccessible @join__field(graph: REVIEWS)`.
- `federation:diff`, old dump: clean (expected — nothing about the routing
  table changed yet).
- `federation:diff`, **recomposed** dump: **still clean, `drift? => false`**
  — confirmed empirically, matches docs' explicit "directives... are not
  read" caveat (the routing table still `declares?` the coordinate).
- `queries:check` against the recomposed dump: **catches it** —
  `Field 'supportContact' doesn't exist on type 'Warehouse'` — because
  `SchemaLoader.load` (what `check_queries`'s default schema derivation uses)
  strips `@inaccessible` for the client-facing schema, while the routing
  table `Federation::Drift` reads does not. Confirmed the split directly:
  `table.declares?('Warehouse','supportContact') => true`,
  `client_schema.types['Warehouse'].fields.key?('supportContact') => false`.

09:00-09:15 - **argument made required (no default)** and **enum value
removed** (`tmp/l/evo/arg_required_check.rb`, `enum_removed_check2.rb`,
standalone two-version schemas, plain not federated — the codegen/validation
mechanics tested here are identical whether the schema is a subgraph or not).
- New required arg, no default: `SchemaDiff` reports
  `Query.widget(verbose:) argument added: Boolean! — required, breaking: true`;
  `queries:check`/`generate` both catch every query that calls the field
  without it (`Field 'widget' is missing required arguments: verbose`).
- Enum value removed: `SchemaDiff` reports
  `Status.ACTIVE enum value removed, breaking: true`. **But `queries:check`
  and `generate` are both clean** for a query that only *selects* the
  enum-typed field (`status`) without literally naming `ACTIVE` anywhere in
  the document — GraphQL query validation has nothing to check a value
  against unless the value appears in the document. Confirmed the client-side
  dead code this leaves behind is inert, not dangerous: a v1-generated
  `GraphQLTypes::Status.deserialize("ACTIVE")` still constructs
  `#<GraphQLTypes::Status::Active>` fine — it's just that a live v5 server can
  never send `"ACTIVE"` again, so the constant simply stops being reachable.
  `schema:diff` is the ONLY graph_weaver check that surfaces this at all.

09:15-09:25 - **type narrowed** — reasoned through rather than run standalone
(the mechanism is identical to the two cases just confirmed): tightening an
argument's nullability (`[String]` → `[String!]`, or an input field
nullable → non-null) is caught the same way as "argument made required",
because a query's own variable-type declarations are checked against the
argument type at validation time — a variable typed `$x: [String]` used
against a `[String!]` argument fails GraphQL validation itself, so
`queries:check`/`generate` catch it exactly like the required-argument case.
The one case that's NOT caught by anything static: an already-compatible
query sending a `nil` array element at **runtime** (not in the document) —
but that's ordinary GraphQL input validation at request time (a normal
error response), not a graph_weaver gap.

09:25-09:35 - **scalar changing its serialization, `String` → custom scalar**
(`tmp/l/evo/v2_scalar.graphql`, `silent_scalar.rb`) — the session's sharpest
finding, filed below. `SchemaDiff` correctly flags
`Widget.price String! -> Currency!` as breaking (confirmed via
`diff_check.rb`), so the safety net exists — but if a client running v1's
generated code (typed `const :price, String`) receives a v2 payload where
the new `Currency` scalar happens to STILL serialize as a JSON string (just
reformatted, `"$19.99"` instead of `"19.99"`), sorbet-runtime raises
**nothing** — a `T::Struct` field typed `String` accepts any String, however
it's formatted. Repro: `PriceStruct.new(price: "$19.99")` succeeds silently,
and `"$19.99".to_f => 0.0` downstream. GraphQL's/Sorbet's structural typing
(is it *a* String) can't see a scalar's semantic format changing while its
JSON primitive kind stays the same — the ONLY thing standing between a
supergraph owner's teams and this is whether the client actually reads and
acts on `schema:diff`'s `breaking: true` line before it ships.

09:35-09:45 - **@deprecated then removed**
(`tmp/l/evo/v1.graphql`'s `cost: String @deprecated(reason: "use price")`,
generated via `gen_v1.rb`). Generated code for `cost` (`const :cost,
T.nilable(String)`) carries **zero trace** of the deprecation — no comment,
no Sorbet-level annotation, nothing distinguishing it from any other
nilable field. The only place a deprecation surfaces at all is
`schema:diff`'s one-time report line (`lib/graph_weaver/schema_diff.rb:226`,
`"deprecated: <reason>"` / `"no longer deprecated"`, confirmed present at
`docs/getting_started.md:321`) — a client team that isn't running
`schema:diff` on a schedule, or is but doesn't act on that one line among
many, gets no durable signal in the codebase that a field it's using is
going away, right up until the day it's removed and `generate` refuses.
Filed as a finding below (additive: a `# deprecated: <reason>` comment above
the generated `const`/method costs nothing and would persist).

09:45-09:55 - **safe evolution, confirmed as a set** (`tmp/l/evo/v6_safe.graphql`,
`safe_check.rb`): a new required argument WITH a default, a union gaining a
member, a type newly implementing an interface, and a wholly new root field
— `SchemaDiff` correctly marks every one of these `breaking: false`,
`queries:check` stays clean, and regenerating produces **byte-identical**
output for the untouched query (`diff generated/get_widget_query.rb
generated_v6/get_widget_query.rb` — empty). A client that never regenerates
against v6 is unaffected in every observable way. This is exactly what
"additive evolution never surprises" should look like, and it's what
actually happens here.


## Contracts and variants

10:00-10:20 - No `rover` binary on this machine and no GraphOS Studio access,
so no real `--contract` build either; hand-filtered with `@tag` exactly as
the brief and docs/federation.md itself suggest ("Apollo contracts also pair
`@tag` + `@inaccessible` to build filtered API variants"). Built two real
composed supergraphs from the app's own 4 subgraphs
(`tmp/l/scenario_contracts.rb`): **internal** (reviews' `User.supportTier`
tagged `@tag(name: "internal")`, otherwise untouched) and **public** (same
tag, plus `@inaccessible` on the same field -- the shape a real contract
build's filtered output has).
- Generating `dashboard.graphql` (selects `supportTier`) against **internal**:
  succeeds.
- The SAME query against **public**: `generate!` **raises**
  `QueryValidationError` naming `supportTier` -- codegen refuses rather than
  silently producing a client that can't work. Correct, matches "refuse
  rather than guess."
- A genuinely public-shaped client (the query with `supportTier` dropped)
  generated against **public**, then `check_queries`'d against **internal**:
  clean -- a narrower client is always safe against the superset it's not
  actually deployed against, confirmed rather than assumed.
- **The risk that's real**: nothing here cross-checks "what I generated
  against" against "what I'm actually calling." `check_queries(schema:
  internal, queries: app/graphql/queries)` stays green forever even if the
  app is actually deployed against the **public** endpoint -- that mismatch
  only ever surfaces as a live 400 in production, because `verify`/
  `queries:check`/`generate` all take the schema source as a given rather
  than reading it from the client's own `client:`/deploy target. Filed below.
- `federation:diff` (routing-table-based) cannot tell the two variants
  apart at all -- both report "matches the schemas here" -- consistent with,
  and a second confirmed instance of, the same `@inaccessible`-is-a-directive
  gap found above for the field-removal scenario.

10:20-10:35 - **Multiple supergraph files in one app** (`tmp/l/scenario_multi_graph.rb`).
Declared two named graphs (`GraphWeaver.graph`, per
`docs/getting_started.md#more-than-one-schema`) -- `:internal` reusing the
app's existing `app/graphql/queries` -> `app/graphql/generated` (wraps
rather than orphans the app's default graph, as the docs require) and
`:public` pointed at a second, trimmed query directory and its own output.
`GraphWeaver.generate!` handled both correctly, writing five files under the
app's usual output and one under the public one. So **yes, there is a
spelling** for "two dumps, one app" -- but it's the general multi-**graph**
mechanism (each variant needs its own `queries`/`output`, and a `namespace`
the moment there's any risk of a name colliding), not something
contract-variant-specific; nothing in `GraphWeaver.graph` or the docs frames
it as "here's how you run a contract pair." A team gets there only by
recognizing that a schema *variant* is, mechanically, just another graph.
- **A sharper, confirmed asymmetry**: `federation:diff`/`:subgraphs`/`:coverage`
  all honor `SUPERGRAPH=` for a one-off override (their own `desc` strings
  say so). `queries:check`/`verify`/`generate` have **no equivalent** -- the
  rake task calls `GraphWeaver.check_queries` with no arguments, which reads
  only the app's declared graphs. Confirmed directly:
  `SUPERGRAPH=tmp/l/public.graphql rake graph_weaver:queries:check` prints
  **"every query validates against the schema"** -- the exact same result as
  not setting it at all, even though `dashboard.graphql` selects a field the
  named public supergraph doesn't have. **Finding filed below**: a lever
  that means something on three tasks and silently does nothing on three
  others in the same task family is exactly the kind of surprise a
  consistent CLI surface exists to prevent.

## The federation tasks as a supergraph owner would use them

10:35-10:50 - **Is there a way to run federation:diff against subgraph SDL
files rather than loaded Ruby classes?** (`tmp/l/scenario_sdl_only_subgraph.rb`)
Yes, and it works cleanly, but it's undocumented as a pattern. Wrote the
"accounts" team's federation SDL to a plain `.graphql` file (stand-in for
`rover subgraph fetch`/`_service { sdl }` output -- exactly what a non-Ruby
subgraph hands you), loaded it with `GraphWeaver::SchemaLoader.load(sdl_text)`
(a resolver-less `GraphQL::Schema` -- confirmed
`sdl_only_accounts.query.fields["me"]` is a plain `GraphQL::Schema::Field`
with no Ruby method behind it), and passed it explicitly:
`Federation::Drift.new(subgraphs: {"accounts" => sdl_only_accounts, ...})`.
Reported clean, checked 4 of 4 -- genuine drift detection against a subgraph
this process could never execute a single resolver for, because `Drift`
never calls one. `docs/federation.md`'s own line for `subgraphs:` says it
"is the same map `Testing::Router` takes," and Router's docs stress "your
resolvers run, which is the whole point" -- true for Router, and it reads as
implying a live, resolver-backed schema is what belongs in that map. For
`Drift` specifically that's not required at all, and this is the actual
answer to "what does a non-Ruby subgraph look like to every task": to
`Testing::Router` it's `:fake` or `absent` (well documented, already
correct); to `Federation::Drift` it can be a first-class, fully-compared
citizen via `SchemaLoader.load` on their published SDL -- a materially
different, more useful answer that the shared phrasing hides. Filed below
as a docs finding -- additive, no code change.

10:50-10:55 - **Retired-subgraph and shape confirmations** (already fixed on
main per senior C's finding + `git log` `b463b6b`/`cc71113`;
`tmp/l/scenario_retired_and_shape.rb` re-confirms rather than re-derives):
recomposing without `inventory` while `Inventory::Schema` stays loaded here
reports "checked 3 of 3" (correctly no drift -- inventory really is gone)
plus `drift.unplaced => ["Inventory::Schema"]`, the documented warning.
Retyping `Warehouse.code` `String!` -> `ID!` in `products` without
recomposing reports the `shape` section verbatim as docs describe:
`Warehouse.code (products): String! in the supergraph, ID! here`. Both
clean; no time spent beyond confirming main behaves as senior C's fix and
the docs both say.

## Docs for the six teams

11:00-11:15 - Re-read docs/federation.md and docs/getting_started.md#5-verify-in-ci
specifically as "what would I hand to five other teams."
- **Zero mentions of `@tag` or contracts anywhere in federation.md's 826
  lines**, apart from one parenthetical in the `@inaccessible` section:
  "(Apollo contracts also pair `@tag` + `@inaccessible` to build filtered API
  variants.)" No worked example, no note on how `federation:diff`/
  `queries:check`/the multi-graph mechanism behave under a contract split --
  all three behaviors this session had to derive by hand (see above). Given
  contracts are an ordinary feature at any multi-team Apollo shop, this is
  the single biggest gap for a supergraph owner specifically.
- **The one worked CI example in the whole doc set doesn't include
  `federation:diff`.** getting_started.md's "5. Verify in CI" table lists
  five CI questions and says the fifth applies "only on a federated graph" --
  but the GitHub Actions YAML directly below it (the only complete workflow
  example anywhere in docs/) has four `bundle exec rake` steps and
  `federation:diff` isn't one of them. A team on a federated graph that
  copies this YAML (which is exactly what a workflow-example block is for)
  ships without the one CI gate this whole session has been confirming does
  real, load-bearing work. Confirmed by re-grepping docs/federation.md for
  "yml"/"workflow"/"jobs:" -- nothing; there is no complete federated-CI
  example anywhere in the docs.
- **No role map.** federation.md's opening line says it's for "a client of a
  federated graph, a subgraph in one, or both" but every section after that
  is written in one voice for one generic reader. A client team that "never
  composes anything" (the brief's phrase, and four of six teams in this
  org) has to read past ~150 lines of `rover supergraph compose`/
  `orphan_types` ordering traps/federation-version pinning -- pure
  supergraph-owner concerns -- before reaching "Generating against a
  supergraph," the one section that's actually theirs. Nothing marks which
  half of the document is "you, if you publish a subgraph" versus "you, if
  you only call the gateway."
- What IS there and is genuinely owner-only, correctly: "Producing a
  supergraph" (rover config, `orphan_types` ordering), "Has the supergraph
  been recomposed?" (federation:diff internals), "Composition versions"
  territory is absent as a topic but was well covered empirically by
  senior H. These read as written for the person running composition, which
  is accurate -- they just aren't marked as such for the reader who isn't.

## Final check

11:15 - app restored to baseline (the multi-graph regeneration test
regenerated app/graphql/generated/* against the internal-variant supergraph
mid-session; restored by regenerating against the real committed
supergraph.graphql). Final: rspec 23/23, `verify` up to date,
`federation:diff` clean 4/4. Session end.

## Time accounting
- 08:00-08:30 (30m): read briefs, skim senior-log-C.md/H.md, confirm fixes on
  main via CHANGELOG/git log, read docs/federation.md in full, read
  lib/graph_weaver/federation.rb + internal/schemas.rb, set up senior-app-L,
  baseline green.
- 08:35-09:00 (25m): rover-shaped workflow -- field removed (incl. one
  15-minute false start on `popularity` before switching to
  `supportContact`), `@inaccessible` added.
- 09:00-09:45 (45m): schema evolution the spec allows -- argument
  required, enum removed, type narrowed (reasoned, not separately run),
  scalar serialization change (the session's sharpest finding), deprecated
  field.
- 09:45-09:55 (10m): safe evolution confirmed as a control group.
- 10:00-10:35 (35m): contracts/@tag hand-filtering, multi-graph/SUPERGRAPH=
  asymmetry.
- 10:35-10:55 (20m): SDL-only subgraphs for federation:diff, retired-subgraph
  and shape re-confirmations.
- 11:00-11:15 (15m): docs review for the six-team audience.
- 11:15-11:20 (5m): final green check, write-up.
- Total: ~3h.

## Times I read lib/ or spec/, and why
- `lib/graph_weaver/federation.rb` (`Federation::Drift` in full) -- to find
  exactly what `comparable`/`identifying`/`record_stale`/`record_uncomposed`
  compare (coordinate presence + type signature only, confirmed against the
  `@inaccessible` and multi-schema-candidate findings precisely rather than
  guessing from the docs prose alone).
- `lib/graph_weaver/internal/schemas.rb` (`Schemas.loaded`/`defines?`/
  `signature`) -- to confirm auto-detection walks `GraphQL::Schema.subclasses`
  by name, which is what predicted (and then confirmed) that an SDL-loaded
  schema assigned to a Ruby constant is NOT actually excluded from
  auto-detection the way its own comment implies for a truly anonymous one.
- `lib/graph_weaver/schema_loader.rb` (`load`/`build_sdl`/`sdl_kind`) -- to
  find the private `build_sdl`/`add_subgraph_definitions` path and confirm
  the public `SchemaLoader.load` entry point is the one that supplies a
  subgraph's missing `@key`/`_entities` plumbing from SDL text alone, which
  is the mechanism the SDL-only-subgraph finding rests on.
- `lib/graph_weaver/schema_diff.rb` (`Change`/`compare_deprecation`) -- to
  confirm `schema:diff` is genuinely the only check that surfaces a
  deprecation, and to get the exact log line it prints.
- `lib/graph_weaver/tasks.rb` (`queries:check`, `Tasks.supergraphs!`) -- to
  confirm `rake graph_weaver:queries:check` calls `GraphWeaver.check_queries`
  with no arguments (no `SUPERGRAPH=` read anywhere in that task), rather
  than inferring it from the observed behavior alone.
