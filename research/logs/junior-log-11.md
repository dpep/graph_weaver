# Junior dev log — graph_weaver two-graph app

## 20:15 — start
Read README.md top to bottom. Points to docs/getting_started.md, "more than one schema"
section at the bottom for the two-graph case. Also skimmed docs/testing.md (fake/wire modes,
pins, graphql_fake/graphql_in_process helper naming) and docs/scalars.md (register_scalar).

Plan: one graph per API — Countries (public, simple) and PokeAPI (Hasura, large, jsonb scalar).
Namespaces: `Countries` and `Poke`. Queries dirs: app/graphql/countries/queries and
app/graphql/poke/queries. Output dirs likewise generated/.

## 20:20 — app scaffolding
`rails new junior-app-11 --minimal --skip-active-record --skip-test --skip-system-test
--skip-bootsnap` — chose --skip-test since we're using rspec per the gem's docs, and
--minimal to keep noise down (no attempt to render views nicely yet, just picker + list).
Added to Gemfile: `gem "graph_weaver", path: "..."` at the very top (README shows it as the
first line of Gemfile so matched that), `rspec-rails` in dev/test, `webmock` in test group
(testing.md: ":wire needs webmock and rack in the Gemfile (group :test)"). bundle install
green: 84 gems.
`rails g rspec:install` — created .rspec, spec/spec_helper.rb, spec/rails_helper.rb.
## 20:20 — two-graph declaration and the schema-dump gap
Read the "More than one schema" section in full. It shows two graph shapes: an
own-schema class (`Billing::Schema` via lambda) and "a dump you already have"
(`db/github.json`). It does NOT show how to produce that dump for a second
*URL* API you don't already have a committed dump for — the generator
(`rails g graph_weaver:install`) only sets up ONE graph (confirmed via
`--help`: no `--graph` flag). This is the first "doc silent" spot.

Cross-referenced docs/real_world.md: `cache: true` on a `GraphWeaver.new(url,
cache: true)` "dumps the schema at GraphWeaver.schema_path" — but schema_path
is explicitly "the one singular setting: a run reads one schema" (generated_modules.md).
So `cache: true` can't target two different files without changing schema_path
in between. Also found: real_world.md shows `GraphWeaver.generate!(schema:
github)` — you can hand `generate!` a live client directly with "no dump on
disk needed" — but the getting-started CI table promises `verify` needs NO
network, which only holds with a *committed* dump, not a live client re-hit
every run. So for CI-safe two-graph setup I went with: temporarily reassign
`GraphWeaver.schema_path` to each graph's own path, then `cache: true` on that
graph's client to write the dump there (this exact behavior — "cache: true
dumps the schema at GraphWeaver.schema_path" — IS documented, just not
spelled out for the two-file case). Ran via `bin/rails runner` twice (moved
the already-introspected countries dump by hand into app/graphql/countries/,
then bootstrapped poke the same way).

STUCK MOMENT: no doc says how to bootstrap a second graph's schema dump. Went
with the schema_path-reassignment trick above rather than opening lib/.

## 20:22 — poke dump is huge
PokeAPI (Hasura) introspection: 5,776,832 bytes (5.7 MB) schema.json, 4441
types, in ~2.7s wall (rails boot + introspect + write). Countries: 29,421
bytes. Grepped both dumps (plain JSON, as the docs say to do — "already in
your repo") to find real field/query names since the docs don't cover Hasura
naming: root field `pokemon_v2_pokemon(where: pokemon_v2_pokemon_bool_exp,
limit: Int, ...)`, filter via `where: { name: { _ilike: "e%" } }"`
(String_comparison_exp has `_ilike`/`_regex`/etc — Hasura convention, not a
graph_weaver thing), and the jsonb field: `pokemon_v2_pokemonsprites.sprites`
is typed `jsonb`.

Wrote initializer with two `GraphWeaver.graph` blocks (`:countries`,
`:poke`), `client "COUNTRIES"` / `client "POKE"` (constants defined at the
top — matches the docs' GitHub example exactly), `namespace "Countries"` /
`"Poke"`, and `register_scalar "jsonb", "T.untyped"` inside the `:poke` block
only (per scalars.md: "JSON can legally be any JSON value... T.untyped" and
the graph-block registration text: "the block's registrations reach that
graph alone").

Wrote app/graphql/countries/queries/countries.graphql (countries + code +
continent.code) and app/graphql/poke/queries/pokemon_by_letter.graphql
(`pokemon_v2_pokemon(where: { name: { _ilike: $pattern } }, limit: 10)`).

## 20:24 — generate + the four tasks
`rake graph_weaver:generate`:
  wrote app/graphql/countries/generated/countries_query.rb
  wrote app/graphql/poke/generated/pokemon_by_letter_query.rb
1.9s wall. ONE file per graph — surprised me, expected "many files" for the
huge Hasura schema, but codegen is query-driven (README says so) — a query
with no fragments/unions/enums touched generates just its own module, however
big the schema behind it is.

`rake graph_weaver:verify` -> "generated queries up to date", exit 0.

`rake graph_weaver:graphs` ->
  :countries  app/graphql/countries/queries -> app/graphql/countries/generated
    namespace: Countries
    client: COUNTRIES
  :poke  app/graphql/poke/queries -> app/graphql/poke/generated
    namespace: Poke
    client: POKE
exit 0.

`rake graph_weaver:unused` (before any controller/view exists, so everything
selected is unread) -> 10 selections, 6 unread — 2 queries, 20 files swept,
plus the standard "lint not a proof" footer. exit 0 (STRICT not set).

`rake graph_weaver:queries:check` -> "every query validates against the
schema", 1.7s (network, re-introspects both recorded urls). exit 0.
## 20:30 — the app itself
HomeController#index: `Countries::CountriesQuery.execute!.countries` for the picker;
on `country_code` param, finds the country, takes `continent.code[0]` as the letter,
calls `Poke::PokemonByLetterQuery.execute!(pattern: "#{letter}%").pokemon_v2_pokemon`.
View renders a `<select>` of 250 countries (name + continent code) and, once one is
picked, the continent and a list of pokemon names with their jsonb `sprites["front_default"]`
image. Smoke-tested via `rails runner` (Japan -> AS -> "A" -> arbok/arcanine/abra/...)
and via a live dev server + curl (`GET /?country_code=JP`) — sprite <img> tags rendered
from the jsonb field, e.g. arbok -> raw.githubusercontent.com/.../24.png. This confirms
the T.untyped jsonb registration round-trips a real Hash correctly.

`rake graph_weaver:unused` after wiring the view: "10 selections, 0 unread — 2 queries,
22 files swept" — every selected field across both graphs is now read somewhere.
## 20:35 — the schema: kwarg saga (biggest stuck moment of the day)
Wrote spec/requests/home_spec.rb: one graphql: :fake example pinning a value in
each graph in the same example, one graphql: :wire example, one wrong-schema demo.
Getting `schema:` right took four attempts:

1. `graphql_fake("Country" => {...}, schema: COUNTRIES)` (the CLIENT constant) ->
   refused verbatim:
   "graphql_fake stands in for the modules of one graph, and #<GraphWeaver::Client:...>
   names none of this app's graphs (:countries, :poke) — say which:
   graphql_fake(schema: MySchema). A fake fabricates that schema's shapes, with
   that graph's scalar registrations."
2. Tried `schema: GraphWeaver::SchemaLoader.load("app/graphql/countries/schema.json")`
   (a freshly loaded schema Class) -> same "names none of this app's graphs" refusal,
   just with the Class's #inspect instead of the Client's.
3. Tried the exact declared path STRING itself (both relative and Rails.root-absolute)
   -> same refusal, now printing the string back.
4. Tried the graph's NAME as a symbol (`:countries`) since the error message itself
   lists the names in that form -> same refusal.

STUCK MOMENT — none of testing.md's or getting_started.md's "more than one schema"
text ever explains WHAT VALUE actually satisfies `schema:` for a graph that has no
owned graphql-ruby schema class (ours are two remote APIs, dump-only). Every
`graphql_fake(schema: X)` example in the docs uses an X that is an app-owned,
already-instantiated schema class (Catalog::Schema, MySchema) referenced by the
SAME constant both where the graph is declared and where the test calls it — so
identity is free. For a URL/dump-based graph there is no such natural constant
unless you make one. Fix: changed the initializer to load each dump ONCE into
its own constant (`COUNTRIES_SCHEMA` / `POKE_SCHEMA` via
`GraphWeaver::SchemaLoader.load(path)`) and pass THAT constant as the graph's
`schema` setting (not the raw path string) — then specs pass the SAME constant to
`schema:`. That worked immediately. Lesson for the doc: "more than one schema"
should show this pattern for a dump-based graph, the same way it shows
`schema -> { Billing::Schema }` for an owned one — right now a newcomer with two
plain remote APIs has nothing to imitate.

Re-ran `rake graph_weaver:verify` after the initializer change (string -> loaded
Class) to make sure regeneration was still byte-identical: "generated queries up
to date", 1.7s wall — no diff, no measurable boot-time hit from eager-loading
5.7MB into a schema class at boot.

## 20:38 — second Hasura gotcha: lowercase type name collides with fake options
Pinning `"pokemon_v2_pokemon" => { "name" => "abra" }` (bare type-level pin) raised:
  ArgumentError: a fake doesn't take pokemon_v2_pokemon:. It takes schema:,
  registry:, overrides:, seed:, values:, list_size:, null_chance:, errors:,
  fail_at:, corrupt:
Cause: testing.md says "Options are lowercase words, so a key with a dot or a
leading capital is a pin wherever it is written" — a Hasura type name is ALL
lowercase AND has no dot, so the bare form is indistinguishable from an option
name and gets rejected as an unknown option instead of accepted as a pin. Not
called out anywhere the doc discusses Hasura naming (scalars.md only warns
about spelling the type name right, not about this ambiguity). Fix: use the
dotted FIELD form instead — `"pokemon_v2_pokemon.name" => "abra"` — the dot
alone is enough to disambiguate regardless of case.

## 20:39 — the wrong-schema pin refusal (verbatim)
`graphql_fake("pokemon_v2_pokemon.name" => "abra", schema: COUNTRIES_SCHEMA)` —
pinning a Poke-only type against the Countries graph's schema:
  GraphWeaver::Error: override key "pokemon_v2_pokemon.name" names no object
  type in this schema

All 3 examples in spec/requests/home_spec.rb green:
  graphql: :fake  — pins a country in one graph and a pokemon in the other, one example
  graphql: :wire  — posts to both real transports (WebMock asserts both endpoints hit)
  graphql: :fake  — the wrong-schema pin, asserting the exact refusal above
`bundle exec rspec spec/requests/home_spec.rb`: 3 examples, 0 failures, 0.11s.
## 20:40 — production boot + zeitwerk
`SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production bin/rails runner 'puts :ok'` (via the
rvm bundle exec, since bin/rails' shebang is the system ruby 2.6):
  transport: GraphWeaver::Transport::HTTP -> https://countries.trevorblades.com/
  transport: GraphWeaver::Transport::HTTP -> https://beta.pokeapi.co/graphql/v1beta
  loaded 2 generated module(s) from app/graphql/generated, app/graphql/*/generated
  ok
2.5s wall, exit 0.

`RAILS_ENV=production bin/rails zeitwerk:check`:
  transport: ... (same 2 lines)
  loaded 2 generated module(s) from app/graphql/generated, app/graphql/*/generated
  Hold on, I am eager loading the application.
  All is good!
exit 0. Confirms the per-graph `output` dirs (app/graphql/*/generated) are
correctly excluded from autoloading by the documented default
(`generated_paths` includes the `app/graphql/*/generated` glob already) —
never had to touch `GraphWeaver.generated_paths` by hand.

## done
Total elapsed: ~25 minutes wall-clock (20:15 start -> 20:40 finish) for a from-
scratch two-graph Rails app: scaffold, two graphs, one query per graph, a
controller+view wiring both together, all 5 rake tasks green, 3 specs across
3 modes green, production boot + zeitwerk green.
