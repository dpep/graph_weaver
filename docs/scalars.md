# Custom scalars

Teach the generator how a GraphQL custom scalar deserializes into a rich
Ruby object (and serializes back when used as a variable). A field typed
`Decimal` then generates `const :price, T.nilable(BigDecimal)` and casts with
`BigDecimal(...)` inline — no runtime reflection:

```ruby
GraphWeaver.register_scalar("Decimal", BigDecimal)
```

Two arguments: the scalar's name in your schema, and the Ruby type it means.
The second is the only part the library can't work out — how a wire value
becomes a `BigDecimal`, how one goes back on the wire, and the
`require "bigdecimal"` the generated file needs are all inferred.

Registration is global and codegen-time: `rake graph_weaver:generate` reads the
same registry an initializer writes, so register before you generate. A
registration that goes *missing* later — a reverted initializer line, a bad
merge — is loud at generate/verify time, which name the files it moves, and
silent forever after: code regenerated without it casts the field to the plain
wire type (a `String` where an `Email` was) and nothing raises anywhere.
[`verify_generated!`](generated_modules.md) in CI is what protects a
registration; no runtime assertion can.

## Already registered

These names need no registration. graphql-ruby ships all but `DateTime` as its
own scalars, and `DateTime` is what GitHub, Shopify and most hand-written
schemas call an ISO 8601 timestamp.

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

A date stays a `Date` and a timestamp a `Time`, deliberately, and that holds in
both directions: casting a date to `Time` invents a midnight the server never
sent, and sending a `Time` for a date variable drops the time of day. Give one
for the other and it is refused, naming the class —
`$on of Report: expected a Date, got a Time — pass .to_date if dropping the
time of day is what you meant`. That holds when you register your own `cast:`
too: a cast says how the Ruby object is *built*, not which values are right, so
a `DateTime` — which Ruby files under `Date` — is refused for a `Date` scalar
however the codec is spelled. The refusal is about Ruby **objects**: a
timestamp *string* given for a `Date` parses and truncates to its date, which
is what graphql-ruby's own `ISO8601Date` does with it. A schema that means something
else by one of these names fails loudly — the cast raises, naming the field —
and one `register_scalar` overrides it, like any other entry. Names that are
*not* a convention (`Timestamp`, `UUID`, `URL`, `Decimal`, `Money`) are left to
you, because guessing at one would be worse than asking.

## Registering a stdlib type

Name the class and stop. What the library supplies is the part inference can't
reach: the wire spelling (`BigDecimal#to_s` writes `"0.125e2"`, which is not
what any server means by 12.5, and `Date.parse` reads far more than the ISO
8601 a `Date` scalar carries) and the file to require, so the generated source
stands alone.

| Ruby type | cast | serialize | require |
|---|---|---|---|
| `BigDecimal` | `BigDecimal(v)` | `v.to_s("F")` | `bigdecimal` |
| `Float` | `GraphWeaver::Coerce.float(v)` | — | — |
| `Date` | `Date.iso8601(v)` | `v.strftime("%F")` | `date` |
| `Time` | `Time.parse(v)` | `GraphWeaver::Coerce.timestamp(v)` | `time` |
| `DateTime` | `DateTime.iso8601(v)` | `GraphWeaver::Coerce.timestamp(v)` | `date` |

For a timestamp, reach for `Time`; Ruby's own `DateTime` is accepted if you
register it, but never assumed. They don't cost the same per value:
`DateTime.iso8601` measures about 1.6× `Date.iso8601`, and `Time.parse` — what
a `Time` registration infers, so what every `DateTime`/`ISO8601DateTime` field
already casts through — about 7×, since it is the tolerant reader rather than a
strict one. That is noise beside the `T::Struct` construction around it until
you're casting thousands of timestamps per response; there,
`register_scalar("Timestamp", Time, cast: :iso8601)` is about 3× cheaper than
`Time.parse` and refuses the looser forms, which is the trade.
`BigDecimal(v)` is Ruby's own reader, so
it takes what Ruby takes — `"12.5"`, `"1e3"`, a JSON number — and refuses
`"abc"` or `"$12.50"`, naming the field or the variable.

**A trailing zero doesn't survive the round trip.** A `BigDecimal` holds the
*number*, so `"10.00"` in comes back `"10.0"` — `to_s("F")` writes the value,
not the spelling. Numerically identical, textually different, which matters
only where the bytes are: diffing a request body, or hashing one for a
signature. Keep the string the user typed if that is what you need to compare.

## Registering a class of your own

Pass the class and the cast/serialize are **inferred** from it, by probing the
deserialize side and pairing its serializer:

| the class defines | cast | serialize |
|-------------------|---------------|----------------|
| `.parse` | `Type.parse(v)` | `v.to_s` |
| `.load` | `Type.load(v)` | `Type.dump(v)` |
| `Kernel#Type` | `Type(v)` | — |

so a value object with a `.parse` needs nothing more:

```ruby
GraphWeaver.register_scalar("Money", Money)
```

**Give it `eql?` and `hash` too, not just `==`.** A result compares its props
with `eql?`, so that it and `#hash` agree on what "same" means — a class that
stops at `==` makes two results parsed from the same response unequal, and
useless as hash keys, while the `Money` inside them compares fine. Registration
warns when it spots one. `alias_method :eql?, :==` plus a `hash` built from the
same values is the whole fix.

A type defining none of those stays pass-through rather than getting wrapped —
every object has `#to_s`, so inferring a serializer off it would wrap plain
types too. That is about not *inventing* a codec, not about the cast being
optional: a class JSON can't parse into is still refused (below) the moment a
query reads that field. Override explicitly when you need to:

- a `Symbol` method name, nothing to misspell: `cast: :load` → `Money.load(expr)`,
  `serialize: :to_json` → `expr.to_json`
- an `Array`, for a method with arguments: `serialize: [:to_s, "F"]` → `expr.to_s("F")`
- a `Proc` for anything a method name can't express: `cast: ->(expr) { "Money.new(#{expr})" }`
- `:itself` to force pass-through, opting out of inference (rare)

Not every class is so obliging, and the money gem's `Money` is the honest hard
case: it defines none of those probes, so you say how one is built. **A cast can
only use what the wire carries**, and `Money.from_amount` needs a currency no
amount of Ruby recovers if the response didn't send one. So the scalar's shape
decides the registration, and three shapes carry it.

**An object** — `{"amount": "12.50", "currency": "EUR"}`. The cast reads both
out of it, and `serialize:` writes the same hash back:

```ruby
GraphWeaver.register_scalar("Money", Money,
  cast: ->(v) { "Money.from_amount(BigDecimal(#{v}[\"amount\"]), #{v}[\"currency\"])" },
  serialize: ->(v) { "{ \"amount\" => #{v}.amount.to_s(\"F\"), \"currency\" => #{v}.currency }" })
```

**One string carrying both** — `"12.50 EUR"`, split in the cast, with
`serialize: :to_s` writing it back when that is the spelling `Money#to_s` gives.

**An object type rather than a scalar** — `Money { amount currency }` — which
needs no `register_scalar` at all: codegen types both fields, and
[`extend_type`](generated_modules.md#type-helpers) adds the conversion. Ask for
this shape if you get a vote; the currency is then in the schema, where a reader
finds it.

```ruby
GraphWeaver.extend_type("Money") { def to_money = ::Money.from_amount(BigDecimal(amount), currency) }
```

**A bare decimal string** — `"12.50"` — carries no currency, so the cast has to
supply one. Reach for this only when the API really is single-currency, and say
so where the next reader will look:

```ruby
# single-currency API: a Money in any other currency comes back mislabelled
GraphWeaver.register_scalar("Money", Money,
  cast: ->(v) { "Money.from_amount(BigDecimal(#{v}), \"USD\")" },
  serialize: :to_s)
```

The `cast:` proc returns **source, not a value** — generated code is static, so
what comes back is the expression inlined into `from_h`, here
`Money.from_amount(BigDecimal(data.fetch("price")), "USD")`. `serialize: :to_s`
is the inverse, and it's the right one of three near-identical candidates:
`Money#to_s` writes a plain `"12.50"` — no symbol, no thousands separator, and
it ignores your app's `default_formatting_rules` — while `#to_d` and its alias
`#amount` hand back a `BigDecimal`, which reaches the wire as `"0.125e2"`.

**Register what your cast returns, not where the factory method lives.**
`register_scalar("URL", URI)` looks right and runs fine — `URI.parse` is a
probe hit — but `URI` is a *module*, and Sorbet's payload for it doesn't
`include Kernel`, so every call site that touches the prop fails `srb tc` with
"Method `nil?` does not exist on `URI`". The value is a `URI::Generic`, so
register that and say where it comes from:

```ruby
GraphWeaver.register_scalar("URL", URI::Generic, cast: ->(v) { "URI.parse(#{v})" })
```

`URI.parse` is ASCII-only, so a server that writes an un-escaped unicode path
(`https://example.com/café`) raises `URI must be ascii only` — a clean
`CastError` naming the field, but a refusal of a URL that is fine. Escape
before parsing (`URI::DEFAULT_PARSER.escape(#{v})`), or register
[Addressable](https://github.com/sporkmonger/addressable), which takes unicode
as it comes.

The type also accepts a plain string (`"Money"`) when you'd rather not
reference the class — which **skips inference entirely**, since there is no
class in hand to probe: a string-registered type with no `cast:` of its own has
none, and the refusal below says so rather than pretending it was probed.
`requires:` (a string or array) names files emitted as `require`s atop the
generated source so the cast/type resolve. When the type is
a real class (so the runtime is loaded), each path is also `require`d at
registration — a typo fails now, not in the generated file.

## Overriding one field

Pass a `Type.field` **coordinate** instead of a scalar name to override just
that one field — so the same scalar can deserialize as different Ruby types
across fields:

```ruby
GraphWeaver.register_scalar("Timestamp", Time)      # the default, everywhere
GraphWeaver.register_scalar("User.birthday", Date)  # this field only
```

A field override wins over the scalar-name registration — which is also how two
servers that disagree about a `DateTime` coexist in one process.

A coordinate takes a **type string** too, which is how you narrow `JSON`. A
`JSON` scalar can legally be any JSON value — an object, an array, a string, a
number — so the registry's answer for the whole scalar has to stay `T.untyped`.
Where *you* know one field's shape, say it there:

```ruby
GraphWeaver.register_scalar("Settings.meta", "T::Hash[String, T.untyped]")
```

The prop becomes `T.nilable(T::Hash[String, T.untyped])`, so `srb tc` sees a
Hash at every call site, and a response carrying something else is refused
naming the struct instead of surfacing as a `NoMethodError` three layers on.
That's a trade rather than a free win: an array the scalar allowed is now a
hard failure — you asserted the shape, so being right about it is on you. It
also opts that field out of `:fake` fabrication, for the same reason any
non-stdlib type is: only you know which hashes the field really carries, so pin
it (`overrides: { "Settings.meta" => { ... } }`).

Registrations are validated against the schema you generate against, and only
what that schema can **disprove** fails generation: a name it declares as
something else (`register_scalar("Species")` where `Species` is an enum), or a
coordinate whose field it declares as a composite. A name it simply can't match
only warns — one registry serves a whole graph, so that name may belong to the
subgraph next door (see
[federation](federation.md#generating-for-a-federated-graph)).

The testing harness can't invent a wire value for a scalar registered as your
own class — only `Money.parse` knows what it accepts — so it refuses rather than
guess. Say it in test config, where that answer belongs: a pin for the type,
`GraphWeaver::Testing.config.overrides = { "Money" => "12.00" }`, or per example
([testing → pins](testing.md#pins)). A scalar registered as one of the types
above — `BigDecimal`, `Time`, `Date`, `Integer`, `Float`, `String`,
`T::Boolean` — needs nothing.

A registration whose type is a class **JSON can't parse into**, with nothing to
build one, is refused where a query reads that scalar back: the prop would be
unsatisfiable for every response, and finding that out at runtime is worse.
Generation names the field, and which of the two mistakes you made — a class
the probes missed:

```
register_scalar("Money", Wallet) has no cast, so nothing builds a Wallet out of
the JSON at Product.price — Wallet defines no .parse and no .load, and Kernel
has no Wallet conversion function, so there was nothing to infer. Give it a
cast ...
```

or a type given by name, which is never probed:

```
register_scalar("Money", "Wallet") has no cast, so nothing builds a Wallet out
of the JSON at Product.price — a type: given by name is never probed, since
there is no class in hand. Pass the class ...
```

A registration used only for a variable is untouched: nothing casts it.

`cast:` is also what a *variable* of this scalar coerces through, so the same
registration gets you both directions with nothing to switch on:

```ruby
GraphWeaver.register_scalar("Money", Money)
StoreQuery.execute(budget: "12.00")          # Money.parse("12.00") under the hood
StoreQuery.execute(budget: Money.new(1200))  # already a Money — passed straight through
```

The kwarg is still typed `Money`, not `T.any(Money, String)`: `execute`'s sig
stays as narrow as the schema and the conversion happens in its body (see
[typed variables](generated_modules.md#variables-become-typed-kwargs)). So
`budget: "12.00"` written literally in a `# typed:` file is still an `srb tc`
error — as it should be, since you have a `Money` right there — while
`budget: params[:budget]` typechecks and converts.


## What the wire carries

The rule is one sentence: **generated code takes every JSON spelling a
spec-compliant server may write, and refuses the rest.** The tables below are
the whole of it, and [`bin/round-trip`](../bin/round-trip) fuzzes both
directions against them — the accepted spellings as real values, the refused
ones under `--hostile`, where generated code has to name what it turned down.

The one place "spec-compliant" is doing real work is `Float`. JSON has a single
number type and encoders write the shortest form, so `1.0` reaches Ruby as `1`
from graphql-js and from Go. Nothing does the reverse: `2.0` for an `Int` is the
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
| `DateTime`/`Time` (registered as `Time`) | RFC 3339 with `Z` or an offset, with or without fractional seconds, seconds optional; also a bare date and `Time.parse`'s looser forms | an epoch integer, an unparseable string |
| `BigInt` | the decimal string graphql-ruby writes, past 2⁵³ included; also a JSON integer | `1.5`, `"1.5"`, a non-numeric string, `true` |
| an enum | a declared value, as a string | an undeclared value, a non-string |
| `JSON`, or unregistered | anything — `T.untyped`, straight through | nothing |

A refusal is a [`GraphWeaver::CastError`](errors.md) naming the field and the
generated struct (which names the query). Two refusals carry advice rather than
only sorbet's words: an unquoted `ID`, and a registration with no cast (above).

Numeric strings — here, and in the going-out table below — are read as a wire
format, not as Ruby source: `"010"` is ten, and `"0x1f"` and `"1_0"` are
refused. `Kernel#Integer` and `Kernel#Float` accept all three as literals,
which would let a zero-padded form field silently mean something else.

### Going out — what a variable kwarg accepts

The kwarg's **type** is what `srb tc` holds a call site to, and it is exactly
what the schema says. The **value** reaching `execute` at runtime is coerced,
because a Rails param is a String whatever the sig says (see
[typed variables](generated_modules.md#variables-become-typed-kwargs) for why
the sig is `.checked(:never)`).

| scalar | kwarg is typed | also accepts, at runtime | on the wire |
|---|---|---|---|
| `Int` | `Integer` | a decimal string, a whole `Float` | the integer |
| `Float` | `Float` | a decimal string, an `Integer` | the float |
| `String` | `String` | nothing | the string |
| `ID` | `String` | an `Integer` — `execute(id: user.id)` | the string |
| `Boolean` | `true`/`false` | nothing | the boolean |
| `Date` | `Date` | an ISO-8601 string | `"2024-01-15"` |
| `Time` | `Time` | a string `Time.parse` takes, a `DateTime`, `Time.zone.now` | ISO 8601, with microseconds when the value carries a fraction |
| `BigInt` | `Integer` | a decimal string | the decimal string, which is what the server writes |
| an enum | the member **or** its wire value | — | the wire value |
| an input object | the struct **or** a Hash | — | the wire hash |
| a registered custom scalar | its Ruby type | whatever its cast takes | what its serialize writes |
| `JSON`, or unregistered | `T.untyped` | anything | straight through |

The **on the wire** column is also what a result's
[`#as_json`/`#to_json`](generated_modules.md#anatomy)
writes, so a result read back with `from_h` equals the one you rendered.

**Writing the scalar on the server too?** graphql-ruby calls a *nullable*
scalar argument's `coerce_input` with `nil` for an explicit `null` — only
`NonNull` short-circuits — so a coercer written the way the examples above are
(`value.upcase`, `Money.parse(value)`) raises `NoMethodError` on nil. Guard it,
or `:in_process` will show it to you as a `ServerError`.

Two rows are judgment calls worth stating. **`ID` takes an `Integer`** because
the GraphQL spec says an ID serializes as a string but accepts an integer input,
and `execute(id: user.id)` off a model is the everyday call; `String` gets no
such license, since an `Integer` where a `String` belongs is more often a bug
than a spelling. **`Boolean` takes no string** — Ruby has no `Kernel#Boolean`,
so every rule for reading `"0"`, `"off"`, `"no"` is somebody's convention, and
the library will not pick one for you; convert at the call site. **A `Date` and
a `Time` are not each other** — one converts to the other only by dropping the
time of day or inventing a midnight, so a cross-type Ruby **object** is refused
rather than truncated. A timestamp *string* is a different question, answered
by the wire table above: it truncates. What *is* accepted for a `Time` is anything that already is one:
a `DateTime`, or the `ActiveSupport::TimeWithZone` that `Time.zone.now` returns.

Anything the table refuses raises `GraphWeaver::InputError` naming the variable,
the operation and the value — `$count of Compute: expected an Int, got "lots"`
— which is the same [422 rescue point](errors.md) as a bad input-object field.
It is named the way the **schema** names it, so a `register_scalar("Money",
BigDecimal)` field refuses a `Money`, in `#message` and in `#details[:type]`
alike. Input-object fields go through this table too, so `{first: "20"}` inside
a filter hash reads the same as `first: "20"` as a kwarg.

When it is the **server's** custom scalar that refuses, its
`GraphQL::CoercionError` earns a specific
[`kind`](errors.md#what-an-inputerror-says-without-reading-english) only where
its message matches one of graphql-ruby's own explanations, or the scalar
raises with `extensions: { "input" => … }`
([the convention](errors.md#what-your-server-can-send)) itself — a scalar's own
wording arrives `:refused`, with that wording.

`GraphWeaver.reset_registrations!` is the clean slate between tests: built-in
scalars restored, enum mappings and type helpers dropped. `GraphWeaver.reset_graphs!`
is its twin for graphs declared with `GraphWeaver.graph`. To reset one registry
rather than all of them,
`GraphWeaver::Codegen` has the pieces —
`reset_scalars!` (restore the built-ins), `clear_scalars!` (empty the registry
entirely), `reset_enums!`, `reset_type_helpers!`.

Scoping registrations to one of several schemas is not what this is for — a
[graph](getting_started.md#more-than-one-schema) block does that, and holds both
sets at once instead of resetting between them.

A scalar you never register is not an error — it generates as `T.untyped` and
the wire value passes through untouched. It is, though, the one hole in an
otherwise exact result type, so generation names the holes. `rake
graph_weaver:generate` and `:verify` print them once for the run, and a
`GraphWeaver.parse` says the same thing at `info` (see [logging](logging.md)):

```
3 unregistered custom scalars → T.untyped: CountryCode, FuzzyDateInt, Json (register with GraphWeaver.register_scalar)
```

A scalar that is *meant* to be untyped belongs in the registry too —
`GraphWeaver.register_scalar("Json", "T.untyped")` says so once, and it leaves
the report. `JSON` is registered that way already.

## Enums: map onto your own T::Enum

By default a schema enum generates one `T::Enum` per schema, shared by every
query module that touches it (`GraphQLTypes::Species`, aliased as
`AddPetMutation::Species`). That's fine until your app has its own domain
enum, and then the boundary shuffle starts:

```ruby
# your domain already speaks PetKind — it's in your models, your
# ActiveRecord enum column, your case statements
class PetKind < T::Enum
  enums { Cat = new("cat"); Dog = new("dog") }
end

# without a mapping, every call site converts by hand, in both directions
kind = PetKind.deserialize(pet.species.serialize.downcase)      # response -> domain
AddPetMutation.execute!(species: kind.serialize.upcase)            # domain -> wire
```

Register the mapping once and the seam disappears — generated code speaks your
enum everywhere, casting wire values in and serializing members out:

```ruby
GraphWeaver.register_enum("Species", PetKind)

pet.species                                   # => PetKind::Dog — compare, case, persist directly
pet.species == other_pet.species              # same type across every query
AddPetMutation.execute!(species: PetKind::Cat)   # or "CAT" — members and wire values both work
```

**When to reach for it**: the enum has a life outside the API — it's
persisted or matched in business logic. **When not to bother**: values you
only read back out of responses; the generated enum is already one type
across every query and needs zero setup.

The mapping is inferred by name (`"CAT"` ↔ `PetKind::Cat`,
case/underscore-insensitive against each member's serialized value), so
aligned enums need only the one line. When names diverge, `map:` pins the
exceptions and merges over inference:

```ruby
GraphWeaver.register_enum("Species", PetKind, map: { "FELINE" => PetKind::Cat })
```

Two safety properties do the real work:

- **Exhaustiveness at generation**: every value the schema declares must
  resolve to a member, or generation fails naming the gaps
  (`PetKind has no member for Species value(s) DOG — add them, pin with
  map:, or absorb with fallback:`). Your enum drifting from the server's
  is caught at `rake graph_weaver:generate`, not in production.
- **`fallback:` for forward-compat**: `fallback: PetKind::Unknown` makes
  *casting* absorb wire values the server added after you generated —
  responses keep flowing instead of raising. Inputs stay strict either
  way: a typo'd input is your bug, not drift. A union or interface absorbs
  the same drift without a registration: a member added upstream lands in the
  catch-all `Other` its dispatch always carries
  ([generated modules](generated_modules.md#abstract-types)).

The translation tables are emitted into the generated source
(`SPECIES_FROM_WIRE` / `SPECIES_TO_WIRE`) — reviewable in the diff, no
runtime registry.

Decorating a generated *struct* with your own methods is the sibling API —
`extend_type`, in [generated modules](generated_modules.md#type-helpers).
