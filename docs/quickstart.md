# Quickstart: the production path (Rails)

The setup that ships: queries live as `.graphql` files, generation writes
`# typed: strict` Ruby you check in, and CI fails when anything drifts.
Mostly copy/paste. (Exploring an API from a console instead? Start with
[dynamic mode](real_world.md) — no build step.)

Rails is assumed below; the [non-Rails note](#not-rails) at the bottom
covers the one difference.

## 1. Install

```ruby
# Gemfile
gem "graph_weaver"
```

## 2. Bootstrap the schema dump

Codegen reads a schema dump at `app/graphql/schema.json`
(`GraphWeaver.schema_path`). You never write this file by hand —
`cache: true` writes it on first introspection. Bootstrap once from a
console:

```ruby
GraphWeaver.new("https://api.example.com/graphql", auth: ENV["API_TOKEN"], cache: true).schema
```

Skip this step and the generate task tells you exactly that — the error
message is the documentation. Prefer PR-reviewable diffs? `cache: :graphql`
writes SDL instead of introspection JSON; both generate identical code.

Note `cache:`/`ttl:` apply only to url clients — a schema source (a live
class or a dump) never introspects, so passing them raises.

## 3. Wire the client

```ruby
# config/initializers/graph_weaver.rb
GraphWeaver.client = GraphWeaver.new(
  "https://api.example.com/graphql",
  auth: ENV["API_TOKEN"],
  cache: true,   # reuses the committed dump; delete the file to re-introspect
)

# custom scalars/enums/type helpers — register globally, so the rake
# tasks bake them into generated source
GraphWeaver.register_scalar("DateTime", Time, serialize: :iso8601, requires: "time")

# require every generated module (explicit, factory_bot-style)
GraphWeaver.load_generated!
```

`GraphWeaver.client =` is the load-bearing line: generated modules
without a baked transport resolve to it at execute time (the full
[resolution order](transports.md#executor-resolution)).

## 4. Add the rake tasks

```ruby
# Rakefile
require "graph_weaver/tasks"
```

In Rails the tasks depend on `:environment`, so your initializer — and
its registrations, which are baked into generated source — runs first.

## 5. Write a query, generate, commit

```graphql
# app/graphql/queries/person.graphql
query($id: ID!) {
  person(id: $id) {
    name
    birthday
  }
}
```

```sh
rake graph_weaver:generate   # writes app/graphql/generated/person_query.rb
```

Commit the schema dump and the generated files. Generated code is
reviewed like any other code — and never edited by hand.

```ruby
PersonQuery.execute!(id: "1").person&.name   # typed, via GraphWeaver.client
```

## 6. Test against fakes

```ruby
# spec/support/graph_weaver.rb
require "graph_weaver/rspec"

GraphWeaver::Testing.configure do |config|
  config.schema = GraphWeaver::SchemaLoader.locate   # the committed dump
  config.auto_fake = true   # every example runs against a schema-correct fake
end
```

Every query now executes against a seeded `FakeExecutor` — no server, no
stubs, and `rspec --seed 1234` reproduces the fake data. Pin values with
`overrides:`, simulate failures with `Failure.*` — see
[testing](testing.md).

## 7. Verify in CI

```sh
rake graph_weaver:verify          # generated code fresh? fails on any drift
rake graph_weaver:schema:verify   # server drifted? re-introspects and compares
```

Two different questions. `graph_weaver:verify` checks that the committed
generated files match what the current schema + queries + registrations
would produce — run it in every CI build. `graph_weaver:schema:verify`
asks whether the *server* has moved since the dump was taken — it needs
network, a dump with a recorded source url (introspected dumps have one),
and `GRAPHWEAVER_AUTH` for private APIs; run it on a schedule and refresh
with `rake graph_weaver:schema:refresh`.

## Sorbet, with or without

`sorbet-runtime` is a hard dependency, so generated `T::Struct`s and sigs
enforce at runtime in every app — no Sorbet setup required on your end.
The *static* layer (`srb tc` flagging a typo'd field before anything
runs) applies only when your app runs Sorbet, and only to checked-in
generated files — dynamic `parse` is invisible to `srb tc`. Everything
works without Sorbet; codegen plus Sorbet is what moves type errors from
runtime to CI.

## Not Rails?

Everything above works the same, minus the `:environment` hook: the rake
tasks can't run your registrations for you, so require the file that does
them from your Rakefile alongside `graph_weaver/tasks`. And
`GraphWeaver.load_generated!` goes wherever your app boots instead of an
initializer.
