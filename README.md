GraphWeaver
======
![Gem](https://img.shields.io/gem/dt/graph_weaver?style=plastic)
[![codecov](https://codecov.io/gh/dpep/graph_weaver/branch/main/graph/badge.svg)](https://codecov.io/gh/dpep/graph_weaver)

**Your `.graphql` files, compiled into Sorbet types — and the fakes to test them.**

GraphWeaver is graphql-codegen for Ruby. Write a query as a `.graphql` file and it
generates checked-in `# typed: strict` Ruby — nested `T::Struct`s, casting, a typed
`execute` — so `srb tc` knows the exact shape of every result. The schema can be a
live graphql-ruby class, an introspection dump, SDL, or an Apollo supergraph;
at runtime the only dependencies are `graphql` and `sorbet-runtime`.

```graphql
# app/graphql/queries/person.graphql
query($id: ID!) {
  person(id: $id) {
    id
    name
    birthday
    pets { name }
  }
}
```

`rake graph_weaver:generate` turns that file into a `PersonQuery` module, and what
comes back is a struct rather than a Hash you have to trust:

```ruby
result = PersonQuery.execute!(id: "1")   # or #execute, for the Response envelope

result.person&.name                # => "Daniel"
result.person&.birthday            # => #<Date: 1990-06-15>   custom scalars deserialize
result.person&.pets&.map(&:name)   # => ["Shelby", "Brownie"]

result.person&.nmae
# srb tc: Method `nmae` does not exist on `PersonQuery::Result::Person`
#         Did you mean `name`?
```

`person` is `T.nilable` because the schema says the field is nullable — the `&.`
isn't defensive, it's the schema talking. A field you misspelled, or never
selected, is a typecheck error rather than a `NoMethodError` in production.

## Start here

```ruby
# Gemfile
gem "graph_weaver"
```

In Rails, setup is one command:

```sh
rails g graph_weaver:install https://api.example.com/graphql
```

which writes the initializer, the `app/graphql` layout, the editor config and the
schema dump. **[Getting started](docs/getting_started.md)** walks the production
setup end to end. Or skip the build step and poke at an API from a console —
anything holding a schema parses, and the module runs on what parsed it:

```ruby
api = GraphWeaver.new("https://countries.trevorblades.com/")
CountryQuery = api.parse("queries/country.graphql")   # a path or a raw string
CountryQuery.execute!(code: "JP").country&.capital    # => "Tokyo"

api.run!("query { continents { name } }").continents  # or no module at all
```

The **[examples](examples/)** run that path for real, smallest first: a public API
in 30 lines, a paginated search, the production path against GitHub, and the
federated graph below.

## Precise types are expensive to fake, so it fakes them for you

Generation makes result types exact, which makes them tedious to build by hand —
and most generators stop there and leave you the fixtures. GraphWeaver ships the
fakes. One line in the spec helper:

```ruby
require "graph_weaver/rspec"
```

then one tag says what an example runs against:

```ruby
it "shows the profile", graphql: :fake do
  person = PersonQuery.execute!(id: "1").person

  person.name       # => "Shakita Stark"      fabricated from your schema
  person.birthday   # => #<Date: 2024-12-16>  custom scalars included
  person.pets.size  # => 2
end
```

No fixture, no stub, no HTTP — and the values are seeded from rspec's own seed, so
`--seed 4242` hands back that same person and a failure reproduces.

Random data answers "does this render". When the example is *about* the data, pin
the fields it's about and let the rest stay fabricated:

```ruby
graphql_fake(overrides: { "Person.name" => "Ada", "Person.pets" => [{ "name" => "Shelby" }, {}] })

person.name                 # => "Ada"
person.pets.map(&:name)     # => ["Shelby", "Mrs. Fermin Predovic"]
```

Keys are schema coordinates, checked and spellchecked, so a typo raises instead of
leaving the example green against random data. The tag also picks a *real* client
when you want one: `:in_process` runs your resolvers, `:router` runs them across a
federated graph. Field-level failure simulation and record/replay cassettes with
anonymization are in [testing](docs/testing.md).

## Federation without a gateway

When your app is both a GraphQL client and a subgraph, the local router plans a
query across the composed supergraph and runs your **real resolvers** over the
boundary — no gateway process, no node, no sockets. That's
[`examples/federation.rb`](examples/federation.rb), the example that needs no
network, and this is the trace it prints:

```
fetches:
  → accounts  root fields
  → reviews   _entities × 1 User
  → products  _entities × 2 Product
```

The trace is the query plan: every node at a level goes in one `_entities` call,
so two products cost one fetch. Anything it can't answer *faithfully* it refuses
at plan time rather than guessing — and it's diffed against a real
`@apollo/gateway` over the same supergraph, currently 72 queries identical, 2
refused, 0 wrong
([`spec/integration/router_parity_spec.rb`](spec/integration/router_parity_spec.rb)).
See [federation](docs/federation.md).

## The schema keeps itself honest

The lifecycle is rake tasks, not a CI pipeline you assemble yourself:
`schema:refresh` re-introspects the committed dump, `schema:diff` fails when the
server has drifted, `queries:check` names the queries that drift broke and where,
and `verify` fails when the checked-in Ruby is stale. Generation is deterministic
— same schema and queries, byte-identical files — so regenerating never shows a
diff you didn't earn. See [getting started](docs/getting_started.md#5-verify-in-ci).

**Any release can change what codegen emits**, patch releases included — fixing a
generated type is a byte change. So `rake graph_weaver:generate` is part of every
upgrade, and `verify` is what tells you when you've skipped it.

#### Also in the box

- **Queries and mutations** with typed variable kwargs — enums as `T::Enum`s, input objects as `T::Struct`s, required vs optional falling out of nullability and defaults
- **Fragments** (inline, named, type conditions), **unions and interfaces** (member structs, `__typename` dispatch), `@skip`/`@include` nullability
- **Any transport**: in-process execution, a zero-dependency HTTP client, or Faraday with your own middleware — plus a composable `Retry` with backoff and jitter
- **Structured errors**: a typed envelope that keeps partial data and extensions, an error hierarchy split by failure site, field-level reports with entity ids, and stale-schema detection

#### Dig deeper

- **[Getting started](docs/getting_started.md)** — the production path in Rails, step by step
- **[Generated modules](docs/generated_modules.md)** — module anatomy, typed variables, fragments/unions/interfaces, naming, clients, dynamic mode
- **[Testing](docs/testing.md)** — fakes, failure simulation, the rspec tags
- **[Federation](docs/federation.md)** — supergraph vs API schema, the local router, what it refuses
- **[Transports](docs/transports.md)** — the execute contract, Faraday, retries and backoff
- **[Errors](docs/errors.md)** — the Response envelope, the error hierarchy, field-level reports
- **[Custom scalars](docs/scalars.md)** — the registry: codec inference, requires, input coercion
- **[Cassettes](docs/cassettes.md)** — capture and replay real responses, anonymized
- **[Editor support](docs/editors.md)** — five lines of YAML for schema autocomplete in `.graphql` files, no JS project
- **[Against a real API](docs/real_world.md)** — introspecting a live endpoint, GitHub end to end
- **[Logging](docs/logging.md)** — point `GraphWeaver.logger` at any Logger

----
## Development

- `make check` — regenerate spec fixtures, run specs, typecheck
- `make integration` — one-off checks against live APIs (GitHub needs a token) and a federation gateway (needs node)
