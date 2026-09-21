# Junior fragments log — graph_weaver: own-schema in-process, shared fragments, drift

Persona: a year into Rails, used GraphQL from a Python client, never seen this
gem. Checkout at 89ded3e (READ-ONLY, `path:` in the Gemfile). Toolchain:
`~/.rvm/wrappers/ruby-3.4.9/bundle exec ...`. App built at
`/tmp/claude/graph_weaver/round7/junior-fragments-app`. Sources: README.md and
docs/ only — never opened lib/. Skimmed `research/logs/junior-log-{2,8,10,11,13,14,15}.md`
and `research/migration-experiment.md` first, per the brief, to avoid
re-reporting; migration-experiment.md's finding 1/2 (object-fragment hoisting)
turned out to be exactly the gap 0.7.5 (in CHANGELOG.md, this checkout) fixed —
confirmed below, not re-reported.

2026-09-21T03:49:41Z — start. Read README.md, docs/getting_started.md,
docs/generated_modules.md, docs/testing.md, docs/scalars.md in full before
writing any code (~25 min of the session). Decided the schema shape from
"Anatomy"/"Selections"/"A shared fragment is one type"/"Abstract types" in
generated_modules.md, the two testing tables in testing.md, and the Money
"bare decimal string" example in scalars.md.

2026-09-21T04:05Z — first fully green `bundle exec rspec` (9 examples). ≈16
minutes of session wall-clock from opening docs/getting_started.md to a green
suite, most of it reading, not typing — the generator, `rake
graph_weaver:generate`, and every spec passed on the first attempt once
written. That is itself the headline finding: nothing here needed a second
try except the two deliberate probes below.

## What I built

- `PetstoreSchema` (app/graphql, plain graphql-ruby): `Species` enum (DOG,
  CAT, BIRD), `Money` scalar (bare decimal string, single-currency USD —
  the exact shape docs/scalars.md recommends for "reach for that only when
  the API really is single-currency"), `Pet` and `Shelter` objects, an
  `Animal` interface with two implementations (`Pet`, `StrayAnimal`), and
  `adoptPet` mutation.
- `rails g graph_weaver:install PetstoreSchema` — the in-process form,
  first try, output matched docs/getting_started.md's transcript exactly.
- Fragments: `PetFields on Pet` (object), `AnimalFields on Animal`
  (interface, with `... on Pet` / `... on StrayAnimal` type conditions plus
  interface-level fields — the dispatch-requiring shape, not the trivial
  "no conditions" collapse).
- Four operations: `pet.graphql` and `shelter.graphql` both spread
  `...PetFields`; `animals.graphql` spreads `...AnimalFields`;
  `adopt_pet.graphql` is the mutation (plain selection, no fragment).
- `Money` (app/models/money.rb) — tiny value object with `.parse`/`#to_s`/
  `eql?`/`hash`, registered via `GraphWeaver.register_scalar("Money", Money)`.
- `GraphWeaver.register_enum("Species", fallback: true)` for the drift
  exercise.
- `PetPresenter` (app/models/pet_presenter.rb) — `sig { params(pet:
  GraphQLTypes::PetFields).void }`, the hoisted type, not a per-query one.
- `PetPolicy.exotic?` — `case` over `GraphQLTypes::Species` with an `Other`
  branch (the fallback member) before `T.absurd`.
- Specs: `graphql: :fake` (pet_query_spec.rb), `graphql: :in_process`
  (animals_query_spec.rb, pet_fields_hoisting_spec.rb), `graphql: :wire`
  (wire_spec.rb), and `client.check_query` (check_query_spec.rb). 9 examples,
  0 failures, plus two one-off probes below (not kept in the suite, or kept
  and asserted differently — noted where).

No static Sorbet (no `srb tc`) in this app — out of scope for the exercise
and not requested by the brief; `sorbet-runtime` came along as
graph_weaver's own hard dependency, so the `sig`s above are runtime-checked
only. Ruby 3.4.9, Rails 8.1.3.1, graphql 2.6.10, graph_weaver 0.7.5 (this
checkout, `path:`).

## The drift exercise (Species gains RABBIT, no regenerate)

Baseline, all clean:
```
rake graph_weaver:verify        -> generated queries up to date            (0)
rake graph_weaver:schema:diff   -> app/graphql/schema.json matches PetstoreSchema (0)
rake graph_weaver:queries:check -> every query validates against the schema (0)
```

Added `value "RABBIT"` to `Types::Species` and a pet whose `species` is
`"RABBIT"`, in the *live schema class only* — no `schema:refresh`, no
`generate`, no touching `app/graphql/schema.json` or `generated/`. Reran the
same three tasks with nothing else changed:

```
$ rake graph_weaver:verify
the dump is behind the schema — app/graphql/schema.json no longer matches
PetstoreSchema (1 change, 0 breaking). Run rake graph_weaver:schema:refresh,
then rake graph_weaver:generate — rake graph_weaver:schema:diff names what
moved.
exit 1

$ rake graph_weaver:schema:diff
app/graphql/schema.json vs PetstoreSchema: 1 change, none breaking
other:
  Species.RABBIT  enum value added
app/graphql/schema.json is stale — the schema behind it has drifted (rake graph_weaver:schema:refresh)
exit 1

$ rake graph_weaver:queries:check
every query validates against the schema
exit 0
```

`verify` catching this surprised me until I reread
getting_started.md#your-apps-own-schema-in-process: "that's what makes `rake
graph_weaver:verify` a deterministic CI check, and why it **fails** when the
dump has fallen behind the class." I had assumed (wrongly, from the earlier
"codegen reads the committed dump, never the live class" sentence) that
`verify` was dump-only, symmetric with `queries:check`/`schema:diff`'s
dump-vs-server split. It isn't, for an in-process schema specifically —
`verify` gets an extra, free comparison against the live class that a remote
API doesn't offer. `queries:check` staying green makes sense in hindsight:
the drift is a new enum *value*, and no `.graphql` file names it, so nothing
a query selects broke.

Runtime, still unregenerated:
```ruby
PetQuery.execute!(id: "4").pet.species   # => GraphQLTypes::Species::Other
PetPolicy.exotic?(_)                     # => false, no raise
```
and `log/development.log` carries exactly the documented debug line:
`GraphQLTypes::Species absorbed "RABBIT" into Other`. `register_enum(...,
fallback: true)` did what scalars.md says it does, verbatim.

One thing I did not expect and had to go looking for: **`:fake` will happily
fabricate the *unrecognized* value too.**
```ruby
FakeClient.new(overrides: {"Pet.species" => "RABBIT", "Money" => "1.00"})
PetQuery.execute!(id: "1", client: fake).pet.species  # => GraphQLTypes::Species::Other
```
Nothing in testing.md says pins are checked against declared enum *values*
(only that pin *keys* — type/field names — are schema vocabulary, checked
and spellchecked). So a stale dump doesn't stop you from pinning a value it
doesn't know about, and the fallback mechanism absorbs it exactly as it
would a real server's drift. That means you can rehearse "the server adds a
species tomorrow" entirely inside `:fake`, today, which is a genuinely nice
emergent property — filed under "easier than expected," not a bug.

## Ranked findings

1. **paper cut — `graphql: :wire`'s refusal fires in a `before`-hook, so you
   can't `expect { ... }.to raise_error` it from inside the example.**
   Repro (deleted from the final suite, but reproduced live):
   ```ruby
   RSpec.describe "wire probe", graphql: :wire do
     it "..." do
       expect { PetQuery.execute!(id: "1") }.to raise_error(GraphWeaver::Error, /.../)
     end
   end
   ```
   Message (verbatim, captured via a plain failing spec and via
   `log/test.log`):
   ```
   graphql: :wire runs your own transport against your resolvers, so it
   needs the endpoint that transport posts to — and GraphWeaver.client is
   GraphWeaver::Client, which posts to none. There is nothing to serve.
   Point the client at a url (GraphWeaver.new("https://api.example.com/graphql")),
   or tag the example graphql: :in_process or graphql: :router — they run
   above the wire.
   ```
   The refusal itself is documented and correct, and is already a declined
   item in follow-ups.md ("`:wire` on an app where NO graph posts anywhere:
   still refused whole (by design)") — not re-reporting *that*. What's new:
   the refusal happens in the tag's own `before(:each, graphql: :wire)`
   hook, before my example body runs, so RSpec marks the example failed
   before my `expect {}.to raise_error` block is ever reached — there's no
   way to assert "this refuses" as a passing spec without stepping outside
   the tag (a plain `rails runner`, or catching it some other way I didn't
   find without opening lib/). Small, but it means the one shape of test a
   junior would most want to write here — "assert my app can't accidentally
   ship `:wire` on a graph with nothing behind it" — isn't writable as a
   green spec with the documented API alone.
   *What a fix would look like:* none needed for the refusal itself; maybe a
   documented `GraphWeaver::Testing.wire_target(client, graph:)` predicate
   or similar for asserting the precondition without touching an example's
   `before` chain. Files: none in the app; this is a documentation/testing-API
   observation about the gem.

2. **doc gap (minor) — the two "which live class serves this" derivations
   for `:in_process` and `:wire` are not equally lenient, and nothing says
   so side by side.** `:in_process`'s own derivation (testing.md#nothing-to-
   configure) explicitly includes "the loaded class that defines everything
   the schema declares" as a fallback — so my `graphql: :in_process` specs
   found `PetstoreSchema` with zero configuration. `:wire`, told to serve a
   graph whose client posts to a stubbed url, does **not** take that same
   fallback: with nothing else set it served a *fake* behind the wire and
   only **warned**, verbatim:
   ```
   :wire serving a fake at https://petstore.example.test/graphql —
   PetstoreSchema is loaded and nothing named it, so your resolvers did not
   run. To serve them, name it: GraphWeaver::Testing.config.schema = PetstoreSchema
   ```
   Setting that one line made it behave like `:in_process` behind the wire.
   The warning names the exact fix (this is a strength, not a paper cut on
   its own), but I only found the asymmetry because I happened to try
   `:in_process` first and compare — a reader going in through
   `docs/testing.md#over-the-wire--graphql-wire` alone would plausibly reach
   the "fake behind the wire" case, get all-green (`:fake` succeeded once I
   also pinned `Money`), and never learn their real resolvers didn't run,
   until the log warning is spotted separately. *What a fix would look
   like:* one sentence in testing.md#over-the-wire cross-referencing the
   "loaded class" derivation `:in_process` already documents, noting `:wire`
   deliberately doesn't take it. Files: docs/testing.md only.

3. **quiet where it should speak (very minor) — `:fake`'s pin validation
   checks the *coordinate*, not the *enum value*.** `graphql_fake("Pet.species"
   => "RABBIT")` (or `FakeClient.new(overrides: ...)`) is accepted even
   though the dump's `Species` enum has no `RABBIT` member — it silently
   routes through the `fallback: true` catch-all instead of refusing the pin
   the way a typo'd *field* name is refused. Not a bug against the
   documented contract (pins are schema-vocabulary-checked, and nothing
   promises to validate an enum member's spelling), and arguably a feature —
   see "easier than expected" above — but the asymmetry with the sibling
   promise ("`\"Person.nmae\"` raises rather than quietly pinning nothing")
   is worth a line in scalars.md's fallback section or testing.md's pins
   section, since right now discovering it requires trying it. *What a fix
   would look like:* a doc sentence, not a code change — this is a place
   where "refuse rather than guess" was deliberately not applied to enum
   *values*, and saying so once would save the next reader the same
   30-second detour I took. Files: docs/scalars.md
   (#values-the-server-hasnt-told-you-about-yet) or docs/testing.md (#pins).

Nothing above rises to publish-blocker or silent-wrong-answer — every path
that could have produced a silently wrong result (drifted enum, hoisted
fragment sharing, interface dispatch, custom scalar round-trip) instead
refused loudly at generation time, failed `verify` immediately, or degraded
predictably into the documented `Other` catch-all with a debug line naming
what happened.

## What was easier than expected

- **Object-fragment hoisting just worked.** This is exactly
  migration-experiment.md's finding 1/2 (a shared fragment on `Pet` used to
  generate two unrelated structs; the fix — noted in this checkout's
  CHANGELOG.md under v0.7.5 — hoists it into `GraphQLTypes::PetFields`
  either way). I wrote the presenter against the hoisted type on the first
  attempt, no type-alias workaround needed, and verified with `.equal?`
  that `PetQuery::PetFields`, `ShelterQuery::PetFields`, and
  `GraphQLTypes::PetFields` are the literal same object.
- **The interface-fragment dispatch shape (`... on Pet` / `... on
  StrayAnimal` inside a shared fragment) generated the `T.any(Pet,
  StrayAnimal, Other)` dispatch module correctly on the first
  `rake graph_weaver:generate`**, including catching my *first* draft
  (missing `__typename`) at generation time with the exact, actionable
  message quoted in finding 2's sibling case — no runtime surprise.
- **The generator's in-process transcript matched docs/getting_started.md
  byte for byte** — same five files, same wording, same "Testing: add
  `require \"graph_weaver/rspec\"`..." reminder (which I needed, since
  `rspec-rails` wasn't installed yet at generator time).
- **`register_scalar`/`register_enum` needing `to_prepare`** was exactly one
  paragraph in getting_started.md's step 2 and I got it right without a
  failed boot — no NameError, no autoloading surprise.
- **Production boot (`RAILS_ENV=production rails zeitwerk:check`) was
  clean** with the mixed layout (graphql-ruby server types under
  `app/graphql/types/`, graph_weaver's own `queries/`, `fragments/`,
  `generated/` siblings under `app/graphql/`) — no Zeitwerk collision
  between the two.

## Every generated name I had to type in app code, and could I guess it

| name | where | guessable from the query alone? |
|---|---|---|
| `GraphQLTypes::PetFields` | presenter sig | yes, once you've read "A shared fragment is one type" — the rule (`GraphQLTypes::<FragmentName>`) is one sentence and I typed it correctly first try |
| `GraphQLTypes::Species` | policy sig | yes — "one enum, one Ruby type ... named for the enum" |
| `GraphQLTypes::Species::Dog/Cat/Bird/Other` | policy `case`/spec | yes for the declared members (mechanical PascalCase of the wire value); `Other` needed the scalars.md fallback section, not guessable from the schema alone |
| `GraphQLTypes::AnimalFields::Pet` / `::StrayAnimal` | spec assertions | yes, but only after reading "Abstract types" — the rule (container named for the fragment, members named for their `... on Type` condition) is two facts you have to already know are related |
| `PetQuery`, `ShelterQuery`, `AnimalsQuery`, `AdoptPetMutation` | spec/console | yes, mechanically, from the file name naming rule |
| `PetQuery::PetFields` (checked, not used) | — | equally guessable as the `GraphQLTypes::` spelling, and I used the latter since it says "shared" more honestly in a presenter's sig |

No name in this exercise required opening generated code to discover — every
one was predictable from generated_modules.md's naming rules read once,
which matches this doc's own claim about itself.

## Time and where I read source

- Docs read in full before writing any code (README.md,
  getting_started.md, generated_modules.md, testing.md, scalars.md) — no
  lib/ opened at any point, confirmed by not needing to once the schema
  design was settled.
- Read migration-experiment.md and 7 prior junior-log files (~5 min) before
  starting, specifically to avoid re-reporting the object-fragment-hoisting
  gap — turned out to be fixed in this checkout, which is itself evidence
  the earlier finding mattered.
- Two probes that were genuine "I don't know what happens" moments, not
  scripted: the `:wire`-on-nothing-posts refusal (already declined, ~5 min
  including reading the exact wording back against follow-ups.md), and the
  missing-`__typename` generation refusal (~3 min, restored immediately
  after confirming the message).
- No dead end ran past its 15-minute box; the closest was working out how
  to make `:wire` serve real resolvers rather than a fake (~10 min,
  documented as finding 2 rather than abandoned).

## Would I have stayed?

Yes, and with more confidence than I expected going in. The one property
that matters most for a GraphQL client coming from a hand-rolled Python one
— "the type I get back for a shared shape is the type I asked the docs for"
— held on the first try for both an object fragment and an interface
fragment, which is exactly the case the checkout's own CHANGELOG says was a
recent, real gap. The three findings above are all in the "read one more
sentence of docs" tier, not "the feature doesn't do what it says": nothing
silently mis-cast a value, and the one place forward-compat with an
unannounced schema change mattered (`fallback: true`), it worked exactly as
documented, down to the debug log line. My only real friction was
`:wire` on a schema that has no transport of its own to test — which the
project has already thought about hard enough to leave a paper trail
(follow-ups.md) rather than pretend it's solved.
