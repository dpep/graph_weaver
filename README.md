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
- **Any transport**: in-process schema execution (perfect for tests) or HTTP via the bundled executor — swap per call with `executor:`
- **Dynamic mode** for development: `GraphWeaver::Codegen.load(...)` generates and evals on the fly, no build step

####  Usage

```ruby
require "graph_weaver"

# generate from any schema source
schema = GraphWeaver::SchemaLoader.load("schema.json")   # or .graphql SDL, or a live class

source = GraphWeaver::Codegen.new(
  schema:,
  executor_const: "MyApi::Executor",
  query: File.read("queries/person.graphql"),
  module_name: "PersonQuery",
).generate

File.write("app/queries/person_query.rb", source)

# at runtime
executor = GraphWeaver::HttpExecutor.new("https://api.example.com/graphql")
PersonQuery.execute(id: "1", executor:)
```

In development, skip the build step:

```ruby
PersonQuery = GraphWeaver::Codegen.load(schema:, executor_const: "...", query:, module_name: "PersonQuery")
```

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
