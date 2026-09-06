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

so the common case needs nothing more. Only the *deserialize* side is probed —
every object has `#to_s`, so a type defining neither `.parse` nor `.load` stays
pass-through rather than getting wrapped (which is how the built-ins name their
real classes). Override explicitly when you need to:

- a `Symbol` method name, nothing to misspell: `cast: :load` → `Money.load(expr)`,
  `serialize: :to_json` → `expr.to_json`
- a `Proc` for anything a method name can't express: `cast: ->(expr) { "Money.new(#{expr})" }`
- `:itself` to force pass-through, opting out of inference (rare)

`type:` also accepts a plain string (`"BigDecimal"`) when you'd rather not
reference the class. `requires:` (a string or array) names files emitted as
`require`s atop the generated source so the cast/type resolve. When `type:` is
a real class (so the runtime is loaded), each path is also `require`d at
registration — a typo fails now, not in the generated file.

Pass `coerce: true` to let a variable of this scalar accept **either** the value
object **or** its raw input, normalizing the latter through the cast:

```ruby
GraphWeaver.register_scalar("Money", Money, coerce: true)
# generated execute now takes T.any(Money, String); "12.00" is parsed
StoreQuery.execute(budget: "12.00")          # Money.parse("12.00") under the hood
StoreQuery.execute(budget: Money.new(1200))  # passed straight through
```

Bad input still explodes (the cast raises), and coercion needs both a cast and a
serialize. Off by default — the strict typed kwarg is the norm.

`coerce:` also takes a **Symbol** naming a conversion method — `coerce: :to_f`
makes a variable accept `5`/`"5"` and `.to_f` it, sending a native number (not
`"5.0"`) on the wire. The convertible built-ins already know theirs
(`Float`→`:to_f`, `Int`→`:to_i`), so rather than opting in each, flip the
default:

```ruby
GraphWeaver.auto_coerce = true
```

Resolved lazily at generation time (set it any time before you generate), it
gives convertible built-ins their conversion and any scalar with a full
cast/serialize pair (`Date`, your `Money`) parse-style coercion; an explicit
`coerce:` on a registration always wins. `Boolean`, `String` and `ID` stay
strict — `#to_s` is a cast that can't fail, so widening them would erase static
typing on most real variables to buy nothing;
`register_scalar("ID", String, coerce: :to_s)` opts in deliberately.

The built-in scalars (`Date`, `ID`, `Int`, …) are pre-registered through the
same path (`Date` even carries its own `require "date"`), so a later
`register_scalar` overrides them; `GraphWeaver.reset_scalars!` restores the
defaults and `clear_scalars!` empties the registry.

A scalar you never register is not an error — it generates as `T.untyped` and
the wire value passes through untouched. It is, though, the one hole in an
otherwise exact result type, so generation names the holes at `info` (see
[logging](logging.md)):

```
3 unregistered custom scalars → T.untyped: CountryCode, FuzzyDateInt, Json (register with GraphWeaver.register_scalar)
```

## Enums: map onto your own T::Enum

By default a schema enum generates one `T::Enum` per schema, shared by every
query module that touches it (`GraphQLEnums::Species`, aliased as
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
