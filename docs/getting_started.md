# Getting started: the production path (Rails)

The setup that ships: queries live as `.graphql` files, generation writes
`# typed: strict` Ruby you check in, and CI fails when anything drifts.
In Rails one generator does the setup. (Exploring an API from a console
instead? Start with [dynamic mode](real_world.md) — no build step.)

Rails is assumed below; the [non-Rails note](#not-rails) at the bottom
covers the differences.

## 1. Install

```ruby
# Gemfile
gem "graph_weaver"
```

## 2. Run the generator

```sh
rails g graph_weaver:install https://api.example.com/graphql
```

```
      create  config/initializers/graph_weaver.rb
      create  app/graphql/queries/.keep
      create  app/graphql/generated/.keep
      create  graphql.config.yml
  introspect  app/graphql/schema.json from https://api.example.com/graphql
```

The argument is whatever you'd pass to `GraphWeaver.new` — the generator
takes the same three source forms the library does, and writes the
initializer that fits:

| source | |
|---|---|
| `https://api.example.com/graphql` | an endpoint: introspected now, and the dump committed |
| `MyApp::Schema` | your own graphql-ruby schema, executing [in-process](#your-apps-own-schema-in-process) |
| `db/schema.graphql` | a [dump you already have](#a-schema-dump-you-already-have) — pointed at, not copied |

| flag | |
|---|---|
| `--auth` | name of the ENV var holding the auth token — default `GRAPHWEAVER_AUTH`. Url only. Name a different one and the initializer follows, but `schema:refresh`/`schema:diff` still read `GRAPHWEAVER_AUTH` — set both |
| `--no-schema` | skip writing the dump; `rake graph_weaver:schema:refresh URL=...` does it later |

Re-running is safe — every file goes through the usual Rails conflict
prompt, so an initializer you've edited is never overwritten silently.

What it wrote:

- **`config/initializers/graph_weaver.rb`.** `GraphWeaver.client =` is the
  load-bearing line: generated modules without a baked transport resolve to
  it at execute time (the full
  [resolution order](transports.md#client-resolution)). Custom
  scalars/enums/type helpers register here too — the rake tasks bake them
  into generated source, so they have to run first:

  ```ruby
  GraphWeaver.register_scalar("DateTime", Time, serialize: :iso8601, requires: "time")
  ```

  Initializers run before autoloading is set up, so a constant a
  registration *names* — a `T::Enum` for `register_enum`, a mixin module for
  `extend_type` — can't be autoloaded from `app/` here (you get
  `uninitialized constant PetKind`). Keep it out of the autoload paths and
  require it, or build a mixin inline with a block, which needs no constant
  at all:

  ```ruby
  # config.autoload_lib(ignore: %w[assets tasks graph_weaver])
  require Rails.root.join("lib/graph_weaver/pet_kind")
  GraphWeaver.register_enum("Species", PetKind, requires: "graph_weaver/pet_kind")

  GraphWeaver.extend_type("Pet") { def adopted? = !adopted_at.nil? }
  ```

- **`app/graphql/schema.json`.** The schema dump codegen reads
  (`GraphWeaver.schema_path`) — never written by hand, always committed.
  `cache: true` in the initializer reuses it; delete the file to
  re-introspect. Prefer PR-reviewable diffs? `cache: :graphql` writes SDL
  instead; both generate identical code. (`cache:`/`ttl:` apply only to url
  clients — a schema source never introspects, so passing them raises.)
- **`graphql.config.yml`.** Five lines of YAML that give VS Code and
  RubyMine schema autocomplete, hover docs, and validation as you type in
  `.graphql` files — no JS project, no `npm install`. Details and the honest
  limits in [editors](editors.md).
- **`app/graphql/queries/`, `app/graphql/generated/`.** Where you write
  queries and where generation writes Ruby.

Rake needs no wiring either: in Rails the `graph_weaver:*` tasks register
themselves (a Railtie) and depend on `:environment`, so your initializer —
and its registrations — runs first. The generated modules load at boot the
same way, after `config/initializers`.

### Your app's own schema, in-process

An app that *serves* GraphQL with graphql-ruby can have the same typed
access to its own API — same generated structs, no socket, no HTTP:

```sh
rails g graph_weaver:install MyApp::Schema
```

```ruby
# config/initializers/graph_weaver.rb
Rails.application.config.to_prepare do
  # queries run in-process against the app's own schema — no socket
  GraphWeaver.client = GraphWeaver.new(MyApp::Schema)
end
```

`to_prepare`, not a bare assignment: the schema class is autoloaded, so it
isn't resolvable while initializers run, and a dev reload replaces it with
a new class object that a captured one would go stale against.

**Context is per request, not per app.** A resolver reading
`context[:current_user]` gets nil from the app default — build a client
where you know the request and pass it per call:

```ruby
client = GraphWeaver.new(MyApp::Schema, context: { current_user: })
PetQuery.execute!(client:, id: "1").pet.owner   # => the context's user
```

**Keep the dump in step with the schema.** Codegen reads the committed
dump at `GraphWeaver.schema_path`, never the live class — that's what
makes `rake graph_weaver:verify` a deterministic CI check. The generator
writes the first dump; after that it's an artifact derived from code in
your own repo, so rebuild it with graphql-ruby's own rake task:

```ruby
# lib/tasks/graphql.rake
require "graphql/rake_task"
GraphQL::RakeTask.new(schema_name: "MyApp::Schema", directory: "app/graphql",
  dependencies: [:environment])
```

```sh
rake graphql:schema:json     # rewrites app/graphql/schema.json
rake graph_weaver:generate
```

Run the dump step ahead of `rake graph_weaver:verify` in CI — that check
compares committed Ruby against the committed dump, so a stale dump makes
it fail on a query that is fine. `rake graph_weaver:queries:check` is
unaffected: when `GraphWeaver.client` runs in-process it validates
against the live class, not the dump. (`graph_weaver:schema:diff` and
`:refresh` are for servers you *don't* own; a dump taken from a schema
class records no url, and they say so.)

### A schema dump you already have

```sh
rails g graph_weaver:install db/schema.graphql
```

Sets `GraphWeaver.schema_path` to that file rather than writing a second
copy, and introspects nothing. A dump has no resolvers, so it can't
execute — set `GraphWeaver.client` to whatever serves the API.

## 3. Write a query, generate, commit

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

### Autocomplete while you write the query

`graphql.config.yml` is already there, so VS Code and RubyMine validate the
`.graphql` files as you type, with schema autocomplete and hover docs — see
[editors](editors.md).

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
hoisted once into the shared `GraphQLTypes` module and every query that spreads
it aliases the same type — so a `union` selected across many queries becomes one
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

There's no flag: hoisting triggers when the union field's selection is exactly
that one spread. Mix in other fields, or shadow the fragment with a query-local
one of the same name, and the union stays inlined in that query — see
[abstract types](generated_modules.md#abstract-types).

## 4. Test against fakes

```ruby
# spec/support/graph_weaver.rb
require "graph_weaver/rspec"
```

```ruby
it "renders the empty state", graphql: :fake do … end   # or tag the describe
```

A fresh `rails g rspec:install` leaves the `spec/support` glob commented
out in `spec/rails_helper.rb`, so uncomment it — or put the require in
`rails_helper.rb` itself. Nothing warns you that a support file went
unread.

The tag installs a seeded, schema-correct `FakeClient` for that example —
no server, no stubs, and `rspec --seed 1234` reproduces the fake data along
with test order. The schema it fabricates from is derived (the committed
dump, or your client's), so there's nothing to configure. Tag
`graphql: :in_process` instead and the same example runs against your real
resolvers; pin values with `overrides:`, simulate failures with `Failure.*`
— see [testing](testing.md).

## 5. Verify in CI

```sh
rake graph_weaver:verify         # generated code fresh? fails on any drift
rake graph_weaver:schema:diff    # server drifted? re-introspects and compares
rake graph_weaver:queries:check  # did that drift break any of your queries?
```

Three different questions — four on a federated graph, where
`rake graph_weaver:federation:diff` asks whether anyone changed a subgraph
without recomposing the supergraph you committed. It needs no network
either, so it belongs in the same PR run; see
[federation](federation.md#has-the-supergraph-been-recomposed).

`graph_weaver:verify` compares the committed generated files against what the
current schema + queries + registrations would produce. No network — run it in
every CI build.

`graph_weaver:schema:diff` asks whether the *server* has moved since the
dump was taken. It needs network, a dump with a recorded source url
(introspected dumps have one), and `GRAPHWEAVER_AUTH` for private APIs;
run it on a schedule and refresh with `rake graph_weaver:schema:refresh`.

`graph_weaver:queries:check` answers the question that actually matters
when it *has* moved: **which of your queries no longer validate, and
why.** It re-introspects the recorded url (without rewriting the dump) and
validates every `.graphql` file against the schema as it is right now,
naming each error's line and column:

```
app/graphql/queries/person.graphql
  4:5  Field 'nmae' doesn't exist on type 'Person' (Did you mean `name`?)

1 invalid query
```

It exits non-zero when anything fails, so it drops straight into CI or a
scheduled job.

The Ruby behind it returns the same thing as data, so you can wire it into
whatever you already have (a spec, a Slack ping, an issue):

```ruby
GraphWeaver.check_queries
# => { "app/graphql/queries/person.graphql" =>
#      [{ "message" => "Field 'nmae' doesn't exist on type 'Person' (Did you mean `name`?)",
#         "line" => 4, "column" => 5 }] }
```

Empty means everything validates. Pass `schema:` a loaded schema and nothing
touches the network — handy for checking a *proposed* schema (a subgraph about
to ship) before it's live:

```ruby
GraphWeaver.check_queries(schema: GraphWeaver::SchemaLoader.load("proposed.graphql"))
```

It wants the loaded schema, not the path. Left off, it re-introspects the url
the dump records — and when that dump is a composed supergraph, each error also
names the subgraphs behind the type it points at
([federation](federation.md#the-routing-table)).

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

There's no generator, but what it writes is short — a few lines wherever
your app boots, two directories, and the schema dump:

```ruby
GraphWeaver.client = GraphWeaver.new(
  "https://api.example.com/graphql",
  auth: ENV["GRAPHWEAVER_AUTH"],
  cache: true,
)
GraphWeaver.load_generated!   # no Railtie to require the generated files
```

```sh
mkdir -p app/graphql/queries app/graphql/generated
rake graph_weaver:schema:refresh URL=https://api.example.com/graphql
```

Add `require "graph_weaver/tasks"` to your Rakefile for the rake tasks —
and, since there's no `:environment` hook to run your registrations,
require the file that does them from the Rakefile too. `graphql.config.yml`
is copy/paste from [editors](editors.md).
