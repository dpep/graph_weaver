# Result type names are too long — six options, measured against two real apps

**Recommendation: change no codegen. Document the app-side constant alias
instead, in `getting_started.md#sorbet-with-or-without`, next to the sig-chain
section the migration report already asks for.**

> **The rule, in one sentence:** an app that wants a short name for a generated
> struct assigns one — `Country = Countries::CountryProfileQuery::Result::Country`
> at the top of the class that hands it out — and the generated name stays
> exactly as long and as position-determined as it is today.

The reason is arithmetic. The worst sig in either migrated app is 116 characters:

```ruby
    sig { params(continent_code: String).returns(T.nilable(Countries::ContinentCountriesQuery::Result::Continent)) }
```

| | chars | owned by |
|---|---|---|
| `sig { params(…).returns(T.nilable(…)) }` + indent | 63 | Sorbet |
| `Countries::` | 11 | the app (`namespace "Atlas::Countries"`) |
| `ContinentCountriesQuery::` | 25 | the file name + the operation suffix |
| `Result::` | **8** | **graph_weaver** |
| `Continent` | 9 | the response key |

Everything this lane could reasonably change is `Result::`. Deleting it takes the
line from 116 to 108, which is still past every line limit a team has and still
the reason someone skips the sig. The app-side constant takes the same line to
**72**:

```ruby
    sig { params(continent_code: String).returns(T.nilable(Continent)) }
```

That is the whole finding. A gem-side change buys 7%; one line of app code buys
38%, and buys it in the app's own vocabulary.

---

## Before / after, in the apps

### `atlas` — `lib/atlas/geo.rb`, as migrated

```ruby
sig { params(code: String).returns(T.nilable(Countries::CountryProfileQuery::Result::Country)) }
def country_profile(code)
  Countries::CountryProfileQuery.execute!(code:, client: @client).country
end

sig { params(continent_code: String).returns(T.nilable(Countries::ContinentCountriesQuery::Result::Continent)) }
def continent_countries(continent_code) = …

sig { params(code: String).returns(T.nilable(Countries::CountryLanguagesQuery::Result::Country)) }
def languages(code) = …
```

### The recommendation

```ruby
# The generated structs this service hands out, under the names the rest of
# Atlas knows them by.
Country = Countries::CountryProfileQuery::Result::Country
Continent = Countries::ContinentCountriesQuery::Result::Continent
CountryLanguages = Countries::CountryLanguagesQuery::Result::Country

sig { params(code: String).returns(T.nilable(Country)) }
def country_profile(code) = …

sig { params(continent_code: String).returns(T.nilable(Continent)) }
def continent_countries(continent_code) = …

sig { params(code: String).returns(T.nilable(CountryLanguages)) }
def languages(code) = …
```

Three lines added, three sigs shortened, `rspec` 20/20 and `srb tc` clean. And
the *callers* get the short name too — `QuoteBuilder` can now write
`sig { params(country: Geo::Country) … }`, which is the point: the presenter
stops knowing which `.graphql` file produced its country.

### The same edit under option A (the gem-side alias)

```ruby
sig { params(continent_code: String).returns(T.nilable(Countries::ContinentCountriesQuery::Continent)) }
```

108 characters. It removes the one segment that carries no information and
leaves the two that carry the app's own choices.

---

## Ranked options

### 1. App-side constant alias, documented — **recommended**

One sentence in the docs, no codegen. Covers every depth, every app layer, and
the shared-concept case (`Geo::Country` is a name two queries' structs can both
be aliased *to* under different app names; a genuinely shared *type* is the
object-fragment hoist lane's job).

Migration cost: none. No **Action** line — nothing an existing app has changes
behaviour.

Verified on both apps:

- 116 → 72 on atlas's worst sig; three alias lines added across `Geo`.
- `# typed: strict` needs **no** `T.let` around a class alias — `srb tc` clean.
- Rails: `rails zeitwerk:check` "All is good!", `RAILS_ENV=production rails
  runner` boots and resolves `PetPresenter::Owner`, and after
  `Rails.application.reloader.reload!` the alias is still `.equal?` to the
  canonical constant (generated files are `require`d by the railtie, not
  Zeitwerk-managed, so there is no reload skew to worry about).
- It makes finding 4's remedy affordable, which is the actual payoff. Sig'ing
  `QuoteBuilder`'s ivar (`@geo = T.let(geo, Geo)`) with `Geo::Country` in the
  chain caught the typo the report says slipped through:

  ```
  lib/atlas/quote_builder.rb:44: Method `nmae` does not exist on
    `Atlas::Countries::CountryProfileQuery::Result::Country`
  ```

**Use a plain constant, not `T.type_alias`.** The constant is usable as a value;
the type alias is not, and the failure is at typecheck, verbatim:

```
lib/atlas/strict_probe.rb:13: Call to method `from_h` on
  `Atlas::Countries::CountryProfileQuery::Result::Country` mistakes a type for a value
```

`T.type_alias` stays the right tool for the one thing a constant can't express —
a union of two queries' structs, as `PetPresenter::Pet` already is.

**The docs sentence** (both halves run verbatim above):

> A generated struct's constant path spells out the query that produced it, which
> is what makes it stable — and long. Where an app names one in a sig, alias it
> once in the class that hands it out: `Country =
> Countries::CountryProfileQuery::Result::Country`, then
> `sig { returns(T.nilable(Country)) }`. Use a plain constant, not
> `T.type_alias`: the constant works in a sig *and* as a value (`Country.from_h`),
> and in a `# typed: strict` file it needs no `T.let`. Reach for `T.type_alias`
> only when the type is a union of several queries' structs.

### 2. Module-level alias for each struct the root selects (option A)

> `CountryProfileQuery::Country = Result::Country`, for each of the root's direct
> object children.

Prototyped in `codegen/emit.rb` (17 lines, one hook after `emit_nested(root, …)`).
Gem suite 2054/0 and `srb tc` clean; both apps regenerated and rewritten; rspec
and `srb tc` green in both. It works, and it also shortens *deep* names, since
`ShelterQuery::Shelter::Pets` resolves through the alias.

Why it isn't the recommendation:

- **It doesn't solve the stated problem.** 116 → 108.
- **Sorbet still reports the long name.** The alias shortens what you write, not
  what the compiler tells you when it's wrong — the diagnostic above says
  `Atlas::Countries::CountryProfileQuery::Result::Country` whichever spelling the
  sig used. Half the pain is in reading errors.
- **It needs a new refusal, and today's behaviour is silently wrong.** The root's
  response key lands in the same module-level namespace as the shared aliases
  (`PetFilter = GraphQLTypes::PetFilter`, `Species = …`, and the hoisted-fragment
  names the other lane is about to add). A query aliasing a root field to an
  input type's name clobbers it with a Ruby warning and no refusal:

  ```
  warning: already initialized constant Probe::PetFilter
  warning: previous definition of PetFilter was here
  ```

  (The enum case happens to be caught today by `check_shadowing!`, with a message
  that reads oddly — "…and shadows it inside Species" — but that is a
  pre-existing message, not this option's doing.)
- **Two spellings for one thing, forever.** Which does the doc show? Which does
  the error show? "One rule beats a rule with exceptions."
- **It fights the ecosystem.** Apollo Kotlin generates `<Operation>.Data.<Field>`
  — a nested `Data` class under the operation class, with a nested class per
  composite field ([docs](https://www.apollographql.com/docs/kotlin/essentials/queries)).
  Apollo iOS is the same shape. `Result` *is* `Data`. A Ruby team coming from
  github/graphql-client has no naming convention to be surprised by (that client
  is dynamic — `response.data.pet`, no generated constants at all), so the nearest
  convention is Apollo's, and GraphWeaver already matches it.

**If the owner wants it anyway, what the codegen lane needs:** emit the aliases
after `emit_nested(root, out, 1)` in `Emit#emit_module`, from
`root.fields.filter_map { |f| f.node.nested }` keeping `ObjectNode`s that aren't
`module_level?`. Then extend `check_shared_collisions!` to take those names too,
refusing with the same shape of message it uses for a hoisted fragment — and note
that this is a **breaking generation change**: a query that generates today would
start refusing, so it needs an **Action** line.

### 3. Object-fragment hoisting — the other lane, and the better half of the answer

Not mine to do, but it belongs in the ranking: when a field is selected as exactly
`{ ...PetFields }`, `GraphQLTypes::PetFields` is short, meaningful, *shared*, and
named by a source fact. That is Relay's answer to the same problem (the fragment,
not the operation, is the unit of typed reuse). For the shared case it beats every
option here; for the per-query case it does nothing, which is where option 1 lives.

One thing to flag to that lane: it aliases `PetFields` into each query module, so
it fills the same module-level namespace option A wants. Doing both doubles the
collision surface.

### 4. Relocate the root's children to module level (option B)

> Emit the root's direct object children as module-level classes, leaving `Result`
> to reference them — so `CountryProfileQuery::Country` *is* the class.

Prototyped. The one thing it does that nothing else does: **Sorbet reports and
autocorrects the short name.**

```
spec/codegen_spec.rb:578: Unable to resolve constant `Person`
  Did you mean `PersonQuery::Person`? Use `-a` to autocorrect
```

And the one thing that disqualifies it: `Result::Person` stops existing.
**40 of the gem's own 2054 examples fail** and `srb tc` errors, from nothing but
`Result::` references — and struct `.name` changes, so cast-error text and any
log/cassette assertion naming a struct moves too. Every migrated app pays the same
in proportion. Keeping `Result::X = X` as a back-compat alias fixes the migration
but re-creates option A's "two spellings" problem and half-breaks the documented
property that "structs nest the way the selection does" — the first hop would be
flat and the rest nested, which is a rule you can't state without its exception.

### 5. A shorter module suffix (`CountryProfile::Country`)

Dead. The suffix is not optional today: `internal.rb`'s `strip_kind_extension`
drops only a trailing `.query`/`.mutation` *extension*, deliberately — "`_query`
inside a snake_case name is a word OF the name". Dropping the suffix outright
costs 5 characters of 116, renames every module in every app, and removes the one
signal that `Atlas::Countries::CountryProfile` is generated code rather than a
model.

### 6. `include` the query module

`include Countries::CountryProfileQuery` in a presenter brings `Result`, `QUERY`,
`OPERATION_NAME` and the input/enum aliases into the class's constant scope to buy
`Result::Country`. Strictly worse than one alias line, and it imports a pile of
names nobody asked for.

---

## What I declined

**Anything that makes the generated name shorter at the cost of making it less
predictable.** The property in `docs/generated_modules.md` — "adding, removing, or
reordering an unrelated selection can never rename a struct you already use", with
`spec/naming_spec.rb` asserting it — is worth more than eight characters, and
every shortening scheme that goes past `Result::` (deduplicating by type name,
collapsing single-child chains, pluralization) trades it away.

**Reframing the problem as finding 4's.** Tempting, because it's true that the
long name appears *only* in a sig, and a migrated app has few: seven in atlas,
five in menagerie, twelve across both, ten of them at depth 1. Twelve occurrences
is not a typing problem. But "teams skip the sig" is a real report, and a
116-character line is a real reason, so the answer has to make the line shorter —
which is what option 1 does, and it happens to make the rest of finding 4's sig
chain cheaper at the same time.

---

## Evidence

Prototypes were built and thrown away; nothing under `lib/` is proposed. Apps
copied to `/tmp/claude/graph_weaver/naming/{atlas,menagerie}` (branches
`option-a`, `option-d`) so the shared scratch apps under `migrate/` were left
alone.

| | atlas rspec | atlas srb | menagerie rspec | menagerie srb | gem rspec | gem srb |
|---|---|---|---|---|---|---|
| baseline | 20/0 | clean | 23/0 | clean | 2054/0 | clean |
| option A | 20/0 | clean | 23/0 | clean | 2054/0 | clean |
| option B | — | — | — | — | 2054/**40** | **2 errors** |
| option 1 (docs) | 20/0 | clean | 23/0 | clean | untouched | untouched |

Name corpus across both migrated apps — every place app code spells a generated
struct: 12 occurrences, mean 38.6 characters, 10 of them the root's direct child.
Option A takes the mean to 30.6 (−21%); the app-side alias takes it to the length
of a word.
