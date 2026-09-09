# Custom scalars

Teach the generator how a GraphQL custom scalar deserializes into a rich
Ruby object (and serializes back when used as a variable). A field typed
`Money` then generates `const :price, T.nilable(Money)` and casts with
`Money.parse(...)` inline — no runtime reflection:

```ruby
GraphWeaver.register_scalar("Money", Money, requires: "bigdecimal")
```

Registration is global and codegen-time: `rake graph_weaver:generate` reads the
same registry an initializer writes, so register before you generate.

Pass a `Type.field` **coordinate** instead of a scalar name to override just
that one field — so the same scalar can deserialize as different Ruby types
across fields:

```ruby
GraphWeaver.register_scalar("ISO8601DateTime", Time)   # the default, everywhere
GraphWeaver.register_scalar("User.birthday", Date)     # this field only
```

A field override wins over the scalar-name registration — which is also how two
servers that disagree about a `DateTime` coexist in one process. Coordinates are
validated against the schema, so a typo'd field raises.

Pass a real class as `type:` and the cast/serialize are **inferred** from it by
probing the deserialize side and pairing its serializer:

| the class defines | cast          | serialize      |
|-------------------|---------------|----------------|
| `.parse`          | `Type.parse(v)` | `v.to_s`     |
| `.load`           | `Type.load(v)`  | `Type.dump(v)` |

so the common case needs nothing more. A type defining neither `.parse` nor
`.load` stays pass-through rather than getting wrapped. Override explicitly when
you need to:

- a `Symbol` method name, nothing to misspell: `cast: :load` → `Money.load(expr)`,
  `serialize: :to_json` → `expr.to_json`
- a `Proc` for anything a method name can't express: `cast: ->(expr) { "Money.new(#{expr})" }`
- `:itself` to force pass-through, opting out of inference (rare)

`type:` also accepts a plain string (`"BigDecimal"`) when you'd rather not
reference the class. `requires:` (a string or array) names files emitted as
`require`s atop the generated source so the cast/type resolve. When `type:` is
a real class (so the runtime is loaded), each path is also `require`d at
registration — a typo fails now, not in the generated file.

Pass `fake:` to say what the testing harness should fabricate for this scalar —
the **wire** value, before your `cast:` runs. Only the registration can know
one: `Money.parse` accepts what its author decided it accepts.

```ruby
GraphWeaver.register_scalar("Money", Money, fake: "12.00")
GraphWeaver.register_scalar("Money", Money, fake: ->(rng) { format("%.2f", rng.rand(1.0..100.0)) })
```

A proc is handed the seeded `Random`, so `rspec --seed` still reproduces the
run. Needed only when `type:` is a class the harness can't write for — a scalar
registered as `Time`, `Date`, `Integer`, `Float`, `String` or `T::Boolean` needs
nothing, and neither do the built-ins. Without one, [`FakeClient`](testing.md)
and cassette anonymization refuse at fabrication time rather than handing your
cast a placeholder.

A registration whose `type:` is a class **JSON can't parse into** needs a
`cast:` to build one — `BigDecimal` is the one people reach for, and it defines
neither `.parse` nor `.load`, so inference finds no codec and the prop would be
unsatisfiable. Generation refuses it where a query reads that scalar back,
naming the field:

```
register_scalar("Money", BigDecimal) has no cast, so nothing builds a BigDecimal
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

The built-in scalars (`Date`, `ID`, `Int`, …) are pre-registered through the
same path (`Date` even carries its own `require "date"`), so a later
`register_scalar` overrides them.

## What the wire carries

The rule is one sentence: **generated code takes every JSON spelling a
spec-compliant server may write, and refuses the rest.** The table is the whole
of it — [`bin/round-trip`](../bin/round-trip) draws from the same lists, in both
modes, so the two can't drift.

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
| an enum | a declared value, as a string | an undeclared value, a non-string |
| unregistered | anything — `T.untyped`, straight through | nothing |

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
| an enum | the member **or** its wire value | — | the wire value |
| an input object | the struct **or** a Hash | — | the wire hash |
| a registered custom scalar | its Ruby type | whatever its `cast:` takes | its `serialize:` |
| unregistered | `T.untyped` | anything | straight through |

Two rows are judgement calls worth stating. **`ID` takes an `Integer`** because
the GraphQL spec says an ID serializes as a string but accepts an integer input,
and `execute(id: user.id)` off a model is the everyday call; `String` gets no
such licence, since an `Integer` where a `String` belongs is more often a bug
than a spelling. **`Boolean` takes no string** — Ruby has no `Kernel#Boolean`,
so every rule for reading `"0"`, `"off"`, `"no"` is somebody's convention, and
the library will not pick one for you; convert at the call site.

Anything the table refuses raises `GraphWeaver::InputError` naming the variable,
the operation and the value — `$count of Compute: expected an Int, got "lots"`
— which is the same [422 rescue point](errors.md) as a bad input-object field.
Input-object fields go through this table too, so `{first: "20"}` inside a
filter hash reads the same as `first: "20"` as a kwarg.

`GraphWeaver.reset_registrations!` is the clean slate between tests: built-in
scalars restored, enum mappings and type helpers dropped. To reset one registry
rather than all of them, `GraphWeaver::Codegen` has the pieces —
`reset_scalars!` (restore the built-ins), `clear_scalars!` (empty the registry
entirely), `reset_enums!`, `reset_type_helpers!`.

A scalar you never register is not an error — it generates as `T.untyped` and
the wire value passes through untouched. It is, though, the one hole in an
otherwise exact result type, so generation names the holes at `info` (see
[logging](logging.md)):

```
3 unregistered custom scalars → T.untyped: CountryCode, FuzzyDateInt, Json (register with GraphWeaver.register_scalar)
```

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
