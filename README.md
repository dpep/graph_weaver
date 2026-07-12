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

#### Features

- **Queries and mutations** with typed variable kwargs — enums as `T::Enum`s, input objects as `T::Struct`s, required vs optional falling out of nullability and defaults
- **Fragments** (inline, named, type conditions), **unions and interfaces** (member structs, `__typename` dispatch), **custom scalars** (pluggable registry), `@skip`/`@include` nullability
- **Any schema source**: live schema class, introspection JSON, or SDL — including Apollo Federation supergraph SDL; introspect live endpoints with caching
- **Any transport**: in-process schema execution, the zero-dependency HTTP executor, or Faraday with your own middleware — plus a composable `RetryExecutor` (exponential/linear/custom backoff, jitter, retry-by-error-class or GraphQL code) — swap per call with `executor:`
- **Structured errors**: a typed response envelope (partial data + extensions survive), an error hierarchy split by failure site, field-level reports with entity ids, and `schema_stale?` detection — every error dual-surfaced as a human message plus JSON-ready `#to_h`
- **Testing built in**: schema-correct fakes, failure simulation, record/replay cassettes with anonymization, rspec integration
- **Dynamic mode** for development: `GraphWeaver.parse(...)` generates and evals on the fly, no build step

#### Usage

```ruby
require "graph_weaver"

# a client for one server: transport (Faraday when loaded), auth, and a
# lazily introspected schema. The first argument is a url or any schema
# source — a live schema class, or a .json/.graphql dump
api = GraphWeaver.new("https://api.example.com/graphql", auth: ENV["API_TOKEN"], cache: true)

# generate checked-in typed modules
source = GraphWeaver::Codegen.generate(
  schema: api.schema,
  query: File.read("queries/person.graphql"),
  module_name: "PersonQuery",
)
File.write("app/queries/person_query.rb", source)

# at runtime
PersonQuery.execute(id: "1")                        # uses GraphWeaver.executor
PersonQuery.execute(id: "1", executor: other)       # or per call
```

Module names derive from the operation name (`query GetPerson` →
`GetPerson`) or, for `parse` on a `.graphql` file, from the file name;
pass `module_name:`/`name:` to override. Pass `executor:` (a constant) to
bake a default transport into the generated module.

Prefer Faraday? It's opt-in (`gem "faraday"` in your Gemfile):

```ruby
require "graph_weaver/transport/faraday"

# from a url, with optional middleware customization
executor = GraphWeaver::Transport::Faraday.new("https://api.example.com/graphql") do |conn|
  conn.request :authorization, "Bearer", -> { Tokens.fetch }
  conn.response :logger
end

# or bring a fully configured Faraday connection
executor = GraphWeaver::Transport::Faraday.new(MyApp.faraday_connection)
```

In development, skip the build step entirely:

```ruby
# parse a query into a typed module on the fly — a .graphql path or a raw string
PersonQuery = api.parse("queries/person.graphql")
PeopleQuery = api.parse("query { people { name } }")
PersonQuery.execute(id: "1")

# or one-shot, no module at all
api.execute!("query($id: ID!) { person(id: $id) { name } }", variables: { id: "1" })
```


#### Dig deeper

- **[Generated modules](docs/generated_modules.md)** — module anatomy, typed
  variables (enums, input objects), fragments/unions/interfaces,
  `@skip`/`@include`, naming, executors, dynamic mode
- **[Against a real API](docs/real_world.md)** — introspect a live endpoint
  (GitHub end to end), schema caching
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
