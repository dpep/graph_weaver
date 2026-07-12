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
`ID`/`String`→`:to_s`), so rather than re-registering each, flip them all on at
once:

```ruby
GraphWeaver.reset_scalars!(coerce: true)   # reload built-ins as coercible
GraphWeaver.register_scalar("Money", ...)  # then add your own
```

`Boolean` and `Date` have no lossless one-method conversion, so they stay strict.

The built-in scalars (`Date`, `ID`, `Int`, …) are pre-registered through the
same path (`Date` even carries its own `require "date"`), so a later
`register_scalar` overrides them; `GraphWeaver.reset_scalars!` restores the
defaults (`reset_scalars!(coerce: true)` restores them coercible) and
`clear_scalars!` empties the registry. Register before generating — it's a
codegen-time concern, baked into the emitted source.

## Enums: map onto your own T::Enum

By default each generated module grows its own `T::Enum` per GraphQL
enum. When your app already owns the enum, register the mapping and
generated code speaks yours instead — casting wire values in,
serializing members out:

```ruby
class PetKind < T::Enum
  enums { Cat = new("cat"); Dog = new("dog") }
end

GraphWeaver.register_enum("Species", PetKind)      # global
api.register_enums("Species" => PetKind, "Role" => Role)  # or per client, in bulk

pet.species                                # => PetKind::Dog (yours, everywhere)
AddPetQuery.execute!(species: PetKind::Cat)  # or "CAT" — members and wire values both work
```

The mapping is inferred by name (`"CAT"` ↔ `PetKind::Cat`,
case/underscore-insensitive against each member's serialized value);
`map: { "CAT" => PetKind::Feline }` pins renames and merges over
inference. Generation **fails naming any schema value that doesn't
resolve** — exhaustiveness checked before runtime — unless
`fallback: PetKind::Unknown` absorbs unknown wire values on cast
(forward-compat for servers that add members; inputs stay strict, since a
typo'd input is your bug, not drift). The translation tables are emitted
into the generated source (`SPECIES_FROM_WIRE` / `SPECIES_TO_WIRE`) —
reviewable, no runtime registry.

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

GraphWeaver.register_type("Pet", PetHelpers)   # or api.register_type(...)

pet.display_name   # => "Shelby 🦴"
pet.name           # => "Shelby" — the wire value stays honest
```

Because the include is emitted into the generated source, `srb tc` checks
the helpers against each query's actual selection — a helper that calls
`birthday` on a query that never selected it is a **static error**, which
doubles as selection-completeness checking. Registrations are additive
(global plus client-scoped stack), and fakes/cassettes get the behavior
automatically since it lives on the struct.

For quick decoration, build the mixin inline — the block is
`module_eval`'d into a fresh module auto-named under
`GraphWeaver::TypeHelpers` so generated files can reference it:

```ruby
api.register_type("Pet") do
  def display_name = "#{name} 🐶"
end
```

Same runtime behavior, one caveat: `srb tc` can't see into block-defined
methods, so prefer a named module where static checking matters —
complexity on demand.
