# Migrating two real-shaped codebases onto graph_weaver

Two scratch projects, built to a spec, run green, committed, then migrated on a
branch so the diff *is* the migration. Both are under
`/tmp/claude/graph_weaver/migrate/`, each with a `main` baseline commit and a
`migrate-graph-weaver` commit on top. Everything below was executed, not
inspected; error text is verbatim.

Gem under test: graph_weaver 0.7.4 (worktree at `ed3869c`), via `path:`.

---

## The two codebases

### A. `menagerie` — Rails 8.1, github/graphql-client

A Rails app that is a pure client of a "Petstore" GraphQL API. The idiomatic
graphql-client shape: `GraphQL::Client::HTTP`, `GraphQL::Client.load_schema` off
a committed `db/petstore_schema.json`, `Client.parse` constants living in the
service objects that use them, webmock + hand-written JSON fixtures in specs.

- 679 hand-written lines; 22 examples, green with no network.
- 3 queries + 1 mutation; a `PetFields` fragment spread by two of them; enum
  `Species`; custom scalars `Date` and `Money` (`"USD 25.00"`); a nullable
  `Pet.owner` the code branches on; `PetstoreErrors::{QueryFailed,Unavailable}`
  over a GraphQL `errors` entry and an HTTP 5xx; a presenter, two service
  objects, a controller.
- Baseline `44411d7`, migration `43c56ec`.

### B. `atlas` — plain Ruby, hand-rolled `Net::HTTP` client

A non-Rails service talking to **two** endpoints: the real public Countries API
(`countries.trevorblades.com`, no auth — it actually runs) and an internal
"Fulfillment" API whose SDL is checked in at `schema/fulfillment.graphql`.
`Atlas::GraphqlClient#query(document, variables)` posts JSON, retries twice on
timeouts and 5xx, raises `Atlas::TransportError` / `Atlas::GraphqlError`;
responses are Hashes consumed with `dig`; two queries are `.graphql` files read
at boot with the shared fragment text *concatenated on*, the rest are heredocs.

- 783 hand-written lines + 9 JSON fixtures; 22 examples (1 tagged `:live`,
  excluded by default), green.
- 3 Countries queries + 3 Fulfillment operations incl. a mutation; enum
  `ShipmentStatus`; scalars `DateTime` and `Money`; nullable `Shipment.carrier`;
  a quote-builder service object and a serializer.
- Baseline `89ff2cf`, migration `89ada88`.

---

## The migration, in numbers

|  | menagerie | atlas |
|---|---|---|
| hand-written files touched | 28 | 39 |
| hand-written lines | **+217 / −269** (net −52) | **+382 / −617** (net −235) |
| deleted outright | the graphql-client initializer, `spec/support/petstore_stubs.rb`, 3 JSON fixtures | `graphql_client.rb` (62), `documents.rb` (29), its spec (71), 9 JSON fixtures |
| added | 4 `.graphql` + 1 fragment (48 lines), `config/initializers/graph_weaver.rb` (14) | 6 `.graphql` + 2 fragments (65 lines), `lib/atlas/graphql.rb` (31), `Rakefile` (5), `money.rb` (32) |
| generated + committed | 745 lines, 7 files | 1177 lines, 9 files |
| schema artifacts | reused the existing dump | +32 KB introspected `schema/countries.json` |
| examples | 22 → 23 | 22 → 20 |
| `srb tc` | added, clean | added, clean |

Both end green on `rspec`, `srb tc`, and `rake graph_weaver:verify`; `atlas`
also on `rspec --tag live` and `bin/atlas US` against the real API.

## What carried it

Three things did most of the work, and they are worth naming because none of
them is the headline feature.

1. **The wire stayed the same, so the spec suite didn't have to move with the
   app code.** In menagerie I swapped the client and ran the old suite: **18 of
   22 webmock-stubbed examples passed unchanged**, same stubs, same fixtures.
   The four failures were a presenter unit spec feeding a hand-rolled `Struct`.
   That makes "port the app code" and "port the specs" two independent commits,
   which is the difference between a reviewable migration and a big-bang one.
2. **`register_scalar` deleted code rather than adding config.** `Money` is one
   line; it removed the same three-line `"USD 12.50".split` parser from two
   places in atlas and a `Date.parse` from menagerie's presenter. `Date` and
   `DateTime` needed nothing at all.
3. **The generator did the Rails wiring correctly, first try.** Initializer,
   directories, `graphql.config.yml`, `.gitattributes`, the `AllCops: Exclude`
   append, and `require "graph_weaver/rspec"` inserted into an existing
   `rails_helper.rb`. Nothing to undo.

---

## Findings

Ordered by severity. **gap** = no way to do X, **friction** = a way exists but
the path was rough, **doc** = a claim false or missing, **win** = notably better.

### 1. gap / high — a shared fragment on an object type gets no shared Ruby type

`PetFields` is spread by `pet.graphql` and `shelter.graphql`. It generates
`PetQuery::Result::Pet` and `ShelterQuery::Result::Shelter::Pets`: two unrelated
`T::Struct`s with identical props. Anything that works on "a pet" — a presenter,
a serializer, a policy — can no longer name its argument's type.

Hoisting exists, but only for abstract types:
`docs/generated_modules.md:418` — *"When a whole union field is selected as one
named shared fragment … that type is hoisted once into `GraphQLTypes`."* Object
fragments get nothing, and nothing in the fragments section of
`getting_started.md` says so.

What I did: a type alias in the presenter.

```ruby
Pet = T.type_alias { T.any(PetQuery::Result::Pet, ShelterQuery::Result::Shelter::Pets) }
```

It typechecks and it catches typos, but it is a list the app maintains, and it
grows by one member every time another query selects a `Pet`. On a 10×
codebase this is the thing that would hurt most: the fragment is *the* unit of
reuse in a GraphQL client, and on this side of the wire it isn't a unit at all.

### 2. gap / high — `extend_type` with an `abstract!` mixin breaks `srb tc` on partial selections

This is the documented answer to finding 1, and I tried it before the union
alias. `docs/generated_modules.md` (Type helpers): *"a **named** module can
carry real sigs, though, by declaring the fields it leans on: `abstract!` plus a
`sig { abstract.returns(String) }; def name; end` … and the struct's `const`s
satisfy them — generation declares the override Sorbet demands there."*

It does — for structs that selected those fields. `extend_type("Pet", …)` mixes
into **every** struct generated from `Pet`, including
`RosterQuery::Result::Pets` (`{ id name species }`) and
`AdoptPetMutation::…::Pet` (`{ id name owner { name } }`). Generation succeeds
silently; `srb tc` then says:

```
generated/…/roster_query.rb:31: Missing definitions for abstract methods in `RosterQuery::Result::Pets`
    app/lib/pet_fields.rb:20: `adoption_fee` defined here
    app/lib/pet_fields.rb:17: `birthday` defined here
    app/lib/pet_fields.rb:23: `tags` defined here
```

So the abstract-sig mixin is usable only when every query selecting that type
selects the same fields — i.e. when you didn't need a fragment. The doc states
the mechanism without its precondition, and the failure surfaces two tools away
from the cause.

### 3. gap / medium — a type-helper mixin can't name a generated constant

Still inside finding 2's attempt: the natural sig for the enum field is

```ruby
sig { abstract.returns(GraphQLTypes::Species) }
```

and `rake graph_weaver:generate` dies on it:

```
NameError: uninitialized constant PetFields::GraphQLTypes
  sig { abstract.returns(GraphQLTypes::Species) }
```

Registrations must load before generation; the enum the sig names is generation's
*output*. A mixin over a type with an enum field therefore can't be typed at all,
only `T.untyped`. Circular in a way no amount of care at the call site fixes.

### 4. friction / high — the static payoff stops at the first sig-less method in your app

This is the finding I'd most want a migrating team to know, because it is the
gem's whole pitch and it is conditional.

The README's example is a direct call and behaves exactly as advertised —
verbatim, from menagerie:

```
app/services/pet_directory.rb:9: Method `nmae` does not exist on `PetQuery::Result::Pet`
app/services/pet_directory.rb:10: Method `name` does not exist on `NilClass` component of `T.nilable(PetQuery::Result::Pet)`
```

Both the typo and the nullability, with an autocorrect. But a layered app does
not call generated modules from the place that reads the fields, and I got
**"No errors! Great job."** from all three of these, each with a live typo in it:

- `@pet.nmae` in a presenter whose `initialize` has no sig (menagerie);
- `shelter.nmae` where `shelter` came back through a sig-less `petstore { … }`
  rescue wrapper (menagerie);
- `country.nmae` where `country` came from `Atlas::Geo#country_profile` — even
  **after** I gave that method a full sig, because `@geo` itself was untyped
  (atlas).

The types survive only when *every* hop is sig'd: the producing method, the
wrapper it passes through, and the constructor that stored the collaborator.
Two recipes that worked, both worth being in the docs:

```ruby
# a rescue wrapper that keeps the block's type
sig do
  type_parameters(:T).params(blk: T.proc.returns(T.type_parameter(:T)))
   .returns(T.type_parameter(:T))
end
def petstore(&blk) = yield
```

```ruby
# a service boundary — note what the app now has to spell
sig { params(code: String).returns(T.nilable(Countries::CountryProfileQuery::Result::Country)) }
def country_profile(code) = …
```

Cost on atlas: sigs on 6 service methods plus 2 constructors before one typo in
`QuoteBuilder` was caught. `docs/alternatives.md` is admirably honest that
Sorbet-less apps get little; nothing says a Sorbet app with service objects
gets little too, until it pays for the sigs.

### 5. friction / medium — `schema:refresh` refuses a graph it has a client for, and exits 1

atlas has two graphs: `:geo` (dump introspected from a url) and `:fulfillment`
(hand-maintained SDL). Both declare a `client`. One task:

```
$ rake graph_weaver:schema:refresh                                  # exit 1
/…/schema/fulfillment.graphql records no source url — pass one: rake graph_weaver:schema:refresh URL=https://api.example.com/graphql (if this app serves the schema itself, point GraphWeaver.client at the class and the dump is rebuilt from it — see docs/getting_started.md#your-apps-own-schema-in-process)
graph :geo
refreshed schema/countries.json from https://countries.trevorblades.com/graphql
graph :fulfillment
```

Neither offered fix applies: there is no url to pass (nothing serves it) and the
SDL is the source of truth, not a cache. `docs/getting_started.md` says the
opposite of what happened — *"Give each the file you want and a `client` that
can fetch it: `rake graph_weaver:schema:refresh` introspects each graph's client
into its own dump"*. I checked: with the file **deleted**, the graph's client
*is* used (it then failed on DNS, as it should). So the rule is "the client is
used only when no dump exists", which is neither documented nor guessable, and
an app that mixes an introspected graph with a hand-maintained one can never run
the task green.

### 6. friction / medium — an inherited dump makes `schema:diff` refuse and `queries:check` quietly answer a weaker question

Same situation, different message:

```
db/petstore_schema.json records no source url — it wasn't introspected from one. Pass transport:, or rebuild it from the schema class that produced it.
```

`schema:refresh`'s message in the same state names `URL=…`; this one names a
library keyword and a schema class. **Every team migrating off graphql-client
lands here**, because a committed introspection dump with no provenance is
exactly what graphql-client's recommended setup leaves you, and
`schema:diff` — the check that tells you the server moved — stays dark until
someone works out that `rake graph_weaver:schema:refresh URL=…` re-adopts the
dump.

Worse, its neighbour in the same CI chain doesn't say anything at all.
`docs/getting_started.md` describes `queries:check` as *"It re-introspects the
recorded url (without rewriting the dump) and validates every `.graphql` file
against the schema as it is right now"*. With no recorded url, against an
endpoint that does not resolve, it exits 0 in under a second:

```
$ rake graph_weaver:queries:check                                   # exit 0
every query validates against the schema
```

It quietly validated against the committed dump instead — which is a useful
check, but it is `verify`'s question, not this one's, and the output gives a CI
log no way to tell which was asked. A green chain here means less than the docs
promise, silently. Refusing (as `schema:diff` does) or saying "validated against
the dump — no source url to re-introspect" would both be fine; answering a
weaker question in the same words is the one option that misleads.

### 7. friction / medium — the generator needs a bootable app

`rails g graph_weaver:install` boots the app, so you cannot remove
graphql-client first:

```
cannot load such file -- graphql/client (LoadError)
  from /…/config/initializers/petstore.rb:1
```

Obvious in hindsight, and the answer (both gems in the Gemfile until the last
commit) is the right migration shape anyway — but it is the first thing you hit
and nothing says it.

### 8. friction / medium — non-Rails load order bites app code that names a generated enum

`getting_started.md#not-rails` gives `GraphWeaver.load_generated!` but not where
it goes relative to your own requires. Put it last (as in the docs' snippet,
after the client assignment) and any app constant built from a generated enum —
`STATUS_LABELS = { ShipmentStatus::Pending => … }` — raises `NameError`. My first
dodge (build the table lazily behind a local) then earned four
`Dynamic constant references are unsupported` errors from `srb tc`. The fix is
one line of ordering — `load_generated!` *before* the app's own requires — and it
belongs in that section.

### 9. gap / low-medium — fragments can't be scoped to a graph

A graph block takes nine things; `fragments` isn't one. atlas's two graphs share
one global `GraphWeaver.fragments_paths`, so `CountryBasics` (Countries) and
`ShipmentFields` (Fulfillment) live in one flat namespace that must stay unique
across unrelated schemas. Fine at two graphs, a footgun at ten.

### 10. friction / low-medium — `unused` doesn't sweep extensionless Ruby

```
queries/geo/country_profile.graphql: Country.capital — selected, never read
queries/geo/country_profile.graphql: Country.emoji — selected, never read
```

Both are read — by `bin/atlas`, which has no `.rb` extension. In a non-Rails
project that is where the entry points live. The task's footer covers "a file
type it doesn't sweep", but `bin/*` is Ruby, not an exotic template.

### 11. friction / low — `unused`'s serializer attribution crosses queries

```
PetQuery: every prop counted as read — handed whole to a serializer at app/services/pet_directory.rb:26, as `pet`
  pets.map { |pet| { id: pet.id, name: pet.name, species: pet.species.serialize } }
```

Line 26 is in `#roster`, which runs `RosterQuery`. The block-local `pet` was
credited to `PetQuery` as well. Harmless (it only ever under-reports), but the
line it quotes has nothing to do with the query it names.

### 12. friction / low — three small message/spelling mismatches

- The fake's refusal says `overrides: { "Money" => … }`; inside an rspec example
  the spelling is `graphql_fake("Money" => …)`. Both documented, but the message
  names the one you aren't holding.
- `InputError` uses the Ruby prop name — `weight_grams: expected an Int` — where
  the thing you'd grep for in the `.graphql` is `weightGrams`. (`#coordinate`
  carries the wire name; the message doesn't.)
- Once your own boundary has a sig, sorbet-runtime's plain `TypeError` fires
  *before* `GraphWeaver::InputError`, so the library's structured, i18n-able
  input error never reaches a typed caller. Worth a sentence in `errors.md`.

### 13. behaviour change / medium — enum drift is now fatal where it used to degrade

atlas humanised any unknown status (`"LOST_IN_SPACE"` → `"Lost in space"`);
menagerie's presenter had the same fallback. Post-migration both raise:

```
GraphWeaver::CastError: failed to cast response into PetQuery::Result::Pet: species: "AXOLOTL" is not a GraphQLTypes::Species — expected one of: BIRD, CAT, DOG; a value the server added since you generated needs a regenerate, or register_enum fallback: to absorb them
```

Excellent message, and the strictness is defensible — but `fallback:` is only
available on a **registered** enum, so buying forward-compat means hand-writing
a `T::Enum` you otherwise never needed, for every enum you want to be lenient
about. For a client of someone else's API that adds enum values, that is a real
cost, and it is the one behaviour change in either migration that could take
production down on a day nobody deployed.

### Wins, stated once

- **win / high — data masking is gone.** graphql-client makes a spread
  fragment's fields unreachable on the parent: `Petstore::PetFields.new(data.pet).name`
  at every call site, with the parent carried alongside for `owner`.
  graph_weaver inlines the fragment into the struct. Deleting that wrapper was
  the single nicest moment of either migration.
- **win / high — fakes replaced every fixture.** 12 JSON fixtures and two stub
  helpers across the two apps, gone, for `graphql: :fake` plus pins. The pins are
  schema vocabulary (`"Pet.species" => "DOG"`), so they survive query refactors,
  and they're spellchecked — a typo raises instead of leaving the example green
  against random data. `fake.requests.first[:variables]` replaced webmock body
  assertions one-for-one.
- **win / medium — `retries:` beat the hand-rolled retry on semantics.** atlas's
  own retry looped on 5xx and timeouts for *everything*, mutations included.
  `retries: 2` excludes mutations by default, honours `Retry-After`, and knows
  429/408. Twenty lines deleted and a correctness bug fixed by deletion.
- **win / medium — errors that name the fix.** `schema:refresh`'s `URL=`
  message, the enum-drift message above, and:

  ```
  can't fabricate a Money at pet.adoptionFee: it deserializes into Money, and only you know what wire value that accepts. Pin the type — overrides: { "Money" => ... } — or this one field: overrides: { "Pet.adoptionFee" => ... }. Suite-wide, that's GraphWeaver::Testing.config.overrides.
  ```

  I fixed all three without opening a doc.
- **win / low — the mutation is where the types pay off most.** `AdoptionInput`
  as a generated `T::Struct` with required/optional falling out of the schema
  caught a `nil` adopter name before the request left the process. The
  hand-rolled version posted it and let the server decide.

---

## The migration path I'd recommend

### For a graphql-client Rails app (shape A)

Run both clients side by side; the wire compatibility makes it safe and the
generator forces it anyway.

1. Add `graph_weaver` **beside** `graphql-client`. Run
   `rails g graph_weaver:install <your existing schema.json>` — the
   "[a schema dump you already have](docs/getting_started.md)" path — and commit
   that alone.
2. Immediately fix the provenance: `rake graph_weaver:schema:refresh URL=<your
   endpoint>`, so `schema:diff` and `queries:check` work. Do it now, not later
   (finding 6).
3. Register scalars and enums, and *re-run generate*, before porting any code.
   A missing registration is only loud at generation time.
4. Port **one** query end to end: `.graphql` file, generate, rewrite its call
   site, leave the specs alone. They should pass untouched. That single commit
   is the proof for the rest.
5. Port the remaining queries, one commit each. Leave the `Client.parse`
   constants in place until their last caller is gone.
6. Only now port the specs to `graphql: :fake`. Keep webmock until the last
   wire-level stub is gone; keep one `:wire`-ish transport spec forever.
7. Delete graphql-client. Last commit.
8. Sorbet, if you have it, is a **separate project** after all of the above —
   see the effort note.

Keep: your error classes (translating `GraphWeaver::{QueryError,TransportError,
ServerError}` at one seam kept menagerie's controller and its specs untouched),
your presenters, your fixtures until step 6.

### For a hand-rolled client (shape B)

Same skeleton, two differences.

- **Decide the fragment question before you write the first `.graphql` file.**
  With a hand-rolled client a fragment is just text you concatenate, so your app
  has exactly one shape for "a pet". After migration it has one per query
  (finding 1). If the same fragment feeds three or more consumers, plan for the
  union alias — or keep a hand-written value object and build it from each
  struct, which is duplication but a stable interface.
- **Set the load order first** (`load_generated!` before your own requires,
  finding 8), and add `rake` to the Gemfile.

Don't run two clients side by side here: there's no generator to satisfy and a
hand-rolled client is 60 lines, so a single branch is cheaper than a seam. Do
keep the old client's *specs* for the transport behaviours you configured
(retries), rewritten against a real `GraphWeaver.new(url, retries: 2)` with
webmock — that's the only part fakes can't cover.

If the app is **not** a Sorbet shop and has fewer than ~10 queries: don't
migrate. `docs/alternatives.md` already says this and it held up. The wins that
survive without `srb tc` — fakes, scalar registration, the retry, the error
hierarchy — are real but are not worth a checked-in code generator; graphlient
gets you most of them.

### Effort at 10× (say 40 queries, 25k lines of app code)

Both of mine took roughly a focused day each, including learning the library.
Scaling:

- **Queries: sublinear.** They're mechanical (`.graphql` file + regenerate) and
  the second one costs a tenth of the first. Budget 2–3 days for 40.
- **Call sites: linear, and the bulk.** Every `data["x"]["y"]` becomes
  `x.y`, and every `nil`-guard you wrote defensively either disappears or turns
  out to have been wrong. Budget ~1 day per 3–4k lines of consuming code.
- **Specs: linear but pleasant.** The fixture-to-pin conversion is the same edit
  every time. ~2 days.
- **Fragment types (finding 1): the wild card.** On a codebase with one shared
  `UserFields` fragment spread by 20 queries, the union alias is untenable and
  `extend_type` is unusable if the selections differ. Budget a week and a design
  decision, or plan to keep hand-written value objects at that boundary.
- **Sorbet (finding 4): a separate project, and the big one.** Generating types
  is a day; *collecting* on them means sigs through every service, presenter and
  constructor between the query and the field access. On 25k lines that is weeks,
  and it is the work that decides whether the migration was worth doing at all.

Total: **3–4 weeks of one engineer for the migration proper**, plus the Sorbet
adoption if it isn't already there. Run it behind the old client for the first
two weeks; the wire compatibility makes that free.

---

## The three changes that would have made the biggest difference

**1. Give an object-type shared fragment one Ruby type.** This is finding 1 and
finding 2 together, and it is the only thing in either migration that made me
write code I'd be embarrassed by. The union in `docs/generated_modules.md:418`
already establishes the mechanism and the naming rule: a whole field selected as
one named shared fragment is hoisted into `GraphQLTypes` under the fragment's
name, and each query aliases it. Extend exactly that to object types — when a
selection set is `{ ...Frag }` and nothing else, generate
`GraphQLTypes::Frag` once and alias it from each query, so `PetFields` is a type
an app can name. It preserves the position-determined naming property (the name
comes from the fragment, which is a source fact), it's opt-in by how you write
the query, and it makes the fragment the unit of reuse on both sides of the
wire. If that's too large, the fallback is much smaller and still valuable:
at generation time, when a registered `abstract!` mixin's declared methods
aren't all selected by a struct it is about to be mixed into, **refuse** and name
the query, the struct and the missing fields — today generation is silent and
`srb tc`, two tools away, is the first to mention it.

**2. Document the sig chain, and shorten it.** Add a short section to
`getting_started.md#sorbet-with-or-without` — "the types stop where your sigs
do" — saying plainly that a generated struct passed through one un-sig'd method
is `T.untyped` from there on, that both the producing method *and* the variable
holding the collaborator must be typed, and giving the two recipes verbatim (the
`type_parameters(:T)` block-passthrough wrapper, and a sig'd service boundary).
It belongs next to the README's `nmae` example, which is true of a direct call
and misleading about a layered app. Then shorten the chain: emit a type alias per
query result (`PetQuery::Pet = PetQuery::Result::Pet`, or a documented
`Result::…` shorthand) so an app's own sigs don't have to spell
`Atlas::Countries::CountryProfileQuery::Result::Country` — the length of that
name is itself a reason teams will skip the sig and lose the checking.

**3. Make the schema lifecycle work on a dump you inherited and on a mixed app.**
Three small fixes, one theme. (a) `schema:refresh` should use a graph's declared
`client` when the dump records no source url — it already does when the file is
absent, so the rule is nearly there; the alternative is a way for a graph to
declare its schema hand-maintained (`schema "…", source: :manual`) so the task
skips it instead of exiting 1 and blocking CI for every other graph. (b)
`schema:diff`'s "records no source url" refusal should name `URL=` and the
graph's client the way `schema:refresh`'s does; a rake user is never holding a
`transport:`; and `queries:check`, in the same state, should either refuse the
same way or say out loud that it validated against the dump rather than the
server — right now it prints "every query validates against the schema" and
exits 0 without reaching a network, which is the one outcome a CI log can't
distinguish from the real check. (c) A line in
`getting_started.md#a-schema-dump-you-already-have`
saying that a dump you brought from elsewhere has no provenance, that
`schema:diff`/`queries:check` are dark until you run
`schema:refresh URL=…` once, and that doing so is the second step of any
graphql-client migration. Every team coming from graphql-client arrives with
exactly that file.
