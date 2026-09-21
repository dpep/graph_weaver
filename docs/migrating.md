# Migrating from graphql-client (or a hand-rolled client)

**The wire doesn't change.** The same query text goes out and the same JSON comes
back, so this is a sequence of small commits rather than a cutover: queries move
across one at a time while the old client keeps serving, and most of the spec
suite you already have keeps passing untouched.

Budget 3–4 weeks of one engineer for an app with ~40 queries and 25k lines of
code reading them — [what it costs](#what-it-costs) breaks that down. If the app
doesn't run Sorbet and has fewer than ten queries, don't migrate: the wins that
survive without `srb tc` are real, but they don't pay for a checked-in code
generator ([alternatives](alternatives.md#graphlient)).

## From graphql-client, in Rails

**Both gems stay in the Gemfile until the last commit.** `rails g
graph_weaver:install` boots the app to read your configuration, so an initializer
that still requires graphql-client has to keep resolving — remove the gem first
and the generator dies on `cannot load such file -- graphql/client`. Running the
two side by side is the right shape anyway.

1. **Install beside graphql-client**, pointed at the dump you already have:
   `rails g graph_weaver:install db/petstore_schema.json` ([a schema dump you
   already have](getting_started.md#a-schema-dump-you-already-have)). Commit that
   and nothing else.
2. **Adopt the dump.** It records no source url, so `schema:diff` and
   `queries:check` have no server to ask. `rake graph_weaver:schema:refresh`
   rewrites it from the client the app points at (or `URL=<your endpoint>` once)
   and records the provenance. Do it now: until you do, `queries:check` is
   re-reading the file it is meant to be checking against, and says so. It
   rewrites the file **in place, in graph_weaver's format** — pretty-printed
   introspection JSON with a `graph_weaver:` provenance key beside `data`.
   graphql-client goes on reading it, since `load_schema` hands the parsed hash
   to graphql-ruby and graphql-ruby takes `data` and ignores its siblings; a dump
   anything *else* reads is worth checking once.
3. **Register scalars and enums, and regenerate** — if the API declares any.
   Plenty don't: one whose leaves are all `String`, `Int`, `ID` and `Boolean` has
   nothing to register and skips this step whole. Registrations are baked into
   generated source, so one added later reaches nothing until the next
   `rake graph_weaver:generate` ([scalars](scalars.md)).
4. **Port one query end to end** — write the `.graphql` file, generate, rewrite
   its call site — and leave the specs alone. They pass untouched. That single
   commit is the proof for every one after it.
5. **Port the rest, one commit per query.** Each `Client.parse` constant stays
   where it is until its last caller is gone.
6. **Only now port the specs** to `graphql: :fake` ([testing](testing.md)). Keep
   webmock until the last wire-level stub is gone, and keep one spec that really
   serves HTTP.
7. **Delete graphql-client.** Last commit.
8. **Sigs through your own app are a separate project**, after all of the above —
   [the types stop where your sigs do](getting_started.md#the-types-stop-where-your-sigs-do)
   says what that work is.

Keep your own error classes. Translating `GraphWeaver::QueryError`,
`TransportError` and `ServerError` at one seam leaves a controller, its rescues
and their specs untouched ([errors](errors.md)). Keep your presenters too, and
your fixtures until step 6.

### Why app code and specs are separate commits

Because the wire is the same, a webmock suite doesn't notice which client sent
the request. Swap the client under an untouched suite and most of it stays green
— 18 of 22 stubbed examples in one migrated Rails app, same stubs, same JSON
fixtures; the four that failed were unit specs feeding a hand-rolled `Struct` to
a presenter. That is the difference between a reviewable migration and a big-bang
one.

## From a hand-rolled client

Same skeleton, three differences.

- **One branch, no seam.** There's no generator to keep bootable and a
  hand-rolled client is sixty lines, so running two of them side by side costs
  more than it saves.
- **Set the load order first**: `GraphWeaver.load_generated!` goes before your own
  requires ([not Rails?](getting_started.md#not-rails)). Add `rake` to the Gemfile
  while you're there.
- **Keep the old client's transport specs**, rewritten against a real
  `GraphWeaver.new(url, retries: 2)` with webmock. Retries, timeouts and backoff
  are the one thing fakes can't cover.

## What you delete

- **The retry loop.** A hand-rolled one usually retries everything, mutations
  included. `retries: 2` excludes mutations by default, honours `Retry-After`,
  and knows 408 and 429 ([retries](transports.md#retries)) — twenty lines gone and
  a correctness bug gone with them.
- **Scalar parsers.** `register_scalar("Money", Money)` is one line, and it
  deletes the `"USD 12.50".split` sitting in every place that parsed one. `Date`
  and `DateTime` need no registration at all ([scalars](scalars.md)).
- **Fragment unwrapping.** graphql-client masks a spread fragment's fields on the
  parent, so every call site reads `Petstore::PetFields.new(data.pet).name` and
  carries the parent alongside for the fields the fragment didn't cover. Generated
  structs inline the fragment, so it's `pet.name`; a fragment that is a whole
  selection becomes one shared Ruby type
  ([hoisting](generated_modules.md#a-shared-fragment-is-one-type)).
- **JSON fixtures and stub helpers.** `graphql: :fake` fabricates a
  schema-correct response and you pin the fields the example is about. Pins are
  schema vocabulary (`"Pet.species" => "DOG"`), so they survive query refactors,
  and they're spellchecked — a typo raises instead of leaving the example green
  against random data ([testing](testing.md)).

## The one behaviour change to plan for

**Enum drift is fatal.** A hand-rolled client hands you the raw string, so a value
the server added after you shipped falls through to whatever your code does with
an unknown one — commonly a `humanize`. A generated enum refuses instead: casting
raises and the whole response is lost, naming the value, the enum and the values
it knows about.

That is the right default for an API you own and a real risk for one you don't,
because it breaks on a day nobody deployed. Before you port a query over an enum
someone else can extend, register a fallback for it and unknown values land there
instead — [enums](scalars.md#enums-map-onto-your-own-tenum).

## What it costs

| | how it scales | ~40 queries, 25k lines |
|---|---|---|
| `.graphql` files and generating | sublinear — the second query costs a tenth of the first | 2–3 days |
| call sites | linear, and the bulk of it: every `data["x"]["y"]` becomes `x.y`, and every defensive `nil` guard either disappears or turns out to have been wrong | ~1 day per 3–4k lines of consuming code |
| specs | linear, and pleasant — the fixture-to-pin conversion is the same edit every time | ~2 days |
| sigs through your own app | the one that decides whether the migration paid off | weeks; a separate project |

Coming off graphql-client, run the new one behind the old for the first two
weeks. The wire compatibility makes that free.
