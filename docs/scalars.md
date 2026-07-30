# Custom scalars

Teach the generator how a GraphQL custom scalar deserializes into a rich
Ruby object (and serializes back when used as a variable). A field typed
`Money` then generates `const :price, T.nilable(Money)` and casts with
`Money.parse(...)` inline — no runtime reflection:

```ruby
GraphWeaver.register_scalar("Money", Money, requires: "bigdecimal")
```

Registrations are global by default. A [client](transports.md) scopes
them: `client.register_scalar(...)` overlays the global registry for that
client's generation only — so two servers can disagree about what a
`DateTime` is, and neither leaks into the other.

Pass a `Type.field` **coordinate** instead of a scalar name to override just
that one field — so the same scalar can deserialize as different Ruby types
across fields:

```ruby
GraphWeaver.register_scalar("ISO8601DateTime", Time)   # the default, everywhere
GraphWeaver.register_scalar("User.birthday", Date)     # this field only
```

A field override wins over the scalar-name registration; both stack the same
global-then-client way. (GraphQL names can't contain `.`, so the coordinate is
unambiguous — and it's validated against the schema, so a typo'd field raises.)

Pass a real class as `type:` and the cast/serialize are **inferred** from it by
probing the deserialize side and pairing its serializer:

| the class defines | cast          | serialize      |
|-------------------|---------------|----------------|
| `.parse`          | `Type.parse(v)` | `v.to_s`     |
| `.load`           | `Type.load(v)`  | `Type.dump(v)` |

so the common case needs nothing more. Probing the *deserialize* side is
deliberate — every object has `#to_s`, so inferring off it would wrongly wrap
plain types like `String`/`Integer`; requiring a `.parse`/`.load` the type
actually defines avoids that (and is why the built-in scalars — `Date`, `ID`,
`Int`, and friends, pre-registered and detailed below — can be registered with
their real class constants). Override explicitly when you need to:

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

Bad input still explodes (the cast raises), so some safety survives; coercion
needs both a cast and a serialize. Off by default — the strict typed kwarg is the norm.

`coerce:` also takes a **Symbol** naming a conversion method, for built-ins where
a plain method is the whole story — `coerce: :to_f` makes a variable accept
`5`/`"5"` and `.to_f` it, sending a native number (not `"5.0"`) on the wire. The
convertible built-ins already know theirs (`Float`→`:to_f`, `Int`→`:to_i`,
`ID`/`String`→`:to_s`), so rather than opting in each, flip the default:

```ruby
GraphWeaver.auto_coerce = true
```

Resolved lazily at generation time (set it any time before you generate),
it gives convertible built-ins their conversion and any scalar with a full
cast/serialize pair (`Date`, your `Money`) parse-style coercion; an explicit
`coerce:` on a registration always wins. `Boolean` has no lossless
one-method conversion, so it stays strict.

The built-in scalars (`Date`, `ID`, `Int`, …) are pre-registered through the
same path (`Date` even carries its own `require "date"`), so a later
`register_scalar` overrides them; `GraphWeaver.reset_scalars!` restores the
defaults (`reset_scalars!(coerce: true)` restores them coercible) and
`clear_scalars!` empties the registry. Register before generating — it's a
codegen-time concern, baked into the emitted source.

## Enums: map onto your own T::Enum

By default each generated module grows its own `T::Enum` per GraphQL
enum — `AddPetQuery::Species`, `SearchQuery::Result::...::Species`, one
per module that touches it. That's fine until your app has its own
domain enum, and then the boundary shuffle starts:

```ruby
# your domain already speaks PetKind — it's in your models, your
# ActiveRecord enum column, your case statements
class PetKind < T::Enum
  enums { Cat = new("cat"); Dog = new("dog") }
end

# without a mapping, every call site converts by hand, in both directions
kind = PetKind.deserialize(pet.species.serialize.downcase)      # response -> domain
AddPetQuery.execute!(species: kind.serialize.upcase)            # domain -> wire
```

Two enums for one concept, glue at every crossing, and each generated
module has its *own* incompatible `Species`, so a pet from `SearchQuery`
and a pet from `AddPetQuery` don't even compare. Register the mapping
once and the seam disappears — generated code speaks your enum
everywhere, casting wire values in and serializing members out:

```ruby
GraphWeaver.register_enum("Species", PetKind)                # global
api.register_enums("Species" => PetKind, "Role" => Role)     # or per client, in bulk

pet.species                                   # => PetKind::Dog — compare, case, persist directly
pet.species == other_pet.species              # same type across every query
AddPetQuery.execute!(species: PetKind::Cat)   # or "CAT" — members and wire values both work
```

**When to reach for it**: the enum has a life outside the API — it's
persisted, matched in business logic, or shared across queries. **When
not to bother**: display-only values you read and forget; the per-module
generated enums are self-contained and need zero setup.

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
runtime registry. And because registration can be client-scoped, two
servers with different ideas of `"Species"` can map onto different (or
the same) domain enums without touching each other.

## Type helpers: your logic on generated structs

Derived values (display names, emoji, predicates) belong next to the
data but not *in* it — rewriting wire values on the way in destroys the
raw truth. Register a plain module and every struct generated from that
GraphQL type includes it, whatever query it appears in:

```ruby
module PetHelpers
  def adult? = birthday && birthday < Date.today << 24
  def display_name = adult? ? "#{name} 🦴" : "#{name} 🐶"
end

GraphWeaver.extend_type("Pet", PetHelpers)   # or api.extend_type(...)

pet.display_name   # => "Shelby 🦴"
pet.name           # => "Shelby" — the wire value stays honest
```

The methods live on the struct, so they see its wire fields at runtime and
fakes/cassettes get the behavior automatically; registrations are additive
(global plus client-scoped stack). One caveat on *static* typing, though:
`srb tc` checks a mixin's method bodies in the module's own scope, not the
including struct's — so a helper that reads a wire field (`name`, `birthday`)
doesn't resolve it and fails with "method does not exist on the module." Write
such a helper at `# typed: false`, or reach the field through `T.unsafe(self)`
— either way its body isn't statically checked against the selection. (Sorbet's
`requires_ancestor` is the escape in principle, but it needs an experimental
flag and a concrete ancestor, which a per-query struct isn't.) The only place a
field-reading derivation type-checks natively is *inside* the struct body, where
the field is in scope — which is codegen's job, not a mixin's.

For quick decoration, build the mixin inline — the block is
`module_eval`'d into a fresh module auto-named under
`GraphWeaver::TypeHelpers` so generated files can reference it:

```ruby
api.extend_type("Pet") do
  def display_name = "#{name} 🐶"
end
```

Same runtime behavior, less static reach: the block becomes a runtime module
with no source on disk, so `srb tc` can't see its methods at all — fine in
dynamic `parse`, but in a checked-in `# typed: strict` file it's an unresolved
reference. Prefer a named module (and mind the field-access caveat above) where
static checking matters — complexity on demand.
