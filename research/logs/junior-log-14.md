# Junior scenario 14 log — an app with no Sorbet

Persona: Rails dev, no Sorbet, no tapioca, never wants either. Trying graph_weaver
purely because "the test fakes are good." Following README.md and
docs/getting_started.md cold. Remote graph: https://countries.trevorblades.com/graphql

App built at `/tmp/claude/graph_weaver/junior-app-14`. Gem checkout at
`/Users/dpepper/code/lib/ruby/graph_weaver` (path: gem, read-only, not modified).
Toolchain: `~/.rvm/wrappers/ruby-3.4.9/bundle exec ...` (never `source rvm`).
All timestamps UTC.

---

## Step-by-step

**04:28 — read README.md.** First line of the tagline: "**Your `.graphql` files,
compiled into Sorbet types** — and the fakes to test them." Line 9: "generates
checked-in `# typed: strict` Ruby." The worked example (lines 30-38) shows
`srb tc: Method 'nmae' does not exist...` as the payoff for a misspelled field.
As someone who doesn't want Sorbet, this reads like the wrong tool before I've
even scrolled past the intro — the pitch is Sorbet-first, and nothing on this
page yet says the gem still works without it.
→ **Sorbet assumption #1 — confused me.** The headline pitch and the flagship
  example both assume Sorbet. A Sorbet-averse reader has to keep reading in
  faith that it's optional; the README never says so itself.

**04:28 — read docs/getting_started.md.** Steps 1-5 (install, generator, write a
query, test against fakes, verify in CI) mention nothing Sorbet-specific — the
rake tasks, the generator, the testing tags are all just "run this command."
Found the reassurance at the very end, in a section titled **"Sorbet, with or
without"** (line ~663, after ~650 lines of doc):

> `sorbet-runtime` is a hard dependency, so generated `T::Struct`s and sigs
> enforce at runtime in every app — no Sorbet setup required on your end...
> Everything works without Sorbet; codegen plus Sorbet is what moves type
> errors from runtime to CI.

This is exactly the answer I needed, and it's a good, honest answer — but it's
the very last section of the doc, after five worked steps that never flagged
the question. A cold reader in my position would want this up front, ideally
in the README itself.
→ **Sorbet assumption #2 — cosmetic (placement, not substance).** The content
  is correct and reassuring; it's just buried at the bottom of the longest doc
  instead of surfaced where the decision to adopt gets made.

**04:28 — checked graph_weaver.gemspec** (peeking under the hood, not something
the docs told me to do, but I wanted to know before committing). `sorbet-runtime`
is the only Sorbet-related **runtime** dependency; `sorbet` and `tapioca` are
`add_development_dependency` only — they don't reach my app's Gemfile.lock via a
path gem. Confirms assumption #2 rather than contradicting it.

**04:29 — `rails new junior-app-14 --skip-active-record --minimal ...`.** Plain
Rails 8.1.3.1 app, no AR needed for a GraphQL client. Unremarkable, no Sorbet
anywhere.

**04:29 — added `gem "graph_weaver", path: "..."` and `gem "rspec-rails"` to the
Gemfile, `bundle install`.** Clean install, 78 gems. Verified after:
`grep -iE 'sorbet|tapioca' Gemfile.lock` → only `sorbet-runtime` appears (the
gem itself and its dependency line). No `sorbet`, `sorbet-static`, or `tapioca`
anywhere in the lockfile.
→ **Confirms the doc's claim is true, not just asserted.**

**04:29 — `rails g rspec:install`** then **`rails g graph_weaver:install
https://countries.trevorblades.com/graphql`.** Both generators ran cleanly.
Output of the graph_weaver generator:

```
      create  config/initializers/graph_weaver.rb
      create  app/graphql/queries/.keep
      create  app/graphql/fragments/.keep
      create  app/graphql/generated/.keep
      create  graphql.config.yml
Testing: add `require "graph_weaver/rspec"` to your spec helper for the `graphql:` tags (docs/testing.md).
  introspect  app/graphql/schema.json from https://countries.trevorblades.com/graphql
```

No Sorbet mentioned in the generator output or the initializer it wrote — the
initializer is plain Ruby (`GraphWeaver.client = GraphWeaver.new(...)`). The
doc's own note about `rails g rspec:install` leaving the support glob commented
out was accurate — I added `require "graph_weaver/rspec"` directly to
`spec/rails_helper.rb` as instructed rather than uncommenting the glob.

**04:30 — wrote two query files.** `app/graphql/queries/continents.graphql` (no
variable) and `app/graphql/queries/country.graphql` (`$code: ID!`, one variable).

**04:30 — `rake graph_weaver:generate`.** Wrote `continents_query.rb` and
`country_query.rb`. Opened them to see what "typed" means in practice:

```ruby
# typed: strict
# frozen_string_literal: true
module CountryQuery
  extend T::Sig
  ...
  class Result < T::Struct
    class Country < T::Struct
      const :name, String
      const :capital, T.nilable(String)
      ...
      sig { params(data: T::Hash[String, T.untyped]).returns(Country) }
      def self.from_h(data) ... end
```

→ **Sorbet assumption #3 — cosmetic, but a real "wait, what's this" moment.**
  Every generated file starts `# typed: strict`, every method has a `sig`,
  every struct is a `T::Struct`, nilability is spelled `T.nilable(String)`. I
  never asked for `# typed: strict` and don't run `srb tc`, so that header
  does nothing for me — but I don't need to *do* anything about it either:
  the file just runs. The comment in the generated file itself even explains
  a Sorbet mechanism I'd otherwise have had to look up:
  `# .checked(:never): an untyped value (a Rails param) reaches the coercion
  below instead of sorbet-runtime's argument check; srb tc still holds typed
  call sites.` I had to mentally translate "srb tc still holds typed call
  sites" — that clause is meaningless to me, but thankfully it's in a comment,
  not something blocking me.

**04:31 — wrote two request specs tagged `graphql: :fake`** (`spec/requests/
continents_spec.rb`, `spec/requests/countries_spec.rb`), plus matching
controllers/routes. First run failed on my own mistake, not Sorbet's:

```
ArgumentError: a fake doesn't take Continents: — did you mean the pin
"continents"? It takes schema:, registry:, overrides:, seed:, values:,
list_size:, null_chance:, errors:, fail_at:, corrupt:, and pins keyed by
anything in your schema — a type, a "Type.field" coordinate, or a field name
```

I'd pinned `"Continents"` (the generated Ruby struct name) instead of
`"continents"` (the actual schema field — the struct is named for the response
key, the schema's real type is `Continent`). The error was self-explanatory
and even suggested the fix ("did you mean the pin 'continents'"); fixed in one
edit, re-ran, green.
→ **Not a Sorbet issue at all** — this is graph_weaver's own naming rule
  (struct named for response key, not schema type) surfacing as a normal
  ArgumentError with a good message. Filed here only because I initially
  suspected it might be type-related; it wasn't.

**04:31 — `bundle exec rspec spec/requests`** → 2 examples, 0 failures, no
network calls (fakes only).

**04:31 — live run.** Wrote `spec/requests/live_spec.rb` with no `graphql:` tag
— hits the real `countries.trevorblades.com` endpoint through the client set up
in the initializer. `bundle exec rspec spec/requests/live_spec.rb` → 2
examples, 0 failures (fetched Japan and confirmed "AS" is a continent code).

**04:31 — `rake graph_weaver:verify`** → `generated queries up to date` (exit 0).
**04:31 — `rake graph_weaver:queries:check`** → `every query validates against
the schema` (exit 0). Neither message mentions Sorbet, `srb`, or types — both
read like any other Rake task output.

**04:32 — `RAILS_ENV=production ... rails zeitwerk:check`.** Passed cleanly:

```
transport: GraphWeaver::Transport::HTTP -> https://countries.trevorblades.com/graphql
loaded 2 generated module(s) from app/graphql/generated, app/graphql/*/generated
Hold on, I am eager loading the application.
All is good!
```

**04:32 — production boot + real query via `rails runner`** (`RAILS_ENV=production`,
dummy `SECRET_KEY_BASE`): `CountryQuery.execute!(code: "FR").country&.name` →
`France`, with a one-line log: `GraphWeaver CountryQuery (208.5ms) ok`. Full
boot, eager load, real network call, no Sorbet setup needed anywhere.

---

## Deliberately doing wrong things (no type checker to catch me)

**04:32 — wrong Ruby type as a variable, attempt 1: `code: 123`** (Integer where
the query declares `$code: ID!`). No error, no crash — `country` came back
`nil` for a bogus 3-digit "country code." Reason: GraphQL's `ID` scalar is
spec'd to accept either a String or an Int and coerces it, so `123` silently
became `"123"`. **This is not a defect** — it's correct per the GraphQL
spec — but as a person hoping runtime checks would flag "you passed the wrong
type," this is a near-miss: no error, no signal, just a puzzling `nil`. If I'd
been debugging a typo (e.g., meant `"123"` for a real country I misremembered
the code for) I'd have no clue why.

**Wrong Ruby type, attempt 2: `code: {foo: "bar"}`** (a Hash — nothing coerces
that to an ID). This raised, and raised well:

```
GraphWeaver::InputError: $code of CountryQuery: expected an ID, got {foo: "bar"}
```

Message is plain English, names the variable, the operation, the expected
type, and the actual value. No Sorbet vocabulary in the message. **But** the
backtrace printed around it includes frames like:

```
.../sorbet-runtime-0.6.13498/lib/types/private/methods/_methods.rb:465:in
'UnboundMethod#bind_call'
.../sorbet-runtime-0.6.13498/lib/types/private/methods/_methods.rb:465:in
'block in CountryQuery._on_method_added'
```

→ **Sorbet assumption #4 — confused me (mildly).** I never installed Sorbet,
  but a gem called `sorbet-runtime` shows up uninvited in my stack trace,
  because it's graph_weaver's hard dependency wrapping every generated method
  in a `sig`. The error itself was fine; the backtrace briefly made me think
  "wait, do I have Sorbet installed after all?" (I don't — checked
  Gemfile.lock again to be sure.) A comment on the sig itself
  (`.checked(:never): an untyped value (a Rails param) reaches the coercion
  below instead of sorbet-runtime's argument check`) explains why the argument
  isn't type-checked by Sorbet at all here — the checking that actually
  caught my mistake was graph_weaver's own `GraphWeaver::Coerce`, not Sorbet.
  **Runtime protection, but attributable to graph_weaver's own coercion layer,
  not to Sorbet** — worth knowing, since Sorbet gets credited in the docs and
  README for exactly this kind of catch.

**04:33 — read a field I didn't select** (`.country.awsRegion`, not in my
`country.graphql` selection set):

```
undefined method 'awsRegion' for an instance of CountryQuery::Result::Country
```

Plain `NoMethodError`, no Sorbet mention, obvious what happened (the struct
only has the fields I selected). This is the runtime equivalent of the
README's `srb tc: Method 'nmae' does not exist` — same protection, just
surfacing when the line runs instead of when I typecheck, because I have no
typechecker. **Real runtime protection, no Sorbet required to get it** — I
still can't accidentally read data I never asked for.
(Aside, not graph_weaver's fault: `rails runner` on Rails 8.1 always prints
"Please specify a valid ruby command..." before an unhandled exception's
message, even for a plain `"x".nonexistent_method` — confirmed this is a Rails
runner quirk, not something graph_weaver introduced.)

**04:33 — indexed a nilable field without a nil check.** `country.graphql`
selects `capital`, which the schema marks nullable. Confirmed AQ (Antarctica)
has `capital: nil` from a live query, then called
`.country.capital.upcase`:

```
undefined method 'upcase' for nil
```

Plain `NoMethodError` on `nil` — exactly the crash a Sorbet+`srb tc` setup
would have caught at typecheck time (`T.nilable(String)` forces a `&.` or a
nil check before you can call `.upcase`), and exactly the crash a non-Sorbet
app still gets, just later, in production, on whichever request happens to
hit a country with no capital. **This is the real gap**: `T.nilable` in the
generated struct is honest metadata (sorbet-runtime does check that `capital`
is `String` or `nil`, never e.g. an Integer, at construction time), but
nothing at runtime stops you from then calling a method on it without a
check. Without Sorbet's static pass, `T.nilable` buys you correctness of the
*data*, not safety at the *call site*.

**04:33 — misspelled a prop.** `.country.nmae` instead of `.country.name`:

```
undefined method 'nmae' for CountryQuery::Result::Country — did you mean 'name'?
```

Plain `NoMethodError`, and the "did you mean" suggestion is Ruby 3.4's
built-in `did_you_mean` gem, not something graph_weaver added — but it lands
in the exact same place the README's `srb tc` example does. Runtime instead
of compile-time, otherwise indistinguishable in usefulness.

---

## Summary

**Full run, `bundle exec rspec` (all 4 specs: 2 fake, 2 live):** 0 failures.
No `sorbet`, `sorbet-static`, or `tapioca` anywhere in `Gemfile.lock`, no
`sorbet/` directory, no `.rbi` files anywhere in the app — confirmed by find.
