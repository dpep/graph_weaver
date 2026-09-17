# Custom scalars

Teach the generator how a GraphQL custom scalar deserializes into a rich Ruby
object, and serializes back when used as a variable. Three registrations cover
almost every app:

```ruby
GraphWeaver.register_scalar("Decimal", BigDecimal)   # a stdlib class
GraphWeaver.register_scalar("Money", Money)          # a value object of your own
GraphWeaver.register_enum("Species", PetKind)        # a schema enum onto your T::Enum
```

`register_scalar` takes the scalar's name in your schema and the Ruby type it
means. The type is the only part the library can't work out: a field typed
`Decimal` then generates `const :price, T.nilable(BigDecimal)` and casts with
`BigDecimal(...)` inline — no runtime reflection — and the wire spelling and the
`require "bigdecimal"` the generated file needs come with it.

Registration is global and codegen-time: `rake graph_weaver:generate` reads the
same registry an initializer writes, so register before you generate. A
registration that goes *missing* later — a reverted initializer line, a bad merge
— is loud at generate/verify time and silent forever after: code regenerated
without it casts the field to the plain wire type (a `String` where an `Email`
was) and nothing raises anywhere. [`verify_generated!`](generated_modules.md) in
CI is what protects a registration; no runtime assertion can.

## Already registered

These names need no registration. graphql-ruby ships all but `DateTime` as its
own scalars, and `DateTime` is what GitHub, Shopify and most hand-written schemas
call an ISO 8601 timestamp.

| scalar | Ruby type | on the wire |
|---|---|---|
| `ID` | `String` | the string (an `Integer` input is accepted) |
| `String` | `String` | the string |
| `Int` | `Integer` | a JSON integer |
| `Float` | `Float` | any JSON number |
| `Boolean` | `T::Boolean` | the boolean |
| `Date`, `ISO8601Date` | `Date` | `"2024-01-15"` |
| `DateTime`, `ISO8601DateTime` | `Time` | `"2024-01-15T10:20:30Z"` |
| `BigInt` | `Integer` | the decimal string graphql-ruby writes; a JSON number is read too |
| `JSON` | `T.untyped` | whatever it is, untouched |

**A date stays a `Date` and a timestamp a `Time`**, in both directions: casting a
date to `Time` invents a midnight the server never sent, and sending a `Time` for
a date variable drops the time of day. Give one for the other and it is refused,
naming the class — `$on of Report: expected a Date, got a Time — pass .to_date if
dropping the time of day is what you meant`. A `cast:` of your own doesn't change
that: a cast says how the object is *built*, not which values are right. The
refusal is about Ruby **objects**; a timestamp *string* given for a `Date` parses
and truncates to its date, as graphql-ruby's own `ISO8601Date` does.

A schema that means something else by one of these names fails loudly, and one
`register_scalar` overrides it like any other entry. Names that are *not* a
convention (`Timestamp`, `UUID`, `URL`, `Decimal`, `Money`) are left to you,
because guessing at one would be worse than asking.

## Registering a stdlib type

Name the class and stop. What the library supplies is the part inference can't
reach: the wire spelling (`BigDecimal#to_s` writes `"0.125e2"`, which is not what
any server means by 12.5) and the file to require, so the generated source stands
alone.

Taking `register_scalar("Count", <type>)` as the example:

| Ruby type | cast | serialize | require |
|---|---|---|---|
| `BigDecimal` | `BigDecimal(v)` | `v.to_s("F")` | `bigdecimal` |
| `Date` | `Date.iso8601(v)` | `v.strftime("%F")` | `date` |
| `Time` | `Time.iso8601(v)` | `GraphWeaver::Coerce.timestamp(v)` | `time` |
| `DateTime` | `DateTime.iso8601(v)` | `GraphWeaver::Coerce.timestamp(v)` | `date` |
| `Integer` | `GraphWeaver::Coerce.integer(v, "Count")` | — | — |
| `Float` | `GraphWeaver::Coerce.float(v, "Count")` | — | — |
| `String` | `GraphWeaver::Coerce.string(v, "Count")` | — | — |
| `T::Boolean` | `GraphWeaver::Coerce.boolean(v, "Count")` | — | — |
| `Hash`, `Array` | — | — | — |

For a timestamp reach for `Time`; Ruby's own `DateTime` is accepted if you
register it, but never assumed. All three read ISO 8601 and nothing else, which
is the one spelling a spec-compliant server writes. To take `Time.parse`'s looser
forms as well — a space instead of the `T`, a zone name, `"Jan 15 2024 10:20"` —
say so: `register_scalar("Timestamp", Time, cast: :parse)`, at about 3× the cost
per timestamp.

**A trailing zero doesn't survive the round trip.** A `BigDecimal` holds the
*number*, so `"10.00"` in comes back `"10.0"` — numerically identical, textually
different, which matters only where the bytes are: diffing a request body, or
hashing one for a signature.

**The last five rows are the types JSON already holds**, so they write
themselves — nothing to serialize — and naming one says the scalar *is* that
Ruby type. The library's own rule for the class then runs in both directions,
refusing in the scalar's name: `register_scalar("Count", Integer)` reads and
writes exactly as `Int` coerces a variable, so `5`, `"5"` and `5.0` all arrive
as `5`, while `"abc"`, `1.5` and `true` raise naming `Count`. `Hash` and `Array`
pass through untouched — `Coerce` has no rule for either, and anything else
would be a guess.

Coming back that is the **lenient** reading, unlike the spec's own `Int`, which
[refuses `"1"`](#coming-back--what-from_h-accepts): a compliant server writes an
`Int` as a JSON number, but a custom scalar is the server's own and may well
write the number as a string. The registration is you saying "make this an
`Integer`"; refusing the garbage is what protects you.

## Registering a class of your own

Pass the class and the cast/serialize are **inferred** from it, by probing the
deserialize side and pairing its serializer:

| the class defines | cast | serialize |
|-------------------|---------------|----------------|
| `.parse` | `Type.parse(v)` | `v.to_s` |
| `.load` | `Type.load(v)` | `Type.dump(v)` |
| `Kernel#Type` | `Type(v)` | — |

so a value object with a `.parse` needs nothing more than
`GraphWeaver.register_scalar("Money", Money)`.

**Give it `eql?` and `hash` too, not just `==`.** A result compares its props with
`eql?`, so a class that stops at `==` makes two results parsed from the same
response unequal, and useless as hash keys, while the `Money` inside them compares
fine. Registration warns when it spots one; `alias_method :eql?, :==` plus a
`hash` built from the same values is the whole fix.

**A `cast:` with nothing to write back is half a codec**, and registration says
so too. `Kernel#Type` is the inference that lands there — it reads the wire and
pairs with nothing — so a variable of that scalar goes out as whatever `#to_json`
makes of the object, and a result's `as_json` can't reproduce what the server
sent. Both are silent, because every object answers `#to_json`. Name a
`serialize:`, or `serialize: :itself` if the value really does go out as it is. A
type JSON already holds (a `String`, `Integer`, `Float`, `Hash` or `Array`, or a
subclass of one) writes itself, and is left alone.

A type defining none of those probes stays pass-through rather than getting
wrapped — every object has `#to_s`, so inferring a serializer off it would wrap
plain types too. Override explicitly when you need to:

- a `Symbol` method name: `cast: :load` → `Money.load(expr)`, `serialize: :to_json`
- an `Array`, for a method with arguments: `serialize: [:to_s, "F"]` →
  `expr.to_s("F")`
- a `Proc` for anything a method name can't express:
  `cast: ->(expr) { "Money.new(#{expr})" }` — it returns **source, not a value**,
  since what comes back is inlined into `from_h`
- `:itself` to force pass-through, opting out of inference (rare)

The type also accepts a plain string (`"Money"`) when you'd rather not reference
the class, which **skips inference entirely** — there is no class in hand to
probe. `requires:` (a string or array) names files emitted as `require`s atop the
generated source so the cast and type resolve; where the type is a real class each
path is also `require`d at registration, so a typo fails now rather than in the
generated file.

**Register what your cast returns, not where the factory method lives.**
`register_scalar("URL", URI)` looks right and runs fine — `URI.parse` is a probe
hit — but `URI` is a *module*, and Sorbet's payload for it doesn't `include
Kernel`, so every call site fails `srb tc` with "Method `nil?` does not exist on
`URI`". The value is a `URI::Generic`:

```ruby
GraphWeaver.register_scalar("URL", URI::Generic, cast: ->(v) { "URI.parse(#{v})" })
```

`URI.parse` is ASCII-only, so a server writing an un-escaped unicode path raises
`URI must be ascii only` — a clean `CastError`, but a refusal of a URL that is
fine. Escape in the cast (`URI::DEFAULT_PARSER.escape(#{v})`), or register
[Addressable](https://github.com/sporkmonger/addressable) instead.

### When the wire shape decides the registration

The money gem's `Money` is the honest hard case: it defines none of the probes,
and `Money.from_amount` needs a currency no amount of Ruby recovers if the
response didn't send one. **A cast can only use what the wire carries**, so the
scalar's shape decides what you write.

An **object** — `{"amount": "12.50", "currency": "EUR"}` — is read out in the cast
and written back by `serialize:`:

```ruby
GraphWeaver.register_scalar("Money", Money,
  cast: ->(v) { "Money.from_amount(BigDecimal(#{v}[\"amount\"]), #{v}[\"currency\"])" },
  serialize: ->(v) { "{ \"amount\" => #{v}.amount.to_s(\"F\"), \"currency\" => #{v}.currency }" })
```

**One string carrying both** — `"12.50 EUR"` — splits in the cast, with
`serialize: :to_s` writing it back. A **bare decimal string** carries no currency,
so the cast supplies one; reach for that only when the API really is
single-currency, and say so where the next reader will look:

```ruby
# single-currency API: a Money in any other currency comes back mislabelled
GraphWeaver.register_scalar("Money", Money,
  cast: ->(v) { "Money.from_amount(BigDecimal(#{v}), \"USD\")" },
  serialize: :to_s)
```

**An object type rather than a scalar** — `Money { amount currency }` — needs no
`register_scalar` at all: codegen types both fields, and
[`extend_type`](generated_modules.md#type-helpers) adds the conversion. Ask for
this shape if you get a vote; the currency is then in the schema, where a reader
finds it.

```ruby
GraphWeaver.extend_type("Money") { def to_money = ::Money.from_amount(BigDecimal(amount), currency) }
```

**One `serialize:` serves both directions** — the outbound variable *and* a
result's [`as_json`](generated_modules.md#anatomy) — so a registration's `cast:`
has to accept what its own `serialize:` writes, and a scalar that sends an object
while accepting a string can't have both. That law, and where it is checked, is
[below](#a-cast-must-accept-what-its-own-serialize-writes). The same asymmetry
decides the [`:fake` pin](testing.md#pins): a pin stands in for a *result*, so pin
what the server **sends**.

Any of this can also be flatly wrong: the *format* a `Money` string has to match
lives in the server's `coerce_input`, which no schema carries, so nothing
`generate` reads says whether the server wants `"12.50"`, `"12.50 USD"` or the
object — [check it against the schema
class](#checking-the-half-no-schema-carries), or send one for real.

## Overriding one field

Pass a `Type.field` **coordinate** instead of a scalar name to override just that
one field, so the same scalar can deserialize as different Ruby types across
fields — and so two servers that disagree about a `DateTime` can coexist in one
process:

```ruby
GraphWeaver.register_scalar("Timestamp", Time)      # the default, everywhere
GraphWeaver.register_scalar("User.birthday", Date)  # this field only
```

A coordinate takes a **type string** too, which is how you narrow `JSON`: the
scalar can legally be any JSON value, so the registry's answer for the whole scalar
stays `T.untyped`, but where *you* know one field's shape, say it there —
`register_scalar("Settings.meta", "T::Hash[String, T.untyped]")`. `srb tc` then
sees a Hash at every call site, and a response carrying something else is refused
naming the struct rather than surfacing as a `NoMethodError` three layers on.
That's a trade: an array the scalar allowed becomes a hard failure, and the field
opts out of `:fake` fabrication, so pin it
(`overrides: { "Settings.meta" => { ... } }`).

## What generation refuses, and what it only warns about

Registrations are validated against the schema you generate against, and only what
that schema can **disprove** fails generation: a name it declares as something else
(`register_scalar("Species")` where `Species` is an enum), or a coordinate whose
field it declares as a composite. A name it simply can't match only warns — one
registry serves a whole graph, so that name may belong to the subgraph next door
(see [federation](federation.md#generating-for-a-federated-graph)).

A registration whose type is a class **JSON can't parse into**, with nothing to
build one, is refused where a query reads that scalar back: the prop would be
unsatisfiable for every response. The message names the field and which of the two
mistakes you made — `Wallet defines no .parse and no .load, and Kernel has no
Wallet conversion function, so there was nothing to infer`, or, for a type given
by name, that a name is never probed. A registration used only for a variable is
untouched: nothing casts it.

A scalar you never register is not an error — it generates as `T.untyped` and the
wire value passes through untouched. It is the one hole in an otherwise exact
result type, so generation names the holes; `rake graph_weaver:generate` and
`:verify` print them once for the run, and `GraphWeaver.parse` says the same at
`info`:

```
3 unregistered custom scalars → T.untyped: CountryCode, FuzzyDateInt, Json (register with GraphWeaver.register_scalar)
```

A scalar that is *meant* to be untyped belongs in the registry too —
`GraphWeaver.register_scalar("Json", "T.untyped")` says so once and leaves the
report. `JSON` is registered that way already.

The testing harness can't invent a wire value for a scalar registered as your own
class — only `Money.parse` knows what it accepts — so it refuses rather than
guess. Say it in test config: `Testing.config.overrides = { "Money" => "12.00" }`,
or per example ([testing → pins](testing.md#pins)). A scalar registered as one of
the stdlib types above needs nothing.

`GraphWeaver.reset_registrations!` is the clean slate between tests (built-in
scalars restored, enum mappings and type helpers dropped);
`GraphWeaver.reset_graphs!` is its twin for declared graphs, and
`GraphWeaver::Codegen` has the pieces for one registry rather than all of them —
`reset_scalars!`, `clear_scalars!`, `reset_enums!`, `reset_type_helpers!`. Scoping
registrations to one of several schemas is not what any of that is for: a
[graph](getting_started.md#more-than-one-schema) block does that, and holds both
sets at once instead of resetting between them.

## What the wire carries

One sentence: **generated code takes every JSON spelling a spec-compliant server
may write, and refuses the rest.** The tables below are the whole of it, and
[`bin/round-trip`](../bin/round-trip) fuzzes both directions against them.

The one place "spec-compliant" is doing real work is `Float`: JSON has a single
number type and encoders write the shortest form, so `1.0` reaches Ruby as `1`
from graphql-js and from Go. Nothing does the reverse — `2.0` for an `Int` is the
server writing a non-integer where the spec says integer, so it is refused.

### Coming back — what `from_h` accepts

| scalar | accepted | refused |
|---|---|---|
| `Int` | any JSON integer, including past 2³¹ and 2⁵³ (lossless in Ruby) | `2.0`, `1.5`, `"1"`, `true` |
| `Float` | any JSON number, `3` and `-0.0` and `1e308` included; also a decimal string | a non-numeric string, `true`, a list/object |
| `String` | any JSON string — empty, unicode, newlines, control characters | a number, `true`, a list/object |
| `ID` | any JSON string | a number or `true` — **refused with a hint**: the server didn't quote it |
| `Boolean` | `true`, `false` | `"true"`, `1`, `0` |
| `Date` | ISO-8601: `"2024-01-01"`, `"20240101"`, and a full timestamp (truncated) | any other spelling, an epoch integer |
| `DateTime`/`Time` (registered as `Time`) | ISO 8601 as `Time.iso8601` reads it: `Z` or an offset, with or without fractional seconds | a bare date, seconds omitted, basic format (`"20240115T102030Z"`), `Time.parse`'s looser forms, an epoch integer |
| `BigInt` | the decimal string graphql-ruby writes, past 2⁵³ included; also a JSON integer | `1.5`, `"1.5"`, a non-numeric string, `true` |
| an enum | a declared value, as a string | an undeclared value, a non-string |
| a scalar registered as `Integer`, `Float`, `String` or `T::Boolean` | that Ruby type's rule, *leniently* — a decimal string reads as an `Integer` | what the rule refuses, naming your scalar |
| `JSON`, or unregistered | anything — `T.untyped`, straight through | nothing |

A refusal is a [`GraphWeaver::CastError`](errors.md) naming the field and the
generated struct (which names the query). Numeric strings — here and in the table
below — are read as a wire format, not as Ruby source: `"010"` is ten, and `"0x1f"`
and `"1_0"` are refused, where `Kernel#Integer` would take all three and let a
zero-padded form field silently mean something else.

### Going out — what a variable kwarg accepts

The kwarg's **type** is what `srb tc` holds a call site to, and it is exactly what
the schema says. The **value** reaching `execute` at runtime is coerced, because a
Rails param is a String whatever the sig says (see
[typed variables](generated_modules.md#variables-become-typed-kwargs) for why the
sig is `.checked(:never)`).

| scalar | kwarg is typed | also accepts, at runtime | on the wire |
|---|---|---|---|
| `Int` | `Integer` | a decimal string, a whole real `Numeric` — `2.0`, `BigDecimal("2")` | the integer |
| `Float` | `Float` | a decimal string, a real `Numeric` — an `Integer`, a `BigDecimal`, a `Rational` | the float |
| `String` | `String` | nothing | the string |
| `ID` | `String` | an `Integer` — `execute(id: user.id)` | the string |
| `Boolean` | `true`/`false` | nothing | the boolean |
| `Date` | `Date` | an ISO-8601 string | `"2024-01-15"` |
| `Time` | `Time` | an ISO 8601 string, a `DateTime`, `Time.zone.now` | ISO 8601, with microseconds when the value carries a fraction |
| `BigInt` | `Integer` | a decimal string, a whole real `Numeric` | the decimal string, which is what the server writes |
| an enum | the member **or** its wire value | — | the wire value |
| an input object | the struct **or** a Hash | — | the wire hash |
| a registered custom scalar | its Ruby type | whatever its cast takes | what its serialize writes |
| `JSON`, or unregistered | `T.untyped` | anything | straight through |

The **on the wire** column is also what a result's
[`#as_json`/`#to_json`](generated_modules.md#anatomy) writes, so a result read back
with `from_h` equals the one you rendered.

Three rows are judgment calls. **`ID` takes an `Integer`** because the spec says an
ID serializes as a string but accepts an integer input, and `execute(id: user.id)`
off a model is the everyday call; `String` gets no such license. **`Boolean` takes
no string**, because every rule for reading `"0"`, `"off"`, `"no"` is somebody's
convention. **A `Date` and a `Time` are not each other**, as above; what *is*
accepted for a `Time` is anything that already is one.

A **real `Numeric`** is the number it prints as, so a `BigDecimal` off a decimal
column needs no conversion at the call site: it reaches a `Float` through `to_f`,
at Float's own precision, and an `Int` only when the value is whole —
`BigDecimal("2")` is `2` and `BigDecimal("2.5")` is refused, exactly as `2.5` is.
`Complex` is the one `Numeric` that is not real, and no number rule takes it.

Anything the table refuses raises `GraphWeaver::InputError` naming the variable,
the operation and the value — `$count of Compute: expected an Int, got "lots"` —
which is the same [422 rescue point](errors.md) as a bad input-object field. The
type is named the way the **schema** names it, so a `register_scalar("Money",
BigDecimal)` field refuses a `Money`, in `#message` and in `#details[:type]` alike.
Input-object fields go through this table too, so `{first: "20"}` inside a filter
hash reads the same as `first: "20"` as a kwarg. When it is the **server's**
scalar that refuses, its `GraphQL::CoercionError` earns a specific
[`kind`](errors.md#what-an-inputerror-says-without-reading-english) only where its
message matches one of graphql-ruby's own explanations, or it raises with
`extensions: { "input" => … }`
([the convention](errors.md#what-your-server-can-send)).

A custom scalar's `cast:` is what a *variable* of that scalar coerces through, so
one registration gets you both directions:

```ruby
StoreQuery.execute(budget: "12.00")          # Money.parse("12.00") under the hood
StoreQuery.execute(budget: Money.new(1200))  # already a Money — passed straight through
```

The kwarg is still typed `Money`, not `T.any(Money, String)`: the sig stays as
narrow as the schema and the conversion happens in `execute`'s body. So
`budget: "12.00"` written literally in a `# typed:` file is still an `srb tc` error
— as it should be, since you have a `Money` right there — while
`budget: params[:budget]` typechecks and converts.

**Writing the scalar on the server too?** graphql-ruby calls a *nullable* scalar
argument's `coerce_input` with `nil` for an explicit `null` — only `NonNull`
short-circuits — so a coercer written like the examples above raises
`NoMethodError` on nil. Guard it, or `:in_process` will show it to you as a
`ServerError`.

## Checking the half no schema carries

A custom scalar has two definitions that have to agree: the server's
`coerce_input`/`coerce_result`, and your `register_scalar`. **No schema carries the
first one.** A scalar's SDL is its name, a description and a `@specifiedBy` url —
the coercers are Ruby method bodies that never reach a dump — so a server
switching `coerce_result` from a decimal string to a JSON number, same scalar,
same name, moves nothing `verify`, `schema:diff` or `generate` reads. All three
stay green, and `BigDecimal` then takes the Float without complaint:

```ruby
BigDecimal(BigDecimal("123456789.123456789").to_f).to_s("F")   # => "123456789.1234567"
```

No `CastError`, no warning — just totals quietly wrong past the seventh
significant figure, which is the precision a string-valued `Decimal` exists to
protect.

**Where the server runs in-process, both halves are callable, and that is the
check.** One line, for every scalar at once:

```ruby
it "agrees with the server about every scalar" do
  GraphWeaver::Testing.check_scalars!(Catalog::Schema)
end
```

Per scalar the schema declares and your app registered, it fabricates a value the
way [`:fake`](testing.md) does, casts it, sends it back out through `serialize:`,
through the server's `coerce_input` and `coerce_result`, and back through `cast:`.
It raises naming every scalar that disagreed and which way:

```
2 scalar(s) disagree with Catalog::Schema:
  Money: the server refused "12.5", the wire form serialize: writes (expected "12.50 USD")
  Decimal: round-trips lossily — sent 0.123456789123456789e9, got back 0.1234567891234567e9
```

The fabricated value is all it has to work with, so pin the one that matters:
`config.overrides = { "Decimal" => "123456789.123456789" }` is how the precision
case gets exercised at all — two decimal places always survive a Float. Pass the
schema **class**; a dump's scalars pass values through, so against one this checks
only that a registration's `cast:` accepts what its own `serialize:` writes, which
is a different question (see below).

For a **remote** server the limit stands: nothing before a real request can say.
Send one — a `graphql: :in_process` example against the same schema class if your
app has one, otherwise a [cassette](cassettes.md) recorded against the real
endpoint, which carries the server's rules to a suite that can't reach it.
**`graphql: :fake` cannot stand in for either**: a fake fabricates from your
*client* registration alone, so it hands back a value the real server would never
send and accepts one the real server would reject. It is shape-correct, never
rule-correct.

### A cast must accept what its own serialize writes

One `serialize:` serves both directions — the outbound variable and a result's
[`as_json`](generated_modules.md#anatomy) — so a registration has a law to keep:
**its `cast:` must accept what its `serialize:` writes.** That is what makes
`from_h(JSON.parse(x.to_json)) == x` hold, and it is the innermost leg of
`check_scalars!` above, which is where it is checked.

A server whose `coerce_result` writes one shape and whose `coerce_input` accepts
another can't be served by one `serialize:`, so don't try: write the **result**
form, the one `cast:` reads, and have the server's `coerce_input` accept that too.
If it can't, the asymmetry is the server's to fix — a second registration keyword
for the result form would put a knob where a law belongs, and `as_json` would
still have no way to choose between them.

## Enums: map onto your own T::Enum

By default a schema enum generates one `T::Enum` per schema, shared by every query
module that touches it (`GraphQLTypes::Species`, aliased as
`AddPetMutation::Species`). That's fine until your app has its own domain enum —
one that is persisted, or matched in business logic — and then every call site
converts by hand, in both directions:

```ruby
kind = PetKind.deserialize(pet.species.serialize.downcase)   # response -> domain
AddPetMutation.execute!(species: kind.serialize.upcase)      # domain -> wire
```

Register the mapping once and the seam disappears — generated code speaks your
enum everywhere, casting wire values in and serializing members out:

```ruby
GraphWeaver.register_enum("Species", PetKind)

pet.species                                      # => PetKind::Dog — compare, case, persist directly
pet.species == other_pet.species                 # same type across every query
AddPetMutation.execute!(species: PetKind::Cat)   # or "CAT" — members and wire values both work
```

For values you only ever read back out of responses, don't bother: the generated
enum is already one type across every query and needs zero setup.

The mapping is inferred by name (`"CAT"` ↔ `PetKind::Cat`,
case/underscore-insensitive against each member's serialized value), so aligned
enums need only the one line. When names diverge, `map:` pins the exceptions and
merges over inference:
`GraphWeaver.register_enum("Species", PetKind, map: { "FELINE" => PetKind::Cat })`.

Two safety properties do the real work:

- **Exhaustiveness at generation**: every value the schema declares must resolve to
  a member, or generation fails naming the gaps (`PetKind has no member for
  Species value(s) DOG — add them, pin with map:, or absorb with fallback:`), so
  your enum drifting from the server's is caught by `rake graph_weaver:generate`,
  not in production.
- **`fallback:` for forward-compat**: `fallback: PetKind::Unknown` makes *casting*
  absorb wire values the server added after you generated, so responses keep
  flowing instead of raising. Inputs stay strict either way: a typo'd input is your
  bug, not drift. A union or interface absorbs the same drift with no registration
  — a member added upstream lands in the catch-all `Other` its dispatch always
  carries ([generated modules](generated_modules.md#abstract-types)).

The translation tables are emitted into the generated source (`SPECIES_FROM_WIRE` /
`SPECIES_TO_WIRE`) — reviewable in the diff, no runtime registry.

### Two spellings, one value

A schema mid-rename declares both `LEGACY_MODE` and `legacy_mode` so old clients
keep working. `alias:` says they are one value — both spellings cast, and the
target is what goes back on the wire:

```ruby
GraphWeaver.register_enum("Status", alias: { "legacy_mode" => "LEGACY_MODE" })
```

That is the whole registration when there is no enum of your own to map onto; it
rides along with one when there is, where it also settles which spelling a
member serializes to — inference is case/underscore-insensitive, so a rename
pair lands on a single member. Either way generation refuses rather than pick:
two values that name one Ruby constant, or that map onto one member, are
ambiguous until you say. Delete the alias when the server drops the old
spelling.

Decorating a generated *struct* with your own methods is the sibling API —
`extend_type`, in [generated modules](generated_modules.md#type-helpers).
