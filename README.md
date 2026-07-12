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
result = PersonQuery.execute!(id: "1")   # typed result, or raises on errors (execute returns an envelope)

result.person&.name       # => "Daniel" (typed String)
result.person&.birthday   # => Date (custom scalars deserialize)
result.person&.nmae       # => srb tc: Method `nmae` does not exist
```

New here? The **[getting started](docs/getting_started.md)** guide walks the
production setup end to end — initializer, codegen, fakes, CI. Or run the
**[examples](examples/)**: `ruby examples/countries.rb` (public API, no auth,
all dynamic) and `ruby examples/github/run.rb` (auth + checked-in generated
modules; it stars this repo ⭐ and introduces you to your fellow stargazers).

#### Features

- **Queries and mutations** with typed variable kwargs — enums as `T::Enum`s, input objects as `T::Struct`s, required vs optional falling out of nullability and defaults
- **Fragments** (inline, named, type conditions), **unions and interfaces** (member structs, `__typename` dispatch), **custom scalars** (pluggable registry), `@skip`/`@include` nullability
- **Any schema source**: live schema class, introspection JSON, or SDL — including Apollo Federation supergraph SDL; introspect live endpoints with caching
- **Any transport**: in-process schema execution, the zero-dependency HTTP executor, or Faraday with your own middleware — plus a composable `RetryExecutor` (exponential/linear/custom backoff, jitter, retry-by-error-class or GraphQL code) — swap per call with `executor:`
- **Structured errors**: a typed response envelope (partial data + extensions survive), an error hierarchy split by failure site, field-level reports with entity ids, and `schema_stale?` detection — every error dual-surfaced as a human message plus JSON-ready `#to_h`
- **Testing built in**: schema-correct fakes, failure simulation, record/replay cassettes with anonymization, rspec integration
- **Dynamic mode** for development: `GraphWeaver.parse(...)` generates and evals on the fly, no build step

#### Usage

Three ways to run a query — pick by context:

| Context | Use |
|---------|-----|
| Production | checked-in codegen (`rake graph_weaver:generate`) — reviewed, `srb tc`-checked |
| Development, consoles | `client.parse` / `client.load_queries!` — no build step |
| Scripts, one-offs | `client.execute!` — no module at all |

The production path assembled is the [getting started](docs/getting_started.md);
the pieces:

```ruby
require "graph_weaver"

# a client for one server: transport (Faraday when loaded), auth, and a
# lazily introspected schema. The first argument is a url or any schema
# source — a live schema class, or a .json/.graphql dump
api = GraphWeaver.new("https://api.example.com/graphql", auth: ENV["API_TOKEN"], cache: true)

# make it the app default — generated modules execute through it
GraphWeaver.client = api

# generate checked-in typed modules (rake graph_weaver:generate, or directly)
source = GraphWeaver::Codegen.generate(
  schema: api.schema,
  query: File.read("queries/person.graphql"),
  module_name: "PersonQuery",
)
File.write("app/queries/person_query.rb", source)

# at runtime
PersonQuery.execute(id: "1")                        # via GraphWeaver.client
PersonQuery.execute(id: "1", executor: other)       # or per call
```

Module names derive from the operation name (`query GetPerson` →
`GetPerson`) or, for `parse` on a `.graphql` file, from the file name;
pass `module_name:`/`name:` to override. Pass `executor:` (a constant) to
bake a default transport into the generated module. Prefer Faraday? It's
opt-in (`gem "faraday"`), and the client picks it up when loaded —
middleware blocks and ready connections in [transports](docs/transports.md).

In development, skip the build step entirely — modules from `client.parse`
carry the client's transport, no global wiring needed:

```ruby
# parse a query into a typed module on the fly — a .graphql path or a raw string
PersonQuery = api.parse("queries/person.graphql")
PersonQuery.execute(id: "1")

# or every query file at once (queries_path convention), named like generation would
api.load_queries!

# or one-shot, no module at all — variables are plain kwargs
api.execute!("query($id: ID!) { person(id: $id) { name } }", id: "1")
```


#### Dig deeper

- **[Getting started](docs/getting_started.md)** — the production path in Rails,
  step by step: initializer, rake tasks, fakes, CI, Sorbet or not
- **[Generated modules](docs/generated_modules.md)** — module anatomy, typed
  variables (enums, input objects), fragments/unions/interfaces,
  `@skip`/`@include`, naming, executors, dynamic mode
- **[Against a real API](docs/real_world.md)** — the exploratory tour:
  introspect a live endpoint (GitHub end to end), dynamic mode, schema caching
- **[Transports](docs/transports.md)** — clients, the executor contract,
  Faraday, retries and backoff
- **[Custom scalars](docs/scalars.md)** — the registry: codec inference,
  requires, input coercion
- **[Errors](docs/errors.md)** — the Response envelope, the error hierarchy,
  field-level reports with entity ids, stale-schema detection
- **[Testing](docs/testing.md)** — schema-correct fakes, failure simulation,
  rspec integration
- **[Cassettes](docs/cassettes.md)** — capture and replay real API
  responses; anonymized recording (`GRAPHWEAVER_RECORD=1`, rake tasks)

----
## Installation

```ruby
# Gemfile
gem "graph_weaver"
```

or

```sh
gem install graph_weaver
```

----
## Development

- `make check` — regenerate spec fixtures, run specs, typecheck
- `make integration` — one-off checks against the live GitHub and Countries APIs
