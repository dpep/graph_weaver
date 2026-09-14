# GraphWeaver senior-engineer evaluation — session A

Evaluator stance: senior Ruby engineer (10y), built typed clients / value-object
codecs before, maintains a graphql-ruby API, first time looking at this gem.
Focus: custom scalar registration doors. Working dir:
/tmp/claude/graph_weaver/senior-app-A. Gem consumed via path dependency, never
editing the gem repo itself.

### 20:24 — start. Read README.md, docs/scalars.md, docs/generated_modules.md, docs/testing.md, and skimmed docs/getting_started.md (in-process schema + Not Rails sections) before touching code.
### 20:24 — bundle install clean (graph_weaver path gem, graphql, sorbet-runtime, sorbet(-static-and-runtime), money, zeitwerk, rspec). No Rails — plain Ruby app, in-process graphql-ruby schema (docs/getting_started.md 'Not Rails?' + 'Your app's own schema, in-process').
### 20:29 — schema + registrations built, first generate! run

Built a plain graphql-ruby schema (`lib/schema.rb`) with: `Money` (money gem,
USD, decimal string on the wire), `Date`/`ISO8601Date`, `ISO8601DateTime`
(time_precision bumped to 3 so sub-second survives graphql-ruby's own default
truncation — that's a graphql-ruby footgun, not graph_weaver's), `JSON`,
custom `UUID`/`URL`/`Duration`/`Email`/`Weight`/`LocalDate` scalars, and a
`Visibility` enum with values `PUBLIC`, `PRIVATE`, `CLASS`, `END` (the
Ruby-keyword-adjacent one). Consumed in-process (`GraphWeaver.generate!(schema: Schema)`,
no Rails, no Zeitwerk for the main path).

**First real finding, and it came before I'd even started "trying to break
it":** registering `Email` as `EmailAddress` (a class with none of
`.parse`/`.load`/`Kernel#Email`) with no `cast:`/`serialize:` override raised
at generation the moment a query actually selects that field:

```
register_scalar("Email", EmailAddress) has no cast, so nothing builds a
EmailAddress out of the JSON at Product.supportEmail — give it one (cast:
:parse names a class method, cast: ->(v) { "EmailAddress(#{v})" } emits any
expression), or register a type the wire already parses into
(GraphWeaver::Error)
```

That's a *good* error (names the field, says what to do), but it reads as a
**docs gap**: docs/scalars.md's "Registering a class of your own" section says
"A type defining none of those [probes] stays pass-through rather than
getting wrapped" — on first read that sounds like "no error, the raw wire
value passes through," which is what I expected and is wrong for a field a
query reads back. Re-reading closely, "pass-through" there is scoped to *not
inventing a serializer via #to_s* (the very next sentence), not "no cast is
required." The paragraph never says a cast is still mandatory once a query
selects the field — that's a separate rule stated ~15 lines further down
("A registration whose type is a class JSON can't parse into ... is refused").
A one-line forward-reference right where "pass-through" is introduced would
have saved me the round trip. Filed as finding #1 below.

Fixed by giving both `cast: :new` and `serialize: :to_s` explicitly.
generate! then wrote 5 files cleanly, 0 already-up-to-date (first run).
### 20:30 — enum-with-keyword-value test

`Visibility` enum with values `PUBLIC`, `PRIVATE`, `CLASS`, `END`. Expected
this to be the "break it" case for the enum door; it wasn't. Generated:

```ruby
class Visibility < T::Enum
  enums do
    Class = new("CLASS")
    End = new("END")
    Private = new("PRIVATE")
    Public = new("PUBLIC")
  end
end
```

`Class = new(...)` is a fresh constant assignment inside
`GraphQLTypes::Visibility`, not a reassignment of top-level `::Class` — Ruby
constants are always capitalized, so a GraphQL enum value can never camelize
into an actual reserved word (those are all lowercase: `def`, `end`, `class`,
`self`...). Loaded with `ruby -w` (warnings on): no "already initialized
constant" warning, `GraphQLTypes::Visibility::Class == ::Class` is `false`,
`.serialize` round-trips to `"CLASS"` correctly. This is a case where the
*module nesting* (every enum lives under its own namespace) structurally
prevents the collision I went looking for — worth calling out as a design
strength, not just a non-finding.
### 20:33 — finding #2: registering the URI module vs URI::Generic

`GraphWeaver.register_scalar("URL", URI)` — the obvious one-line, inferred-cast
registration for the stdlib `URI` module, since `URI.parse` exists and is the
only `.parse` in play. `generate!` succeeds, and at *runtime* it round-trips
fine (`URI.parse(...)` returns a `URI::HTTPS`, and `URI::HTTPS#is_a?(URI)` is
`true` — `URI::Generic` really does include the `URI` module). But `srb tc`
does NOT accept the generated file:

```
generated/products_query.rb:102: Method `nil?` does not exist on `URI`
component of `T.nilable(URI)` https://srb.help/7003
    variables["website"] = (website.nil? ? nil : ...)
Note:
    `nil?` is actually defined as a method on `Kernel`. To call it,
    `include Kernel` in the module `URI` to ensure the method is always there.
```

Sorbet's own builtin payload RBI for the stdlib `URI` module doesn't declare
`include Kernel` on it — so a bare `T.nilable(URI)` doesn't statically know
about `nil?`, even though every real Ruby object has it. Fix: register the
concrete class `.parse` actually returns (`URI::Generic`, a real class with a
full RBI) instead of the namespacing module, with an explicit `cast:` proc
naming `URI.parse` and `serialize: :to_s`:

```ruby
GraphWeaver.register_scalar("URL", URI::Generic,
  cast: ->(v) { "URI.parse(#{v})" }, serialize: :to_s, requires: "uri")
```

That generates `const :website, T.nilable(URI::Generic)` and typechecks
cleanly. **Finding #2**: the one-argument inferred-cast door silently accepts
a Module whose `.parse` factory returns instances of a *different* (sub)class,
and generates code that is correct at runtime but fails `srb tc` for a reason
entirely outside graph_weaver's control (Sorbet's stdlib payload). Nothing in
docs/scalars.md flags "register the return type of your factory, not the
module the factory method happens to live on" — worth one sentence, since
`URI` is exactly the kind of "obvious first thing to reach for" a Ruby
engineer tries for a URL scalar. Severity: low (real workaround exists, one
extra line), but it cost me a full `srb tc` cycle to diagnose since the error
message points at Sorbet's payload, not at the registration. Additive fix:
docs could add "the type you register should be what your cast/`.parse`
*returns*, not merely where the factory method lives."
### 20:37 — finding #3: register_scalar's eql?/hash lint has a blind spot

**Read lib code, and why:** `lib/graph_weaver/codegen/scalar_type.rb`
(`warn_half_a_value_object`, around line 176) — the docs said "registration
warns when it spots one" for a value object missing `eql?`/`hash`, but my
`EmailAddress` (defines *none* of `==`/`eql?`/`hash` — plain `Object`
identity — which still breaks `ResultStruct` equality exactly the way the
docs describe) produced no warning at all, with `GraphWeaver.logger` pointed
at a real `Logger`. Read the source to find out why, rather than guess:

```ruby
def warn_half_a_value_object
  return unless @klass.is_a?(Class) && defines?(:==) && !defines?(:eql?)
  ...
end
```

The lint fires **only** when a class overrides `==` but not `eql?` — the
"half a value object" case. A class that overrides *neither* (Object's
identity-based `==`/`eql?`/`hash`, internally consistent with itself) is
invisible to it, even though it is equally broken for `ResultStruct`'s
promise that "two results parsed from the same response are `==`": two
`ProductQuery.execute!` calls against identical data return `Product`
structs that are *not* `eq`, because `support_email` is two different
`EmailAddress` instances and `Object#==` is identity. Confirmed with a spec
(`spec/scalars_spec.rb`, "ResultStruct equality/hash contract"):
`BadValueObject` (overrides `==`, forgets `eql?`/`hash`) triggers the logged
warning; `EmailAddress` (overrides nothing) does not, and both break the
struct's equality contract identically.

**Finding #3**: writing a plain Ruby value object with **no** equality
override at all — arguably the *more* common first draft, since it's what
`Struct.new` and a bare class both hand you before anyone thinks about
`Hash` keys — is the case the lint doesn't catch, while the rarer "I wrote
`==` and forgot the other two" case is the one covered. Suggest widening the
warning's condition to include "no `==`, `eql?`, or `hash` override at all"
(a class the query result will actually need value semantics for), which
would have caught my exact mistake. Additive change (loosens a warning
condition, doesn't change any behavior downstream of the warning itself).
Severity: medium — it produces a working-looking library that silently fails
"is this a good hash key" days later, on a class that looks like ordinary
Ruby, with no signal from the tool that promises to catch exactly this class
of bug.

`srb tc`: does not catch this at all (Sorbet doesn't reason about `==`/`eql?`
consistency), consistent with docs framing this as a runtime-registration
concern, not a static one.

Also generated `sorbet/rbi/gems/{rspec,rspec-core,rspec-support,rspec-expectations,rspec-mocks}@*.rbi`
via `bundle exec tapioca gem ...` — required once specs pulled in
`graph_weaver/rspec` and `RSpec.describe`, unrelated to the gem itself.
`spec/spec_helper.rb` marked `# typed: ignore` (matching the gem repo's own
convention for its spec_helper) since specs aren't the checked contract.

Full happy-path state after these three findings: `bundle exec rspec` 10/10
green, `bundle exec srb tc` clean.
### 20:42 — adversarial batch: DateTime/Date, BigDecimal(1e400), Float::INFINITY/JSON, Money currency mismatch, serialize/spelling disagreement

**Time/Date object mismatch (going out).** `ProductsQuery.execute!(since: Time.now)`
where `since:` is typed `Date` — refuses exactly as documented, verbatim:

```
GraphWeaver::InputError: $since of ProductsQuery: expected an ISO8601Date,
got a Time — pass .to_date if dropping the time of day is what you meant
(got 2026-09-12 20:39:34.130159 -0700)
```

Clean pass — docs promised this message and delivered it, including the
concrete value in the error, which is a nice touch for a 422 handler that
logs it. `Time` with sub-second precision (`"2024-01-15T10:20:30.123Z"`)
round-trips losslessly both ways once `GraphQL::Types::ISO8601DateTime.time_precision`
is bumped above graphql-ruby's own `0` default — that default-truncation is a
graphql-ruby footgun on the **server** side, not graph_weaver's; worth a
one-line mention in docs/scalars.md's `DateTime`/`Time` row since it's the
single most likely reason someone's "ISO8601DateTime already registered,
why is my millisecond gone" bug report would start in this gem's issue
tracker instead of graphql-ruby's.

**`BigDecimal("1e400")` and `Float::INFINITY` through `JSON`**: both round-trip
cleanly. `BigDecimal` is arbitrary precision, so a 403-character decimal
string casts back losslessly; `T.untyped`/`JSON` passes anything through
untouched, `Infinity` included — though note this only exercises the
Ruby-hash-in/Ruby-hash-out half (`from_response!` takes an already-decoded
hash); real JSON over a wire can't represent `Infinity` at all, so this
specific probe is really testing "does graph_weaver mangle a value already in
memory" (no) rather than "what happens when a server tries to send Infinity"
(a JSON encoding problem upstream of this gem entirely).

**Money in a different currency than the server expects — the real one.**
`Money.from_amount(BigDecimal("10.00"), "EUR")` sent as a `price:` variable:
no error anywhere. `Coerce.cast` passes an already-`Money` value straight
through (per docs: "already a Money — passed straight through"), `serialize:
:to_s` writes the bare decimal `"10.0"` with **no currency on the wire at
all**, and the round-tripped response comes back `Money(fractional:1000,
currency:USD)` — the server's own registered default. **This is a silent
currency substitution**, not a graph_weaver bug: docs/scalars.md's own
"honest hard case" section says outright that a `Money` scalar as a bare
decimal string can't carry currency, and the `cast:` proc's hardcoded `"USD"`
is presented as the necessary price of that wire shape. I'm flagging it
anyway because it's the single most consequential thing I found for a
money-handling app (see verdict, below) — the gem is faithfully doing what it
was told, and what it was told is a real modeling trap that will bite the
first app that reaches for `register_scalar("Money", Money, cast: -> ...
"USD" ...)` verbatim from the README without noticing the currency is
hardcoded. Not a finding *against* graph_weaver so much as a flag that the
README's own copy-paste example is loaded.

**A scalar whose `serialize:` disagrees with the server's spelling.**
Re-registered `Weight` with `serialize: ->(expr) { "#{expr}.to_s('F').tr('.', ',')" }`
(comma decimal, e.g. `"1,234"`) against a server whose resolver does a plain
`BigDecimal(weight)`. Fails at the server, loudly, with the real cause
preserved:

```
GraphWeaver::ServerError: HTTP 500: ArgumentError: invalid value for
BigDecimal(): "1,234"
```

Good failure mode — no silent corruption, no swallowed exception — but it's
a runtime surprise discovered only by actually calling the mutation; nothing
about `register_scalar` or `generate!` can catch it ahead of time, since the
gem has no way to know what the real server's scalar accepts. Worth knowing
going in: **coordinate `cast:`/`serialize:` are a claim about the wire
contract that only a real request against the real server verifies** — a
cassette or an `:in_process`/`:router` test catches this; a `:fake`-only
test suite never would, since the fake fabricates from the *same*
registration and therefore always agrees with itself (this is explicitly
called out in docs/testing.md's `:wire` section: "What it can't tell you is
whether your `cast:` agrees with the real server").

One correction to my own test along the way: `cast: :itself` is documented
for the *class registration* door ("force pass-through, opting out of
inference") and means exactly that — no cast at all. I first tried
`register_scalar("Weight", BigDecimal, cast: :itself, serialize: ->...)`
expecting it to mean "keep the default BigDecimal cast, override serialize
only," and got the same `has no cast` refusal as finding #1 — that was my
misreading, not a bug: dropping `cast:` entirely (not `:itself`) is what
keeps the stdlib-table default. Once dropped, the override worked as
intended.
### 20:44 — a registration that names a class not yet loaded (Zeitwerk)

Set up a real `Zeitwerk::Loader` (`loader.push_dir("lib/app"); loader.setup`,
no eager load — the standalone-Zeitwerk shape, since this app has no Rails)
over `lib/app/lazy_widget.rb` (`class LazyWidget`, defines `.parse`). Then:

`GraphWeaver.register_scalar("Barcode", LazyWidget)` (bare constant reference)
— Ruby resolves the constant the moment the line parses, which is exactly
"referencing the class" the docs warn triggers the autoload immediately.
Confirmed: `Object.const_defined?(:LazyWidget, false)` is `true` right after
`loader.setup`, before anything touches it — but that's a red herring
(`const_defined?` is true the instant Zeitwerk registers the `autoload`, not
only once the file has actually run); the real signal is
`$LOADED_FEATURES.any? { |f| f.include?("lazy_widget") }`.

**Read lib code, and why:** to find out why `register_scalar("Barcode",
"LazyWidget")` (the string form, specifically documented as the way to avoid
referencing the class) raised the *same* `has no cast` refusal as finding #1,
even though the real `LazyWidget` class defines `.parse` — that looked like a
bug until I read `lib/graph_weaver/codegen/scalar_type.rb:108`:

```ruby
@klass = type.is_a?(Module) ? type : nil
...
codec = @klass && CODECS.find { |c| @klass.respond_to?(c.probe) }
```

**Finding #5 (docs gap, not a bug):** the string form of `register_scalar`
skips `.parse`/`.load`/`Kernel#Type` probing *entirely* — `@klass` is `nil`
for a String type, so `codec` is always `nil` regardless of what the real
class defines. Confirmed end-to-end with `cast: :parse, serialize: :to_s`
added explicitly: registration, `generate!`, and even the file `require`
implied by `requires:` all skip loading the constant (`normalize_requires!(...,
load: !@klass.nil?)` — `false` for a String type) — the class loads for the
first time only when a real response is cast and the generated source
actually executes `LazyWidget.parse(...)`, which is the ideal laziness for a
Zeitwerk app. But docs/scalars.md's "The type also accepts a plain string...
when you'd rather not reference the class" reads as purely a
convenience/spelling choice; it doesn't say the string form silently forgoes
all inference, so a reader who reaches for the string form specifically
*because* their class is Zeitwerk-autoloaded (the exact scenario it's
apparently meant for) will hit the same `has no cast` error I did in finding
#1, and nothing at that error site hints "you're seeing this because you used
the string form, not because your class is wrong." One added sentence to the
docs — "the string form never probes the class, so pair it with an explicit
cast:/serialize:" — would have saved a second confused round-trip like the
one in finding #1. Additive change, low severity (real behavior is correct
and arguably the *only* correct behavior — probing would defeat the whole
point of lazy string registration).
### 20:45 — register_scalar inside a graph block; two graphs, same scalar name, different types

Declared a second graph (`Billing::Schema`, a tiny separate graphql-ruby
schema with its own `Money` scalar) alongside the main one, one line each:

```ruby
GraphWeaver.graph :main do
  schema Schema; queries "queries"; output "generated"
end

GraphWeaver.graph :billing do
  schema Billing::Schema; queries "graph2/queries"; output "graph2/generated"
  namespace "Billing"
  register_scalar "Money", BigDecimal   # a completely different Money than :main's
end
```

One gotcha, clearly explained by the error rather than mysterious: the moment
you declare *any* `GraphWeaver.graph`, the implicit top-level one stops
existing — my first attempt left the main app's `queries`/`generated`
directories undeclared and got a precise refusal naming every orphaned file
and the fix. Once both graphs were declared, `generate!` produced
`const :price, Money` (the value object) in the main graph's
`product_query.rb` and `const :total, BigDecimal` in
`graph2/generated/invoice_query.rb` — same scalar **name** ("Money"), two
unrelated Ruby types, zero cross-contamination, confirmed by actually
executing both in the same process:

```
main graph price: Money 12.50
billing graph total: BigDecimal 0.42e2
```

This is exactly what docs/getting_started.md promises ("the block's
registrations reach that graph alone, laid over the top-level ones") and it
held up under an actual dual-schema run, not just a read of the generated
source. No findings here — this is the cleanest, most confidence-inspiring
part of the whole registration model: a real federation-adjacent need (two
backends that both call something "Money" and mean different things) has an
obvious, one-block answer with no global mutable state leaking between them.
### 20:45 — a scalar registered after generation (stale?)

Changed `LocalDate`'s registration (`cast: :parse` -> `cast: :jd`, a
deliberately different Symbol) in-process without regenerating, then called
`GraphWeaver.verify_generated!(schema: Schema)`:

```
GraphWeaver::Error: stale generated queries — regenerate (rake
graph_weaver:generate): generated/product_query.rb
```

Correctly caught and named the one affected file. Confirms the doc claim
("regenerate when ... a registration changes") is real and mechanical, not
aspirational — `verify` diffs against what the *current* registry would
produce, not just the schema/queries. Unsurprising but worth actually
checking rather than trusting the docs on faith, since a registration-only
drift (no schema change, no `.graphql` edit) is the easiest kind to forget a
regenerate for in practice — nothing else about your diff looks like it
needs one.
### 20:46 — graphql: :fake fabrication for a custom-class scalar (Duration) — what and how to pin

`GraphWeaver::Testing::FakeClient.new(schema: Schema)` against `ProductQuery`
with no pins refuses immediately — not at `Product.warranty`, at
`Product.price` (field declaration order), since `Money` is the first
"your own class" scalar the fake hits:

```
GraphWeaver::Error: can't fabricate a Money at product.price: it deserializes
into Money, and only you know what wire value that accepts. Pin the type —
overrides: { "Money" => ... } — or this one field: overrides: {
"Product.price" => ... }. Suite-wide, that's GraphWeaver::Testing.config.overrides.
```

Pinned `Money`/`UUID`/`URL`/`Email` and re-ran — it then stopped at
`Product.warranty` with the same shape of message for `Duration`
(deserializes into `IsoDuration`). **Answer to "what does the fake fabricate
for Duration": nothing — it refuses rather than guessing**, exactly like
`Money`, `UUID`, `URL`, `Email` (any scalar registered as a class of your
own). Pin it — `overrides: { "Duration" => "PT2H15M" }` (or
`"Product.warranty" => "PT2H15M"` for one field) — and the fabricated struct
casts it through the real registered `cast:` (`IsoDuration.load("PT2H15M")`
→ `IsoDuration(seconds: 8100.0)`), so the pin is checked the same way a real
response would be, not just splatted in raw.

**One more scalar needed a pin that surprised me**: `Product.metadata`, the
JSON-narrowed coordinate (`register_scalar("Product.metadata", "T::Hash[String,
T.untyped]")`), *also* refuses fabrication —

```
GraphWeaver::Error: can't fabricate a JSON at product.metadata: it
deserializes into T::Hash[String, T.untyped], and only you know what wire
value that accepts. ...
```

— even though the underlying scalar is plain `JSON` (which needs no pin when
*un*narrowed: `JSON`/`T.untyped` is in the "needs nothing" list). Narrowing a
`JSON` field to a Sorbet Hash type opts it out of free fabrication the same
way registering a custom class does. Docs/scalars.md's JSON-narrowing section
says the trade is "an array the scalar allowed is now a hard failure" for
casting; it doesn't mention the same registration also disables fake
fabrication for that field, which is a second, separate cost of narrowing
worth one added sentence (minor, additive doc gap). Once all five
(`Money`/`UUID`/`URL`/`Email`/`Duration`) plus the one coordinate were
pinned, the rest of the struct fabricated normally and every other field
(`name`, `weight`, `visibility`, ...) stayed randomly-but-validly generated —
confirming pins are additive/targeted, not "pin one thing, lose the rest of
the free fabrication."
### 20:47 — final verification

Final state of the main app: `bundle exec rspec` 10/10 green,
`bundle exec srb tc` clean, regeneration is byte-identical across two runs
(determinism claim holds), `verify_generated!` passes on a freshly generated
tree and correctly fails on a deliberately stale one.

## Doors and adversarial cases not separately reproduced

In the interest of time, a few requested cases were reasoned about from the
generated code/docs rather than independently reproduced with a fresh repro
script: the exact `srb tc` diagnosis for a handful of minor variations on
already-covered doors (e.g. `cast:` as a bare Array on a class rather than a
stdlib type), and a literal `graphql: :router`/federation angle (out of scope
for a scalar-focused single-schema evaluation). Everything explicitly named
in the brief — every door, every "try to break it" bullet — has a concrete
repro above or in `spec/scalars_spec.rb`.
