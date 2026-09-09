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

Pass `coerce: true` to let a variable of this scalar accept **either** the value
object **or** its raw input, normalizing the latter before it goes on the wire:

```ruby
GraphWeaver.register_scalar("Money", Money, coerce: true)
# generated execute now takes T.any(Money, String); "12.00" is parsed
StoreQuery.execute(budget: "12.00")          # Money.parse("12.00") under the hood
StoreQuery.execute(budget: Money.new(1200))  # passed straight through
```

`GraphWeaver.auto_coerce = true` is the same switch for every scalar at once —
set it any time before you generate; an explicit `coerce:` on a registration
always wins. Off by default either way: the strict typed kwarg is the norm.

*How* a scalar coerces isn't yours to pick — the scalar already knows. `Int` and
`Float` convert (`"5"` → `5`, sent as a native number); anything with a full
cast/serialize pair (`Date`, your `Money`) parses, and bad input still explodes
because the cast raises. A pass-through scalar — `String`, `ID`, `Boolean` — has
neither a conversion nor a codec pair, so it can't coerce at all: `coerce: true`
on one raises rather than emitting a no-op.

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
| `Float` | any JSON number, `3` and `-0.0` and `1e308` included; also a numeric string | a non-numeric string, `true`, a list/object |
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

`Float`'s tolerance of numeric strings is `Kernel#Float`'s, which also takes
Ruby literal syntax — `"0x1f"` reads as `31.0`. No server writes that, but it is
the one place the table is wider than the spec.

### Going out — what a variable kwarg accepts

Strict by default; the right column is what `coerce: true` — or
`GraphWeaver.auto_coerce` — adds.

| scalar | kwarg takes | on the wire | with coercion |
|---|---|---|---|
| `Int` | `Integer` | the integer | `Integer\|Float\|String`, via `.to_i` |
| `Float` | `Float` | the float | `Float\|Integer\|String`, via `.to_f` |
| `String`, `ID` | `String` | the string | nothing to add — `coerce: true` raises |
| `Boolean` | `true`/`false` | the boolean | nothing to add — `coerce: true` raises |
| `Date` | `Date` | `iso8601` | `Date\|String`, parsed with `Date.iso8601` |
| `Time` | `Time` | `iso8601` | `Time\|String`, parsed with `Time.parse` |
| an enum | the member **or** its wire value | the wire value | always on |
| an input object | the struct **or** a Hash | the wire hash | always on |

A wrong-typed kwarg is caught by `srb tc` at the call site; at runtime it is
sorbet's own `TypeError`, not a `GraphWeaver::InputError` — that one covers the
input shapes sorbet can't see (an unknown key, a missing required field, an
out-of-range enum).

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
