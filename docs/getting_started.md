# Getting started: the production path (Rails)

The setup that ships, end to end: queries live as `.graphql` files, generation
writes `# typed: strict` Ruby you check in, and CI fails when anything drifts.
Follow it once when you add the gem to an app. (Exploring an API from a console
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
| `--auth` | name of the ENV var holding the auth token — default `GRAPHWEAVER_AUTH`. Url only. The name is recorded into the dump, so `schema:refresh`/`schema:diff`/`queries:check` read the same one the initializer does |
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

  A registration that names one of your own constants — a `T::Enum` for
  `register_enum`, a mixin for `extend_type` — goes in a `to_prepare` block,
  the same place the in-process client goes and for the same reason:
  autoloading is set up after `config/initializers` run. Generation depends on
  `:environment`, which runs `to_prepare` too, so the registration is in place
  before it emits.

  ```ruby
  Rails.application.config.to_prepare do
    GraphWeaver.register_enum("Species", PetKind, fallback: PetKind::Unknown)
    GraphWeaver.extend_type("Pet", PetHelpers)
  end
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
and its registrations — runs first. The generated modules load at boot from
a `to_prepare` block, so a helper or enum you registered in one is already
in place when the file that names it loads.

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
your own repo, so rebuild it with graphql-ruby's own rake task, ahead of
`verify` in CI:

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

A stale dump makes `verify` fail on a query that is fine. `queries:check` is
unaffected: running in-process it validates against the live class, not the
dump. (`schema:diff` and `:refresh` are for servers you *don't* own; a dump
taken from a schema class records no url, and they say so.)

**Scaffolding the app too?** On a `rails new --skip-active-record`,
`rails g graphql:install` writes `config.active_record.query_log_tags` lines
into `config/application.rb` that an app without ActiveRecord can't boot
with — a graphql-ruby bug. Delete them.

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

```ruby
PersonQuery.execute!(id: "1").person&.name   # typed, via GraphWeaver.client
```

Commit the schema dump and the generated files. Generated code is reviewed like
any other code — and never edited by hand. The module name comes from the file
name; the full set of naming rules is in
[generated modules](generated_modules.md#naming).

`graphql.config.yml` is already there, so VS Code and RubyMine validate the
`.graphql` files as you type, with schema autocomplete and hover docs — see
[editors](editors.md).

**In development you don't type that command again.** While the server is
running, a `.graphql` edit — or a refreshed schema dump — regenerates before
the next request, the way a route or a locale change takes effect. A query that
doesn't compile is logged with its file and position while the modules already
loaded keep serving, so a file saved mid-edit doesn't take the server down.
Development only, and `config.graph_weaver.watch = false` turns it off. The
generated files are still what ships: commit them, and keep `rake
graph_weaver:verify` in CI.

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

One payoff worth knowing about: when a shared fragment *is* the whole selection
on a union field, its type is hoisted once into `GraphQLTypes` and every query
that spreads it gets the same Ruby type — so one exhaustive `case … T.absurd`
works everywhere. See
[abstract types](generated_modules.md#abstract-types).

## 4. Test against fakes

```ruby
# spec/support/graph_weaver.rb
require "graph_weaver/rspec"
```

```ruby
it "renders the empty state", graphql: :fake do … end   # or tag the describe
```

The tag installs a seeded, schema-correct `FakeClient` for that example — no
server, no stubs, and `rspec --seed 1234` reproduces the fake data along with
test order. The schema it fabricates from is derived (the committed dump, or
your client's), so there's nothing to configure. Tag `graphql: :in_process`
instead and the same example runs against your real resolvers. Pinning values,
simulating failures, and the federated `graphql: :router` are in
[testing](testing.md).

A fresh `rails g rspec:install` leaves the `spec/support` glob commented
out in `spec/rails_helper.rb`, so uncomment it — or put the require in
`rails_helper.rb` itself. Nothing warns you that a support file went
unread.

## 5. Verify in CI

Four questions, four tasks — the last only on a federated graph:

| ask | task | needs network |
|---|---|---|
| is the checked-in Ruby fresh? | `rake graph_weaver:verify` | no |
| has the server's schema drifted from the dump? | `rake graph_weaver:schema:diff` | yes |
| did that drift break any of my queries? | `rake graph_weaver:queries:check` | yes |
| did a subgraph change without a recompose? | `rake graph_weaver:federation:diff` | no |

`verify` compares the committed generated files against what the current
schema + queries + registrations would produce, so it belongs in every CI
build. `schema:diff` needs a dump with a recorded source url (introspected
dumps have one) and `GRAPHWEAVER_AUTH` for private APIs — run it on a
schedule and repair with `rake graph_weaver:schema:refresh`.
`federation:diff` needs no network either, so it goes in the same PR run;
see [federation](federation.md#has-the-supergraph-been-recomposed).

`schema:diff` names what moved, breaking changes first — breaking meaning
a query written against your dump stops validating, or stops casting:

```
app/graphql/schema.json vs https://api.example.com/graphql: 8 changes, 5 breaking

breaking:
  AdoptionInput.nickname          String -> String!
  Person.email                    removed
  Person.pets                     [Pet!]! -> [Pet!]
  Query.person(includeArchived:)  argument added: Boolean! — required
  Species.CAT                     enum value removed

other:
  Person.birthday  deprecated: use bornOn
  Pet.nickname     added: String
  Species.BIRD     enum value added

app/graphql/schema.json is stale — the server's schema has drifted (rake graph_weaver:schema:refresh)
```

Nullability is judged from your side, which is why the two above point
opposite ways: `Person.pets` losing its `!` hands a generated struct the
nil it declared it wouldn't get, while `AdoptionInput.nickname` gaining
one rejects a query that omits it. Any drift exits non-zero — whether a
change matters is yours to judge.

`GraphWeaver::SchemaLoader.diff(path)` is the same summary as an object —
`#breaking`, `#compatible`, `#to_h`, and `#empty?` for the plain "has it
drifted" question.

`queries:check` answers the question that actually matters when the schema
*has* moved: **which of your queries no longer validate, and why.** It
re-introspects the recorded url (without rewriting the dump) and validates
every `.graphql` file against the schema as it is right now, naming each
error's line and column, and exits non-zero:

```
app/graphql/queries/person.graphql
  4:5  Field 'nmae' doesn't exist on type 'Person' (Did you mean `name`?)

1 invalid query
```

The Ruby behind it returns the same thing as data, so you can wire it into
whatever you already have (a spec, a Slack ping, an issue):

```ruby
GraphWeaver.check_queries
# => { "app/graphql/queries/person.graphql" =>
#      [{ "message" => "Field 'nmae' doesn't exist on type 'Person' (Did you mean `name`?)",
#         "line" => 4, "column" => 5 }] }
```

Empty means everything validates. Pass `schema:` a *loaded* schema (not a path)
and nothing touches the network — handy for checking a proposed subgraph before
it's live:

```ruby
GraphWeaver.check_queries(schema: GraphWeaver::SchemaLoader.load("proposed.graphql"))
```

Left off, it re-introspects the url the dump records — and when that dump is a
composed supergraph, each error also names the subgraphs behind the type it
points at ([federation](federation.md#the-routing-table)).

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
