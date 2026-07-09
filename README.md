GraphWeaver
======
![Gem](https://img.shields.io/gem/dt/graph_weaver?style=plastic)
[![codecov](https://codecov.io/gh/dpep/graph_weaver/branch/main/graph/badge.svg)](https://codecov.io/gh/dpep/graph_weaver)

A typed GraphQL client for Ruby, built for federation, extensibility, Sorbet, and testing.

GraphWeaver generates `# typed: strict` Ruby from your queries: nested `T::Struct`s, casting code, and a typed `execute` — so `srb tc` sees the exact shape of every query result, and a typo'd field is a static error, not a runtime surprise.

```graphql
# queries/person.graphql
query($id: ID!) {
  person(id: $id) {
    name
    birthday
    pets { name }
  }
}
```

```ruby
result = PersonQuery.execute(id: "1")

result.person&.name       # => "Daniel" (typed String)
result.person&.birthday   # => Date (custom scalars deserialize)
result.person&.nmae       # => srb tc: Method `nmae` does not exist
```

####  Features

- **Queries and mutations** with typed variable kwargs — required vs optional falls out of nullability and defaults
- **Fragments** (inline, named, interface conditions), **unions and interfaces** (member structs, `__typename` dispatch), **enums** (`T::Enum`), **custom scalars** (pluggable registry)
- **Any schema source**: live schema class, introspection JSON, or SDL — including Apollo Federation supergraph SDL
- **Any transport**: in-process schema execution (perfect for tests), the zero-dependency HTTP executor, or Faraday with your own middleware — swap per call with `executor:`
- **Dynamic mode** for development: `GraphWeaver::Codegen.load(...)` generates and evals on the fly, no build step

####  Usage

```ruby
require "graph_weaver"

# configure the default transport once (override per module or per call)
GraphWeaver.executor = GraphWeaver::HttpExecutor.new("https://api.example.com/graphql")

# generate from any schema source
schema = GraphWeaver::SchemaLoader.load("schema.json")   # or .graphql SDL, or a live class

source = GraphWeaver::Codegen.generate(
  schema:,
  query: File.read("queries/person.graphql"),
  module_name: "PersonQuery",
)
File.write("app/queries/person_query.rb", source)

# at runtime
PersonQuery.execute(id: "1")                        # uses GraphWeaver.executor
PersonQuery.execute(id: "1", executor: other)       # or per call
```

Module names derive from the operation name (`query GetPerson` →
`GetPerson`) or, for `GraphWeaver.parse` on a `.graphql` file, from the
file name; pass `module_name:`/`name:` to override. Pass `executor:` (a
constant) to bake a default transport into the generated module.

Prefer Faraday? It's opt-in (`gem "faraday"` in your Gemfile):

```ruby
require "graph_weaver/faraday_executor"

# from a url, with optional middleware customization
executor = GraphWeaver::FaradayExecutor.new("https://api.example.com/graphql") do |conn|
  conn.request :authorization, "Bearer", -> { Tokens.fetch }
  conn.response :logger
end

# or bring a fully configured Faraday connection
executor = GraphWeaver::FaradayExecutor.new(MyApp.faraday_connection)
```

In development, skip the build step entirely:

```ruby
# parse a query into a typed module on the fly — a .graphql path or a raw string
PersonQuery = GraphWeaver.parse(schema:, query: "queries/person.graphql")
PeopleQuery = GraphWeaver.parse(schema:, query: "query { people { name } }")
PersonQuery.execute(id: "1")

# or one-shot, no module at all
GraphWeaver.execute(schema:, query: "query($id: ID!) { person(id: $id) { name } }", variables: { id: "1" })
```

#### Custom scalars

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

----
## Installation

```ruby
# Gemfile
gem "graph_weaver"
```

or

```
gem install graph_weaver
```

----
## Development

`make check` — regenerate spec fixtures, run specs, typecheck.

See `PLAN.md` for roadmap and `NOTES.md` for the research notebook this
gem grew out of (an exploration of graphql-client internals — GraphWeaver
is a standalone client, not an extension; it depends only on `graphql`
and `sorbet-runtime`).
