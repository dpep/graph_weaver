# Custom scalars

Teach the generator how a GraphQL custom scalar deserializes into a rich
Ruby object (and serializes back when used as a variable). A field typed
`Money` then generates `const :price, T.nilable(Money)` and casts with
`Money.parse(...)` inline — no runtime reflection:

```ruby
GraphWeaver.register_scalar("Money", type: Money, requires: "bigdecimal")
```

Pass a real class as `type:` and the cast/serialize are **inferred** from it by
probing the deserialize side and pairing its serializer:

| the class defines | cast          | serialize      |
|-------------------|---------------|----------------|
| `.parse`          | `Type.parse(v)` | `v.to_s`     |
| `.load`           | `Type.load(v)`  | `Type.dump(v)` |

so the common case needs nothing more. Probing the *deserialize* side is
deliberate — every object has `#to_s`, so inferring off it would wrongly wrap
plain types like `String`/`Integer`; requiring a `.parse`/`.load` the type
actually defines avoids that (and is why the built-ins can be registered with
their real class constants). Override explicitly when you need to:

- a `Symbol` method name, nothing to misspell: `cast: :load` → `Money.load(expr)`,
  `serialize: :to_json` → `expr.to_json`
- a `Proc` for anything a method name can't express: `cast: ->(expr) { "Money.new(#{expr})" }`
- `:itself` to force pass-through, opting out of inference (rare)

`type:` also accepts a plain string (`"BigDecimal"`) when you'd rather not
reference the class. `requires:` (a string or array) names files emitted as
`require`s atop the generated source so the cast/type resolve — when `type:` is
a real class (so the runtime is loaded) each path is actually `require`d at
registration to catch a typo now rather than in the generated file.

Pass `coerce: true` to let a variable of this scalar accept **either** the value
object **or** its raw input, normalizing the latter through the cast:

```ruby
GraphWeaver.register_scalar("Money", type: Money, coerce: true)
# generated execute now takes T.any(Money, String); "12.00" is parsed
StoreQuery.execute(budget: "12.00")          # Money.parse("12.00") under the hood
StoreQuery.execute(budget: Money.new(1200))  # passed straight through
```

Bad input still explodes (the cast raises), so some safety survives; it needs
both a cast and a serialize. Off by default — the strict typed kwarg is the norm.

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
