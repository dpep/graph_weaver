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
same registry an initializer writes, so register before you generate.

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

A date stays a `Date` and a timestamp a `Time`, deliberately: casting a date to
`Time` invents a midnight the server never sent. A schema that means something
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
| `Date` | `Date.iso8601(v)` | `v.iso8601` | `date` |
| `Time` | `Time.parse(v)` | `v.iso8601` | `time` |
| `DateTime` | `DateTime.iso8601(v)` | `v.iso8601` | `date` |

For a timestamp, reach for `Time`; Ruby's own `DateTime` is accepted if you
register it, but never assumed. `BigDecimal(v)` is Ruby's own reader, so
it takes what Ruby takes — `"12.5"`, `"1e3"`, a JSON number — and refuses
`"abc"` or `"$12.50"`, naming the field or the variable.

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

A type defining none of those stays pass-through rather than getting wrapped —
every object has `#to_s`, so inferring a serializer off it would wrap plain
types too. Override explicitly when you need to:

- a `Symbol` method name, nothing to misspell: `cast: :load` → `Money.load(expr)`,
  `serialize: :to_json` → `expr.to_json`
- an `Array`, for a method with arguments: `serialize: [:to_s, "F"]` → `expr.to_s("F")`
- a `Proc` for anything a method name can't express: `cast: ->(expr) { "Money.new(#{expr})" }`
- `:itself` to force pass-through, opting out of inference (rare)

The type also accepts a plain string (`"Money"`) when you'd rather not
reference the class. `requires:` (a string or array) names files emitted as
`require`s atop the generated source so the cast/type resolve. When the type is
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
Generation names the field:

```
register_scalar("Money", Wallet) has no cast, so nothing builds a Wallet
out of the JSON at Product.price — give it one ...
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

A refusal is a [`GraphWeaver::TypeError`](errors.md) naming the field and the
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
| `Date` | `Date` | an ISO-8601 string | `iso8601` |
| `Time` | `Time` | a string `Time.parse` takes | `iso8601` |
| `BigInt` | `Integer` | a decimal string | the decimal string, which is what the server writes |
| an enum | the member **or** its wire value | — | the wire value |
| an input object | the struct **or** a Hash | — | the wire hash |
| a registered custom scalar | its Ruby type | whatever its cast takes | what its serialize writes |
| `JSON`, or unregistered | `T.untyped` | anything | straight through |

Two rows are judgment calls worth stating. **`ID` takes an `Integer`** because
the GraphQL spec says an ID serializes as a string but accepts an integer input,
and `execute(id: user.id)` off a model is the everyday call; `String` gets no
such license, since an `Integer` where a `String` belongs is more often a bug
than a spelling. **`Boolean` takes no string** — Ruby has no `Kernel#Boolean`,
so every rule for reading `"0"`, `"off"`, `"no"` is somebody's convention, and
the library will not pick one for you; convert at the call site.

Anything the table refuses raises `GraphWeaver::InputError` naming the variable,
the operation and the value — `$count of Compute: expected an Int, got "lots"`
— which is the same [422 rescue point](errors.md) as a bad input-object field.
Input-object fields go through this table too, so `{first: "20"}` inside a
filter hash reads the same as `first: "20"` as a kwarg.

`GraphWeaver.reset_registrations!` is the clean slate between tests, or between
generations for different schemas: built-in scalars restored, enum mappings and
type helpers dropped. To reset one registry rather than all of them,
`GraphWeaver::Codegen` has the pieces —
`reset_scalars!` (restore the built-ins), `clear_scalars!` (empty the registry
entirely), `reset_enums!`, `reset_type_helpers!`.

A scalar you never register is not an error — it generates as `T.untyped` and
the wire value passes through untouched. It is, though, the one hole in an
otherwise exact result type, so generation names the holes at `info` (see
[logging](logging.md)):

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
  way: a typo'd input is your bug, not drift.

The translation tables are emitted into the generated source
(`SPECIES_FROM_WIRE` / `SPECIES_TO_WIRE`) — reviewable in the diff, no
runtime registry.

Decorating a generated *struct* with your own methods is the sibling API —
`extend_type`, in [generated modules](generated_modules.md#type-helpers).
