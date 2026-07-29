# Getting started: the production path (Rails)

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
```

`GraphWeaver.client =` is the load-bearing line: generated modules
without a baked transport resolve to it at execute time (the full
[resolution order](transports.md#client-resolution)). The generated
modules themselves load at boot automatically (the Railtie requires
everything under `generated_path`, after your initializers run) —
outside Rails, call `GraphWeaver.load_generated!` wherever your app
boots.

## 4. Rake tasks — nothing to do

In Rails the `graph_weaver:*` tasks register themselves (a Railtie), and
they depend on `:environment`, so your initializer — and its
registrations, which are baked into generated source — runs first.
Outside Rails, add `require "graph_weaver/tasks"` to your Rakefile.

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

### Shared fragments

Define reusable fragments once and spread them from any query:

```graphql
# app/graphql/fragments/person_fields.graphql
fragment PersonFields on Person { name birthday }

# app/graphql/queries/person.graphql
query($id: ID!) { person(id: $id) { ...PersonFields } }
```

Each query inlines only the fragments it (transitively) spreads, so the sent
`QUERY` stays self-contained — the server never needs your fragment library.
Fragment files hold only fragments (no operations), and names are unique across
them. Point elsewhere with `GraphWeaver.fragments_paths` (an appendable list,
default `app/graphql/fragments`).

### Shared unions

When a shared fragment *is* the whole selection on a union field, its type is
hoisted once into a `GraphQLUnions` module and every query that spreads it
aliases the same type — so a `union` selected across many queries becomes one
Ruby type family, and you write one exhaustive `case … when … T.absurd` that
works everywhere:

```graphql
# app/graphql/fragments/feed_item.graphql
fragment FeedItemFields on FeedItem {
  __typename
  ... on Post { title }
  ... on Photo { url }
}

# any query
query { feed { ...FeedItemFields } }   # feed : T::Array[FeedItemFields::Type]
```

Hoisting is what the shared fragment buys you — there's no flag. It triggers
only when the union field's selection is exactly that one spread (mix in other
fields, or shadow the fragment with a query-local one of the same name, and the
union stays inlined in that query). Named like the inputs module from the output
path (`GraphQLUnions`, or `GithubUnions` in a multi-schema layout); override
with `GraphWeaver.unions_module=`.

## 6. Test against fakes

```ruby
# spec/support/graph_weaver.rb
require "graph_weaver/rspec"

GraphWeaver::Testing.configure { |config| config.auto_fake = true }
```

The opt-in is deliberate (no surprise fakes); once on, the schema
auto-locates from the committed dump and every query in every example
executes against a seeded, schema-correct `FakeClient` — no server, no
stubs, and `rspec --seed 1234` reproduces the fake data along with test
order. Pin values with `overrides:`, simulate failures with `Failure.*`
— see [testing](testing.md).

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

If your app globally injects `T::Sig` (`class Module; include T::Sig`), the
per-struct `extend T::Sig` in generated files is redundant — rubocop's
`Sorbet/RedundantExtendTSig` flags it. GraphWeaver auto-detects that at
generation time and skips the `extend`; override with
`GraphWeaver.extend_t_sig = true`/`false`. (Generated code is machine-generated
and marked "do not edit," so excluding `generated/**` from rubocop is also fine.)

## Not Rails?

Everything above works the same, minus the Railtie conveniences: add
`require "graph_weaver/tasks"` to your Rakefile yourself, and — since
there's no `:environment` hook to run your registrations — require the
file that does them from the Rakefile too. `GraphWeaver.load_generated!`
goes wherever your app boots instead of an initializer.
