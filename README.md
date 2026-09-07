GraphWeaver
======
![Gem](https://img.shields.io/gem/dt/graph_weaver?style=plastic)
[![codecov](https://codecov.io/gh/dpep/graph_weaver/branch/main/graph/badge.svg)](https://codecov.io/gh/dpep/graph_weaver)

A typed GraphQL client for Ruby: per-query Sorbet types, schema-correct fakes for your specs, and rake tasks for the whole schema lifecycle. Federation included.

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

Typed structs are the part every generator gets right. What decides whether
you're still happy six months in:

**You can test them.** Generation makes result types *precise*, which makes
them expensive to construct by hand — and most generators stop there, leaving
you to write the fixtures. GraphWeaver ships the fabricator: schema-correct
fakes seeded from your own schema (`rspec --seed` reproduces the data),
field-level failure simulation (`fail_at:`, `corrupt:`, `Failure` + `Sequence`),
record/replay cassettes with anonymization, and rspec integration you turn on
in one line. See [testing](docs/testing.md).

**The schema keeps itself honest.** `cache: true` commits the dump;
`rake graph_weaver:schema:refresh` re-introspects it, `schema:diff` fails when
the server has drifted, and `queries:check` names the queries that drift broke,
with the line and column of each error. `rake graph_weaver:verify` fails when
the committed Ruby is stale. That's the whole schema lifecycle as rake tasks
rather than a CI pipeline you assemble yourself — see
[getting started](docs/getting_started.md#5-verify-in-ci).

Generation is **deterministic**: the same schema and queries produce
byte-identical files, on any machine, in any order — sorted throughout and
enforced by a spec. Regenerating never shows a diff you didn't earn.

New here? In Rails it's one command —
`rails g graph_weaver:install https://api.example.com/graphql` writes
the initializer, the `app/graphql` layout, the editor config and the schema
dump. The **[getting started](docs/getting_started.md)** guide walks the
production setup end to end — codegen, fakes, CI. Or run the
**[examples](examples/)**, smallest first: a public API in 30 lines, a
paginated search, the production path against GitHub, and a whole federated
graph in-process (the one that needs no network).

#### Features

- **Queries and mutations** with typed variable kwargs — enums as `T::Enum`s, input objects as `T::Struct`s, required vs optional falling out of nullability and defaults
- **Fragments** (inline, named, type conditions), **unions and interfaces** (member structs, `__typename` dispatch), **custom scalars** (pluggable registry), `@skip`/`@include` nullability
- **Any schema source**: live schema class, introspection JSON, or SDL — including Apollo Federation supergraph SDL; introspect live endpoints with caching
- **Schema lifecycle as rake tasks**: `schema:refresh`, `schema:diff`, `queries:check`, `verify` — above
- **Rails install generator**: `rails g graph_weaver:install <url|schema class|dump>` scaffolds the initializer, the `app/graphql` layout, `graphql.config.yml` (editor autocomplete) and the schema dump
- **Any transport**: in-process schema execution, the zero-dependency HTTP transport, or Faraday with your own middleware — plus a composable `Retry` (exponential/linear/custom backoff, jitter, retry-by-error-class or GraphQL code) — swap per call with `execute(client: ...)`
- **Structured errors**: a typed response envelope (partial data + extensions survive), an error hierarchy split by failure site, field-level reports with entity ids, and `schema_stale?` detection — every error dual-surfaced as a human message plus JSON-ready `#to_h`
- **Testing built in**: fakes, failure simulation, cassettes, rspec integration — above
- **Type helpers**: mix your own methods onto a generated struct (`extend_type`), or project a nested field onto a typed flat accessor (`alias:`)
- **Dynamic mode** for development: `GraphWeaver.parse(...)` generates and evals on the fly, no build step

#### Usage

Three ways to run a query — pick by context:

| Context | Use |
|---------|-----|
| Production | checked-in codegen (`rake graph_weaver:generate`) — reviewed, `srb tc`-checked |
| Development, consoles | `client.parse` / `client.load_queries!` — no build step |
| Scripts, one-offs | `client.run!` — no module at all |

The production path assembled is the [getting started](docs/getting_started.md);
the pieces:

```ruby
require "graph_weaver"

# a client for one server: transport, auth, and a lazily introspected
# schema. The first argument is a url or any schema
# source — a live schema class, or a .json/.graphql dump
api = GraphWeaver.new("https://api.example.com/graphql", auth: ENV["API_TOKEN"], cache: true)

# make it the app default — generated modules execute through it
GraphWeaver.client = api

# write the checked-in typed modules: app/graphql/queries -> app/graphql/generated
GraphWeaver.generate!   # what `rake graph_weaver:generate` calls

# at runtime
PersonQuery.execute(id: "1")                        # via GraphWeaver.client
PersonQuery.execute(client: other, id: "1")         # or per call
```

Module names derive from the **file** name plus the operation it defines —
`person.graphql` → `PersonQuery`, `adopt.graphql` (a `mutation`) →
`AdoptMutation` — for `parse(path)`, `load_queries!` and the rake task alike.
Full rules, plus `client:` to bake a default client into a module, in
[generated modules](docs/generated_modules.md#generating).

In development, skip the build step entirely — a module from `client.parse`
runs on the client that parsed it, no global wiring needed:

```ruby
# parse a query into a typed module on the fly — a .graphql path or a raw string
PersonQuery = api.parse("queries/person.graphql")
PersonQuery.execute(id: "1")

# or every query file at once (queries_paths convention), named like generation would
api.load_queries!

# or one-shot, no module at all — variables are plain kwargs
api.run!("query($id: ID!) { person(id: $id) { name } }", id: "1")
```


#### Dig deeper

- **[Getting started](docs/getting_started.md)** — the production path in Rails,
  step by step: the install generator, rake tasks, fakes, CI, Sorbet or not
- **[Editor support](docs/editors.md)** — five lines of YAML give VS Code and
  RubyMine schema autocomplete and validation in your `.graphql` files, with no
  JS project
- **[Generated modules](docs/generated_modules.md)** — module anatomy, typed
  variables (enums, input objects), fragments/unions/interfaces,
  `@skip`/`@include`, naming, type helpers, clients, dynamic mode
- **[Against a real API](docs/real_world.md)** — the exploratory tour:
  introspect a live endpoint (GitHub end to end), dynamic mode, schema caching
- **[Federation](docs/federation.md)** — Apollo Federation: supergraph vs API
  schema, feeding weaver a composed graph, the `@inaccessible` caveat, and the
  local in-process router your specs run against
- **[Transports](docs/transports.md)** — clients, the execute contract,
  Faraday, retries and backoff
- **[Custom scalars](docs/scalars.md)** — the registry: codec inference,
  requires, input coercion
- **[Errors](docs/errors.md)** — the Response envelope, the error hierarchy,
  field-level reports with entity ids, stale-schema detection
- **[Logging](docs/logging.md)** — point `GraphWeaver.logger` at any Logger:
  wire traffic at debug, introspection/cache/codegen at info, errors at warn
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
- `make integration` — one-off checks against live APIs (GitHub needs a token) and a federation gateway (needs node)
