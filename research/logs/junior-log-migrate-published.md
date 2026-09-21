# Junior migrate log — countries API app, graphql-client -> graph_weaver 0.7.5

Persona: ~1 year into Rails, used GraphQL from TS/Apollo, never used graph_weaver
or graphql-client (Ruby) before. Task: build a small Rails app on
github/graphql-client against https://countries.trevorblades.com/graphql (3
queries, 1 shared fragment, 1 presenter, 1 service object, webmock request
specs, green), then migrate it onto graph_weaver following docs/migrating.md.
Then force an enum drift and follow docs to survive it.

Repo read-only at /Users/dpepper/code/lib/ruby/graph_weaver, main 89ded3e.
Building under /tmp/claude/graph_weaver/round7/junior-migrate-app.
graph_weaver installed from RubyGems, version 0.7.5, per brief exception.
Docs read as a user would on GitHub: `git show v0.7.5:docs/X.md` (not opening lib/).

## Baseline app (github/graphql-client + Countries API)

20:52 — `rails new junior-migrate-app --minimal --skip-active-record --skip-test`.
Added `graphql-client`, `rspec-rails`, `webmock` to Gemfile. `bundle install` clean.

20:53 — dumped schema via `GraphQL::Client.dump_schema(http, "db/countries_schema.json")`
into a one-off script (graphql-client's own workflow, not graph_weaver's docs).

Confusion (baseline, not graph_weaver's fault): first attempt used a NAMED fragment
(`fragment CountryFields on Country { ... }`), which graphql-client refused:

  expected Documents::CountryFields to be a GraphQL::Client::FragmentDefinition, but
  was a Module. Did you mean Documents::CountryFields::CountryFields?

Fixed by using an anonymous fragment (`fragment on Country { ... }`) — graphql-client
names it from the assigned Ruby constant. Also hit graphql-client's field-masking
gotcha immediately: `country.name` on a query result raised "implicitly fetched field"
because `name` came in through the fragment spread — had to unwrap with
`Documents::CountryFields.new(country).name`. Both are graphql-client footguns, listed
here only as context for what the migration below deletes.

3 queries (`CountriesQuery` list, `CountryQuery` by code, `ContinentsQuery` grouped),
1 shared fragment (`CountryFields`: code/name/capital/emoji), 1 presenter
(`CountryPresenter`, unwraps the fragment), 1 service object (`CountriesService`),
webmock-stubbed request specs for all 3 routes.

20:57 — green: `bundle exec rspec` → 3 examples, 0 failures, no network.
Committed as baseline (277e475). ~15 minutes wall clock (agentic pace; budget was ~30).

## Migration (docs/migrating.md, "From graphql-client, in Rails")

20:57 — added `gem "graph_weaver", "0.7.5"` beside `graphql-client` in the Gemfile,
`bundle install` clean (RubyGems, not path:, per the brief's exception).

20:58 — Step 1: `rails g graph_weaver:install db/countries_schema.json` (the dump
graphql-client's own `GraphQL::Client.dump_schema` had produced). Output matched
docs byte for byte: initializer, `app/graphql/{queries,fragments,generated}/.keep`,
`graphql.config.yml`, `.gitattributes` append, and the `require "graph_weaver/rspec"`
insert into `spec/rails_helper.rb` — landed correctly ABOVE the (already-commented-out)
spec/support glob, matching testing.md's ordering warning, first try. Set
`GraphWeaver.client = GraphWeaver.new("https://countries.trevorblades.com/graphql")`
by hand (the generator leaves that line commented, correctly — a dump has no
resolvers). Committed alone.

20:58 — Step 2: `rake graph_weaver:schema:refresh` — one command, no `URL=` needed,
adopted the dump's provenance first try:
  "refreshed db/countries_schema.json from https://countries.trevorblades.com/graphql"
Confirmed `schema:diff`/`queries:check` now hit the network (they didn't before).
The dump also got rewritten from graphql-client's pretty-printed introspection JSON
into graph_weaver's own compact format (2015 lines -> 1, plus a `graph_weaver:
{url:, introspected_at:}` provenance key) — graphql-client's `load_schema` kept
parsing it fine afterward (same `data.__schema` shape, extra key ignored), so running
both clients off one shared dump file worked with no friction.

20:59 — Step 3 (register scalars/enums before porting code): **no-op for this API.**
Countries API declares zero custom scalars and zero enums (checked via introspection
before starting: only Boolean/Float/ID/Int/String). Nothing to register. Not a doc
problem — just means this base app can't exercise scalars.md or the enum-drift
behavior change migrating.md calls out ("the one behaviour change to plan for");
see the separate enum-drift section below for how I forced that scenario anyway.

20:59-21:01 — Step 4: ported `countries` (list) query end to end — `.graphql` file +
fragment file, `rake graph_weaver:generate` (first try), rewrote `CountriesService#list`
and `CountryPresenter`. Confirmed live against the real API via `rails runner`, then
ran the OLD webmock-stubbed spec suite unchanged: **3 examples, 0 failures** — the
doc's headline claim ("leave the specs alone. They pass untouched") held exactly,
because both clients still send the same field names in the POST body and my stub
matched on that substring. Committed.

21:01-21:02 — Step 5: ported `country` and `continents` queries the same way, both
generated first try. Notable: `CountriesQuery`'s and `ContinentsQuery`'s `countries`
field both alias `CountryFields = GraphQLTypes::CountryFields` (the fragment IS the
whole selection on that field in both), while `CountryQuery`'s `country` field
inlines the fragment's props directly into its own `Country` struct (fragment is
NOT the whole selection — it also has `continent`/`languages`). This is the
*fixed* form of migration-experiment.md's finding #1 ("a shared fragment on an
object type gets no shared Ruby type") — CHANGELOG v0.7.5 says exactly this landed
in this release: "A shared fragment on an object type is one Ruby type... Only
that exact shape hoists." Verified by reading both generated files side by side.
Full spec suite: still 3/3 green, untouched. Committed.

21:03 — Step 6: ported the 3 request specs to `graphql: :fake`. Repeated the known
trap from a prior pass (junior-log.md): pin key is the schema TYPE name ("Country"),
not the generated struct name for a list field ("Countries") — got it right this
time because I already knew to check, but a first-timer would not. Green first try,
3/3, no network (webmock's real-connection block would have caught a leak; none).

21:04 — Step 7: deleted `app/graphql/documents.rb`, the graphql-client initializer,
and the `graphql-client` gem. `bundle install` clean (84 gems). `bundle exec rspec`
still 3/3. `rake graph_weaver:verify` — "generated queries up to date", exit 0.
`rake graph_weaver:unused` — "13 selections, 0 unread", exit 0. Live sanity check
against the real API still works.

**Migration wall clock: ~12 minutes** (20:52 baseline start to 21:04 graphql-client
deleted), agentic pace — a human would take a morning, in line with migrating.md's
own "3-4 weeks for 40 queries / 25k lines" scaled down to 3 queries / ~90 lines.

## Enum drift (forced)

Checked first: the real Countries API has ZERO custom scalars and ZERO enums
(introspected `__schema.types` for kind ENUM/SCALAR before writing anything —
only Boolean/Float/ID/Int/String, no domain scalar or enum at all). So the
"make one enum drift on purpose" part of the brief can't be done against the
live server as-is. Documented the workaround plainly rather than silently
picking a different API:

21:05 — hand-edited MY LOCAL `db/countries_schema.json` (post-adoption, so it
already carried its own provenance) to add a synthetic `ContinentCode` ENUM
type (AF/AN/AS/EU/NA/OC/SA — the real 7 continent codes this API actually
returns as an untyped ID) and repoint `Continent.code`'s type at it. This is
NOT something the docs told me to do — it's a deliberate, clearly-flagged
deviation purely to exercise the documented behaviour. Consequence I noted for
the app: `schema:refresh` must never run again on this app, or it will
silently wipe the synthetic type back to `ID!` on the next live introspection.

Added `code` to `app/graphql/queries/continents.graphql`, `rake
graph_weaver:generate` — first try, wrote `types/continent_code.rb` as a
`T::Enum` with the 7 members, no registration needed for that part.

21:06 — demonstrated the raise via `ContinentsQuery.from_response!` with a
hand-built response hash carrying `"code" => "XX"` (never touched the network —
this is the documented network-free half of execute). Verbatim:

  GraphWeaver::CastError: failed to cast response into
  ContinentsQuery::Result::Continents: code: "XX" is not a
  GraphQLTypes::ContinentCode — expected one of: AF, AN, AS, EU, NA, OC, SA; a
  value the server added since you generated needs a regenerate, or
  register_enum fallback: true to absorb them

This is exactly the message docs/scalars.md and migrating.md's "the one
behaviour change to plan for" describe, word for word.

21:06 — added `GraphWeaver.register_enum("ContinentCode", fallback: true)` to
the initializer (per docs/scalars.md#values-the-server-hasnt-told-you-about-yet),
regenerated, reran the same hand-built response: `code` came back
`GraphQLTypes::ContinentCode::Other` instead of raising. Wrote
`spec/enum_drift_spec.rb` (2 examples: a declared value casts normally, an
undeclared one absorbs into `Other`) — couldn't keep a "raises" spec passing
in the same suite once fallback was registered, because the fallback logic is
baked into the generated source at `generate` time, not decided by a runtime
registry (docs/scalars.md says this explicitly: "no runtime registry") — so
the "before" behaviour lives only in this log's verbatim quote above, not as a
live spec. Full suite after this: 5 examples, 0 failures. `verify`/`unused`
still exit 0.

## The published gem itself (0.7.5 from RubyGems)

- `gem contents graph_weaver -v 0.7.5` — carries the full `docs/` directory (14
  files, all the ones read above), `examples/` (countries.rb, github/,
  federation.rb, rick_and_morty.rb), the install generator, `lib/graph_weaver/
  tasks.rb`, README.md, LICENSE.txt. Nothing promised in the README's "Dig
  deeper" list is missing from the gem itself.
- RubyGems metadata: `homepage_uri`/`source_code_uri` ->
  https://github.com/dpep/graph_weaver, `documentation_uri` ->
  https://github.com/dpep/graph_weaver/tree/main/docs,
  `changelog_uri` -> https://github.com/dpep/graph_weaver/blob/v0.7.5/CHANGELOG.md
  — all four URLs return 200, and the changelog_uri is pinned to the v0.7.5
  tag specifically (not main), so it doesn't drift under the reader's feet.
- Spot-checked 5 links referenced from docs (rspec_spec.rb, wire_mode_spec.rb,
  docs/ tree, docs/migrating.md, the rubygems.org page itself) — all 200.
- Generator and every rake task used (`install`, `generate`, `schema:refresh`,
  `schema:diff`, `queries:check`, `unused`, `verify`) worked exactly as
  documented, every single time, first try, with no need to open lib/.

## Summary

Baseline app: 20:52:42 -> 20:57:38 committed (green, 3 examples).
Migration (add gem -> graphql-client deleted): 20:57:52 -> 21:04:26 (green, 3
examples untouched, then re-pointed to :fake). First green spec suite AFTER
starting the migration: 21:01:06 (~3 min 15s of wall clock after adding the
gem) — that's the point where 1 of 3 queries was ported and the untouched
webmock spec for it passed against the new client.
Enum drift: 21:05:40 -> 21:09:52 (~4 min), a deliberate side-quest.

Hand-written diff for the whole migration (excludes generated/ and the schema
dump): 18 files, +108/-109 lines — roughly a wash, not a net cost, for 3
queries + 1 fragment. Generated + regenerated Ruby: 485 lines, 6 files, 100%
machine-written, `verify` stayed green throughout.

Never opened `lib/` in the graph_weaver repo. Did open graphql-client's own
gem source once (`~/.rvm/gems/.../graphql-client-0.26.0/lib/graphql/client.rb`)
to debug a graphql-client-specific fragment-naming error during the BASELINE
build, before graph_weaver was even in the Gemfile — that's a third-party
dependency of my own app, not the library under test, and the brief's
"don't open lib/" restriction is about graph_weaver's internals.

## FINAL REPORT

(see final assistant message of this session for the full ranked report; this
log is the durable, timestamped, verbatim record it's built from.)
