# Junior dev log — graph_weaver exploration

## 2026-09-12 03:16 UTC — start
Never used this gem. Task: pull Pokemon + country data via graph_weaver, from
IRB first, then scripts. Told to work only from README.md + docs/, not lib/ or
spec/, unless stuck.

## 03:17 — read README.md
Console example is right there:
```ruby
api = GraphWeaver.new("https://countries.trevorblades.com/")
CountryQuery = api.parse("queries/country.graphql")   # a path or a raw string
CountryQuery.execute!(code: "JP").country&.capital    # => "Tokyo"
api.run!("query { continents { name } }").continents  # or no module at all
```
Good, that's exactly what I need for step 1. Docs to dig into per the README's
"Dig deeper" list: generated_modules.md (dynamic mode), real_world.md (told
these are "mine" to read), testing.md (fakes/pins), transports.md (retries),
logging.md (duration logging), errors.md (error hierarchy), cassettes.md.

## 03:19 — read docs/real_world.md
Shows GitHub end-to-end: `GraphWeaver.new(url, auth:, cache: true)`,
`client.parse(heredoc)`, `.execute!`. Mentions retries live in transports.md.
No mention yet of "browse the schema without leaving the console" — need to
keep looking.

## 03:21 — read docs/generated_modules.md
Long doc. Found the "Dynamic mode" section at the very end: `GraphWeaver.parse`
generates+evals with no build artifact; `GraphWeaver.run(source, query,
**variables)` / `client.run` is the one-shot form. Still no explicit "list the
fields" recipe — closest thing so far is getting_started.md's line about
`app/graphql/schema.json` being "the whole schema as plain JSON — types,
fields, descriptions" for when you're not sure what the API offers, but that's
the checked-in-app path, not a console one-liner.

## 03:24 — searched docs/*.md for "fields|introspect|schema\.|print_schema|types\b"
SURPRISE / doc gap: no doc page says "here's how to list a live endpoint's
fields from the console" as its own recipe. The closest things are:
  - getting_started.md: "app/graphql/schema.json is the whole schema as plain
    JSON" (assumes you've already introspected to a file)
  - testing.md: "GraphWeaver.client.schema" — "the client in play exposes it
    as GraphWeaver.client.schema" (this is inside the *testing* doc, about
    sampling a field or building a query on the fly in a spec, not framed as
    a console recipe at all)
  - real_world.md: `GraphWeaver::SchemaLoader.introspect(transport, cache:,
    ttl:)` is public
None of this is exactly "type X in irb to browse fields." Working theory:
`client.schema` returns whatever graphql-ruby hands back from introspection
(a live `GraphQL::Schema` class), and graphql-ruby's own API (`schema.types`,
`schema.query.fields`, etc.) is how you'd browse it — the gem's docs don't
re-document graphql-ruby's own introspection API. Going to try this in IRB
and see. Noting this as confusion #1.

## 03:26 — read docs/transports.md
`retries:` on `GraphWeaver.new` — a count of attempts *after* the first;
`retries: true` for Retry's default of 2. `retry_on:` defaults already cover
TransportError + 5xx/408/429. This is what "retries transient failures" in
the pull script wants — just `retries: 3` (or similar) on the client, no
manual retry loop needed for the transport level.  Note: PokeAPI's Hasura
backend could return actual GraphQL errors (not HTTP failures) for a bad
query — that's `QueryError`, not something `retries:` covers by default
(`retry_codes:` only retries GraphQL errors you name, and I don't know
PokeAPI's throttle code offhand). Treating QueryError/InputError from a
malformed query as a *permanent* failure, and TransportError/ServerError
(5xx/408/429) as what `retries:` should absorb automatically.

## 03:28 — read docs/logging.md
Instrumentation event `GraphWeaver::EXECUTE_EVENT`
("execute.graph_weaver") with `payload[:duration_ms]` — exactly the per-page
timing the task wants, and the doc gives a copy/pasteable non-Rails
instrumenter:
```ruby
GraphWeaver.instrumenter = lambda do |_event, payload, &block|
  block.call
ensure
  log.info { "#{payload[:operation]} (#{payload[:duration_ms]}ms) #{payload[:status]}" }
end
```
Since I want stderr not a Logger file, I'll point `Logger.new($stderr)` there
directly, or write to $stderr myself in the ensure block. Either is a direct
application of the doc's example.

## 03:30 — read docs/errors.md
Error hierarchy: TransportError (no response), ServerError (non-2xx),
QueryError (200 + GraphQL errors), CastError (bad shape), InputError (bad
variables client-side). All of them are `GraphWeaver::Error`. This is what
"exits non-zero with a one-line reason on a permanent failure" wants —
rescue GraphWeaver::Error broadly, print `e.message`, exit 1. TransportError/
ServerError are what `retries:` already retries; if those exhaust retries,
they still surface as a raised error here — same rescue.

## 03:33 — read docs/testing.md
Fakes: `graphql_fake("Type" => value)` pins, `"Field" => [...]` pins a whole
list — "a pinned list is exactly as long as you write it," including `[]`.
That's the natural way to make a fake page come back empty:
`graphql_fake("pokemon_v2_pokemon" => [])`. `config.list_size = 1..3` is a
separate, suite-wide knob for the *fabricated* (non-pinned) list lengths —
not it, since I want a *specific* page to return empty, not to shrink every
random list in the suite. Recording this as the answer to "pins? list_size?
both are in the docs" — it's pins, specifically the empty-array pin;
list_size answers a different question (how big are the fabricated lists
in general).

## 03:35 — read docs/cassettes.md
`GraphWeaver::Testing.cassette(name, client:)` — records on first run against
a real client, replays after. That's task 5's second spec.

## 03:37 — peeked at examples/ (linked directly from README's "Dig deeper" /
"examples" line, so treating it as in-bounds)
`examples/rick_and_morty.rb` is the pagination example: a `loop do ... end`
around `execute!`, reading `next_page` off the response and `break unless
page`. Different pagination shape than PokeAPI's limit/offset (this one is
page-number-based), but the loop shape carries over directly. `examples/
countries.rb` is the exact "30 lines" example the README references — client,
`parse`, `execute!`, and `api.run!(raw string)` with no module. This is my
template for tasks 1–3.

## 03:41 — IRB session (task 1), against PokeAPI
```ruby
require "graph_weaver"
api = GraphWeaver.new("https://beta.pokeapi.co/graphql/v1beta")
api.class            # => GraphWeaver::Client
api.schema.class      # => Class
```
`.schema` is a live `Class` — not documented as such anywhere in graph_weaver's
own docs (this is graphql-ruby's own `GraphQL::Schema` subclass, built from
introspection). Confirmed:
```ruby
schema.ancestors.first(3)  # => [#<Class:...>, GraphQL::Schema, Object]
```
So "how do you see what fields exist without leaving the console" is answered
by dropping into *graphql-ruby's* schema API, not a graph_weaver-specific one:
```ruby
field = schema.query.fields["pokemon_v2_pokemon"]
field.type.to_type_signature      # => "[pokemon_v2_pokemon!]!"
field.arguments.keys              # => ["distinct_on", "limit", "offset", "order_by", "where"]
pokemon_type = field.type.unwrap  # peel List/NonNull off to the object type
pokemon_type.graphql_name         # => "pokemon_v2_pokemon"
pokemon_type.fields.keys.sort     # => ["base_experience", "height", "id", "is_default", "name", ...]
```
First wrong turn: tried `field.type.unwrap.name` — that's `nil`, because a
graphql-ruby wrapped/anonymous type class doesn't answer `.name` the way a
normal Ruby class does here; `.graphql_name` is the one that works, and
`schema.get_type(nil)` predictably also came back nil. First error verbatim:
```
/tmp/claude/graph_weaver/irb4.rb:10:in '<main>': undefined method 'fields' for nil (NoMethodError)
```
(from calling `.fields` on the nil result of `schema.get_type(type_name)`
where `type_name` was itself nil). Confusion #1 resolved this way — cost about
4 failed one-liners before landing on `.unwrap` + `.graphql_name`.

Then the two patterns from the README, both worked first try once the query
was right:
```ruby
PokemonPageQuery = api.parse(<<~GRAPHQL)
  query($limit: Int!, $offset: Int!) {
    pokemon_v2_pokemon(limit: $limit, offset: $offset, order_by: {id: asc}) {
      id name height weight
    }
  }
GRAPHQL
result = PokemonPageQuery.execute!(limit: 3, offset: 0)
result.pokemon_v2_pokemon.map(&:to_h)
# => [{id: 1, name: "bulbasaur", height: 7, weight: 69}, {id: 2, name: "ivysaur", ...}, ...]

api.run!("query { pokemon_v2_pokemon(limit: 2, offset: 0) { name } }").pokemon_v2_pokemon.map(&:name)
# => ["bulbasaur", "ivysaur"]
```
Surprise (nice one): `order_by: {id: asc}` — a plain inline Hash-shaped
GraphQL input literal typed directly into the raw query string — parsed with
zero fuss, no need to know about the enum's Ruby constant since this is a raw
string, not a generated module call. Also note `.execute!` returns a `Result`
whose nested list items are themselves structs with a working `#to_h`
(documented in generated_modules.md) — used that immediately to eyeball the
whole page instead of chaining accessors one at a time, which is the
"leaving the console" trick worth remembering.

## 03:53 — wrote bin/pull (task 2)
Key lines:
```ruby
GraphWeaver.instrumenter = lambda do |_event, payload, &block|
  block.call
ensure
  warn "#{payload[:operation]} (#{payload[:duration_ms]}ms) #{payload[:status]}"
end

api = GraphWeaver.new(URL, retries: 3)

loop do
  page = query.execute!(limit: page_size, offset:).pokemon_v2_pokemon
  break if page.empty?
  page.each { |p| csv << [p.id, p.name, p.height, p.weight] }
  offset += page_size
end
```
and
```ruby
rescue GraphWeaver::Error => e
  warn "pull: #{e.message}"
  exit 1
end
```
First bug I wrote myself (not the gem's): originally returned `offset` as the
row count from `pull_all` — wrong the moment the last page is a partial one,
since `offset` overcounts by up to `page_size - 1`. Switched to a real
`total += page.size` accumulator. Not a graph_weaver issue, just me being
sloppy on the first pass.

## 03:55 — first real run, CSV missing gem
```
bin/pull:12: warning: csv was loaded from the standard library, but is not
part of the default gems starting from Ruby 3.4.0.
/Users/dpepper/.rvm/rubies/ruby-3.4.9/lib/ruby/3.4.0/bundled_gems.rb:82:in
'Kernel.require': cannot load such file -- csv (LoadError)
```
Nothing to do with graph_weaver — Ruby 3.4 unbundled `csv` from the default
gems, so it needs to be in the Gemfile explicitly. Added `gem "csv"`,
re-bundled, fixed.

## 03:58 — bin/pull runs clean against the real API
```
IntrospectionQuery (706.66ms) ok
Query (152.11ms) ok
... (16 lines total)
wrote 1302 rows to pokemon.csv
```
3.79s wall clock, exit 0, 1302 data rows (+1 header = 1303 lines), 16 requests
(1 introspection + 13 pages of 100 + the empty terminating page + ...
actually 15 "Query" lines — let me not overclaim the exact count breakdown,
what matters is it terminated cleanly on the empty page). Operation name logs
as bare "Query" — that's generated_modules.md's naming rule for a genuinely
anonymous parsed document ("dynamic `parse` falls back to `Query` for an
anonymous one"); I never named the operation (`query($limit...)` with no
name), so every page's log line reads the same, which would be useless in a
real app with multiple queries — noting this as a thing I'd fix by naming the
operation if this weren't a throwaway script.

## 04:00 — verified the "permanent failure" path really works
A typo'd field is refused at *parse* time (before any network call), as a
`GraphWeaver::QueryValidationError`, first error verbatim:
```
/Users/dpepper/code/lib/ruby/graph_weaver/lib/graph_weaver/codegen.rb:416:in
'GraphWeaver::Codegen#generate': invalid query: (GraphWeaver::QueryValidationError)
  4:5  Field 'nmae' doesn't exist on type 'pokemon_v2_pokemon' (Did you mean `name`?)
```
A bad *variable* (wrong type passed to `execute!`) is what actually exercises
the rescue-and-exit-1 branch, since it happens where the begin/rescue lives:
```ruby
Q.execute!(limit: "lots", offset: 0)
# rescue GraphWeaver::Error => e; warn "pull: #{e.message}"; exit 1
```
→ `pull: $limit of Query: expected an Int, got "lots"`, exit 1. Exactly the
one-line, non-zero-exit behavior the task wants, and it's the InputError
message from errors.md verbatim, not something I had to build myself.

## 04:02 — housekeeping note
Scratch app setup happened between the doc-reading pass and the IRB session
(out of strict timestamp order in this log because I filled it in
retroactively while editing): `/tmp/claude/graph_weaver/junior-app-12`,
Gemfile pins `gem "graph_weaver", path: "..."` + `rspec` + `webmock`,
`bundle install` succeeded clean (19 gems) on the first try — no surprises
there.

## 04:10 — wrote bin/countries (task 3)
Copied the shape of `examples/countries.rb` almost verbatim — client, one
`.parse` with a raw heredoc, `.execute!.countries`. Ran clean first try, no
surprises, 250 countries, one blank capital (Antarctica, correctly nilable —
`c.capital.to_s` handles it), one country with a comma-separated multi-currency
string (Zimbabwe). Exit 0.

## 04:15 — read the rest of getting_started.md for task 4
Confirmed "the rake-free way" is a documented, named path — the "Not Rails?"
section, "Or skip rake too" subsection:
```ruby
client = GraphWeaver.new(url, cache: true)
client.schema
schema = GraphWeaver::SchemaLoader.load(GraphWeaver.schema_path)
GraphWeaver.generate!(schema:)
GraphWeaver.changed_files
```
and real_world.md's shorter variant, no dump file at all:
```ruby
GraphWeaver.generate!(schema: github)   # no dump on disk needed
```
Went with the shorter one — didn't want a schema.json file for a throwaway
script.

## 04:18 — moved the query into app/graphql/queries/pokemon_page.graphql
```graphql
query($limit: Int!, $offset: Int!) {
  pokemon_v2_pokemon(limit: $limit, offset: $offset, order_by: { id: asc }) {
    id name height weight
  }
}
```
bin/generate:
```ruby
GraphWeaver.queries_paths = "app/graphql/queries"
GraphWeaver.generated_paths = "app/graphql/generated"
api = GraphWeaver.new("https://beta.pokeapi.co/graphql/v1beta")
written = GraphWeaver.generate!(schema: api)
```
Ran clean first try: `1 files total, 1 changed: app/graphql/generated/
pokemon_page_query.rb`. File name → module name worked exactly as
generated_modules.md's naming section says: `pokemon_page.graphql` →
`PokemonPageQuery`. Generated file is `# typed: strict`, has the QUERY
string with the operation now *named* (`query PokemonPageQuery(...)`,
because it's no longer anonymous) — nice fix over the dynamic version, where
every log line read the same generic "Query".

## 04:22 — wrote bin/pull_typed, using the generated module
```ruby
GraphWeaver.generated_paths = "app/graphql/generated"
GraphWeaver.load_generated!
GraphWeaver.client = GraphWeaver.new(URL, retries: 3)   # not baked in, so set the app default
...
page = PokemonPageQuery.execute!(limit: page_size, offset:).pokemon_v2_pokemon
```
Ran clean first try, exit 0, wrote the identical 1302-row CSV (`diff
pokemon.csv pokemon_typed.csv` → identical). Two concrete improvements over
the dynamic version:
  1. Log lines now read `PokemonPageQuery (131.63ms) ok` instead of the
     generic `Query (152.11ms) ok` — a real win if this were a multi-query
     app and you were trying to tell operations apart in a log.
  2. No `IntrospectionQuery` line at all on this run — the generated code
     carries its own `QUERY` string, so nothing needs to introspect the
     schema at runtime; the dynamic version pays that ~700ms up front every
     time the process starts.
What got more awkward: two extra concepts to hold in your head that dynamic
mode didn't need — `GraphWeaver.queries_paths`/`generated_paths` (where do
the files go) and `GraphWeaver.load_generated!` (nothing requires the
generated file for you outside Rails, so a forgotten call is a `NameError:
uninitialized constant PokemonPageQuery` at the first `execute!`, not at
`require "graph_weaver"` time). Also had to consciously remember that
`generate!(schema: api)` doesn't bake a client — the module falls back to
`GraphWeaver.client=`, so a run that forgets that line gets "no client
configured" instead of a working query. Both are one-line fixes once you
know the rule, but they're two new failure modes dynamic mode simply
doesn't have — you trade "one string in your script" for "a query file, a
generate step, and a load step, three things that all have to point at the
same directory."

## 04:30 — task 5: added cache: true to bin/generate for an offline schema
Regenerating with `GraphWeaver.new(url, cache: true)` writes
`app/graphql/schema.json` (5.7MB — Hasura's PokeAPI schema is huge) on first
introspection, which is also what specs need so `GraphWeaver::Testing`
doesn't have to hit the network just to know field shapes.
`GraphWeaver::Testing.configure { |c| c.schema = GraphWeaver::SchemaLoader.
load(GraphWeaver.schema_path) }` in spec_helper.rb points fakes/cassettes at
that dump.

## 04:33 — pulled the loop into lib/pokemon_pull.rb so it's testable
`bin/pull_typed`'s `loop do ... end` became `PokemonPull.call(query:, output:,
client: nil, page_size:)`, taking `client:` so a spec can override it per
call without touching `GraphWeaver.client`. Reran `bin/pull_typed` against
the real API after the refactor to make sure nothing broke: same 1302 rows,
byte-identical CSV.

## 04:36 — the empty-page question: pins? list_size? — probed both by hand
First tried pins as bare kwargs on `FakeClient.new`, following the shape
`graphql_fake("Type" => value)` shows for the *rspec helper*:
```ruby
GraphWeaver::Testing::FakeClient.new(schema:, "pokemon_v2_pokemon" => [])
```
First error verbatim:
```
/Users/dpepper/code/lib/ruby/graph_weaver/lib/graph_weaver/testing/fake_client.rb:260:in
'GraphWeaver::Testing::FakeClient#check_options!': a fake doesn't take
pokemon_v2_pokemon:. It takes schema:, registry:, overrides:, seed:, values:,
list_size:, null_chance:, errors:, fail_at:, corrupt: (ArgumentError)
```
That error message answered the question by itself — pins go under
`overrides:` when building `FakeClient` directly (`graphql_fake` is the tag
helper that takes bare pins and passes them through as `overrides:`
underneath; the raw class doesn't do that sugar). Fixed:
```ruby
GraphWeaver::Testing::FakeClient.new(schema:, overrides: { "pokemon_v2_pokemon" => [] })
```
Confirmed with a throwaway probe script — an *empty* override array really
does come back as `[]` off `execute!`, not an error and not a fabricated
non-empty list. Verdict on "pins? list_size? both are in the docs": it's
pins (an empty-array override), not `list_size` — `list_size` is a suite-wide
knob for how long *fabricated* (non-pinned) lists come out, a different
question from "make *this* call return nothing."

The harder part wasn't the empty page itself, it was getting *two different*
responses out of consecutive calls to the same query module, since a single
FakeClient's pin is static for the whole example. `GraphWeaver::Testing::
Sequence` (mentioned in testing.md's retry-testing example, "clients run in
sequence, the last one repeating") is what does this — one `FakeClient`
pinned to one Pokémon, a second pinned to `[]`, wrapped in a `Sequence`:
call 1 gets the pokemon, call 2 (and every call after) gets the empty page,
which is exactly what makes `lib/pokemon_pull.rb`'s `loop do ... end`
terminate. Sanity-checked this wasn't a rigged/vacuous pass by changing
page 1 to hold two pokemon in a throwaway spec and confirming the total
changed from 1 to 2 — the mechanism really does respond to the fake data,
it isn't hardcoded.

## 04:45 — wrote and ran both specs
`spec/pokemon_pull_spec.rb` (`graphql: :fake` + the `Sequence` trick above)
and `spec/pokemon_page_cassette_spec.rb` (`GraphWeaver::Testing.cassette
("pokemon_page", client: live)` against one real page, per cassettes.md).
Left anonymization off — cassettes.md explicitly says to for "a public,
non-sensitive API, where the real values are the point of the cassette,"
and PokeAPI names are the whole point of eyeballing this fixture.

First `bundle exec rspec` run (network available, cassette file didn't
exist yet — recorded it):
```
..

Finished in 0.54358 seconds (files took 0.85391 seconds to load)
2 examples, 0 failures
```
Reran with `TCPSocket.open` monkey-patched to raise, to actually verify the
second spec was *replaying* rather than quietly hitting the network every
time (I didn't want to just trust the doc's claim of "no HTTP interception,"
since the promise here is specifically that a committed cassette makes CI
offline):
```
..

Finished in 0.02594 seconds (files took 0.88368 seconds to load)
2 examples, 0 failures
```
Same 2/0, an order of magnitude faster, with the network hard-disabled — the
cassette genuinely replays offline. Mode per spec: `pokemon_pull_spec.rb` is
`graphql: :fake` (FakeClient + Sequence, no network ever); the cassette spec
is untagged / `:live` by default, replaying a committed YAML fixture instead
of hitting `:live` for real once recorded.

## 04:50 — doc search terms that found nothing (across docs/*.md)
- `"empty page"` — 0 hits, anywhere. Nothing in the docs frames the problem
  the way I needed it ("how do I make one call in a sequence return
  nothing") — I had to reconstruct it from the general pins section plus
  the one-line mention of `Sequence` buried in the retry-testing example.
- `"pagination"` — 1 hit, and it's a passing mention in cassettes.md ("point
  — pagination quirks, which union member came back..."), not a pagination
  how-to. graph_weaver has no pagination-specific helper at all — it's just
  "write a query with the args your API wants and loop," which the
  rick_and_morty.rb example shows but no *doc page* names as a pattern.
- `"offset"` / `"limit:"` — essentially no hits outside scalars.md's
  unrelated prose; graph_weaver is schema-agnostic about pagination style
  (limit/offset here, page-number in rick_and_morty.rb, cursor-based
  elsewhere) and documents none of them, which is defensible (it's the
  API's shape, not the gem's) but meant zero doc guidance for "how do people
  usually loop this."
- `"Sequence"` — 4 hits, all inside one example block in testing.md's
  "Simulating failures" section (the retry-testing snippet); there's no
  section titled or indexed under "Sequence," "multiple responses," or
  "chained fakes" — I only found it because I'd already read that whole
  section for the retry material and happened to remember the name.


## 04:55 — wrap-up
Never opened `lib/` or `spec/` in the gem itself — the one moment I came
close to "stuck" was the `.unwrap.name` → `nil` dead end in the IRB session
(03:41 entry), and the fix (`.graphql_name`) came from poking at the object
with `.class`/`.methods` in the console itself, not from opening gem source.
Final state: `bin/pull` (dynamic), `bin/countries`, `bin/generate` +
`bin/pull_typed` (typed) + `lib/pokemon_pull.rb`, two green specs, all in
`/tmp/claude/graph_weaver/junior-app-12`.
