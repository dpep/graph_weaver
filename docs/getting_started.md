# Getting started: the production path (Rails)

The setup that ships, end to end: queries live as `.graphql` files, generation
writes `# typed: strict` Ruby you check in, and CI fails when anything drifts.
Follow it once when you add the gem to an app. (Exploring an API from a console
instead? Start with [dynamic mode](real_world.md) — no build step.)

Rails is assumed below; the [non-Rails note](#not-rails) at the bottom
covers the differences. Still deciding whether to adopt at all?
[Alternatives](alternatives.md) compares the field, this gem included.

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
      create  app/graphql/fragments/.keep
      create  app/graphql/generated/.keep
      create  graphql.config.yml
      insert  spec/rails_helper.rb
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
| `--auth` | name of the ENV var holding the auth token — default `GRAPHWEAVER_AUTH`. Url only, and omitted entirely for a public API that needs no token. The name is recorded into the dump, so `schema:refresh`/`schema:diff`/`queries:check` read the same one the initializer does |
| `--no-schema` | skip writing the dump; `rake graph_weaver:schema:refresh` does it later (`URL=...` to name an endpoint the first time) |

Re-running is safe — every file it writes goes through the usual Rails
conflict prompt, so an initializer you've edited is never overwritten
silently. The schema dump is the one file that isn't Thor's to diff, so it is
**kept** rather than prompted for — replacing it would drop the source url it
records, which `schema:diff`/`:refresh` read:

```
        keep  app/graphql/schema.json — delete it and re-run to re-introspect
```

What it wrote:

- **`config/initializers/graph_weaver.rb`.** `GraphWeaver.client =` is the
  load-bearing line: generated modules without a baked transport resolve to
  it at execute time (the full
  [resolution order](transports.md#client-resolution)). Custom
  scalars/enums/type helpers register here too — the rake tasks bake them
  into generated source, so they have to run first ([scalars](scalars.md)):

  ```ruby
  GraphWeaver.register_scalar("Money", Money)   # a scalar the registry can't know
  ```

  Every setting also takes the block form the file's neighbours use —
  `GraphWeaver.configure { |config| … }`, where `config` is `GraphWeaver`
  itself, so the two spellings are one call.

  A registration that names one of your own constants — a `T::Enum` for
  `register_enum`, a mixin for [`extend_type`](generated_modules.md#type-helpers)
  — goes in a `to_prepare` block, the same place the in-process client goes and
  for the same reason:
  autoloading is set up after `config/initializers` run. Generation depends on
  `:environment`, which runs `to_prepare` too, so the registration is in place
  before it emits.

  ```ruby
  Rails.application.config.to_prepare do
    GraphWeaver.register_enum("Species", PetKind, fallback: PetKind::Unknown)
    GraphWeaver.extend_type("Pet", PetHelpers)
  end
  ```

  A custom `GraphQL::Schema::Validator` ([the `extensions.input`
  recipe](errors.md#what-your-server-can-send)) is installed by *symbol*, so
  nothing references its constant and Zeitwerk never autoloads it — name it in
  the same `to_prepare` block, above the schema, or the schema raises
  `unknown validation: :your_rule` on whichever file boots first.

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
- **`app/graphql/queries/`, `app/graphql/fragments/`, `app/graphql/generated/`.**
  Where you write queries, where shared fragments live, and where generation
  writes Ruby.
- **`.rubocop.yml`**, if you have one. Generated code is machine-written and
  marked "do not edit," so the output directory is added to `AllCops: Exclude:`
  — otherwise `Style/Documentation`, `Style/ClassAndModuleChildren` and
  `Metrics/*` fire on every generated file. An `AllCops:` you already have is
  left alone (a second one would replace it, not merge); the generator prints
  the line to add.

Rake needs no wiring either: in Rails the `graph_weaver:*` tasks register
themselves (a Railtie) and depend on `:environment`, so your initializer —
and its registrations — runs first. The generated modules load at boot from
a `to_prepare` block, so a helper or enum you registered in one is already
in place when the file that names it loads.

Everything above describes **one** schema, which is the usual case. An app
with a second one declares each as a graph — [more than one
schema](#more-than-one-schema), at the end; skip it until you have two.

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
any other code — and never edited by hand. One rule covers the names: the file
name becomes the module (`person.graphql` → `PersonQuery`), and every selection
inside it becomes a struct named for its **response key**, not its schema type
— a `countries { … }` selection is `CountriesQuery::Result::Countries` even
where the schema calls the type `Country`. The corners are in
[generated modules](generated_modules.md#naming).

**Not sure what the API offers?** `app/graphql/schema.json` is the whole schema
as plain JSON — types, fields, descriptions — already in your repo. And
`graphql.config.yml` is there too, so VS Code and RubyMine validate the
`.graphql` files as you type, with autocomplete and hover docs off that same
dump — see [editors](editors.md).

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

The generator put `require "graph_weaver/rspec"` in your `spec/rails_helper.rb`
— add it there yourself if rspec arrived after the install, since the tags
below do nothing without it.

```ruby
it "renders the empty state", graphql: :fake do … end   # or tag the describe
```

The tag installs a seeded, schema-correct `FakeClient` for that example — and
**nothing leaves the process**: no server, no HTTP at all, so no webmock and
no VCR. `rspec --seed 1234` reproduces the fake data along with test order.
The schema it fabricates from is derived (the committed dump, or your
client's), so there is nothing to configure. Tag `graphql: :in_process`
instead and the same example runs against your real resolvers.

A request spec is the usual shape: tag it, pin the value the assertion is
about, and everything else in the selection is still fabricated.

```ruby
# spec/requests/people_spec.rb
RSpec.describe "People", type: :request do
  it "lists people", graphql: :fake do
    graphql_fake("Person" => { "name" => "Ada Lovelace" })

    get "/people"

    expect(response.body).to include("Ada Lovelace")
  end
end
```

Pins, simulating failures, and the federated `graphql: :router` are in
[testing](testing.md).

A fresh `rails g rspec:install` leaves the `spec/support` glob commented
out in `spec/rails_helper.rb`, so uncomment it — or put the require in
`rails_helper.rb` itself. Nothing warns you that a support file went
unread.

## 5. Verify in CI

Five questions, five tasks — the last only on a federated graph:

| ask | task | needs network |
|---|---|---|
| is the checked-in Ruby fresh? | `rake graph_weaver:verify` | no |
| has the server's schema drifted from the dump? | `rake graph_weaver:schema:diff` | yes |
| did that drift break any of my queries? | `rake graph_weaver:queries:check` | yes |
| does the app still read what it selects? | `rake graph_weaver:unused` | no |
| did a subgraph change without a recompose? | `rake graph_weaver:federation:diff` | no |

(`rake graph_weaver:graphs` answers a sixth, when an app has more than one
schema: which graphs are configured, and where each generates.)

`verify` compares the committed generated files against what the current
schema + queries + registrations would produce, so it belongs in every CI
build. `schema:diff` asks whatever the dump came from — a recorded source url
(with `GRAPHWEAVER_AUTH` for private APIs), or your own schema class when the
app [serves the schema itself](#your-apps-own-schema-in-process) — and
`rake graph_weaver:schema:refresh` is the repair either way.
`federation:diff` needs no network, so it goes in the same PR run;
see [federation](federation.md#has-the-supergraph-been-recomposed).

Every one of them exits non-zero on a finding, so the gate is a chain. The two
topologies differ only in what reaches a network:

```sh
# an API you don't own — the dump records the url it was introspected from
bundle exec rake graph_weaver:verify          # offline checks first, so a
bundle exec rake graph_weaver:cassettes:check # network blip can't mask one
bundle exec rake graph_weaver:queries:check   # re-introspects the recorded url
bundle exec rake graph_weaver:schema:diff     # …so does this one
```

```sh
# your own graphql-ruby schema, in-process — none of this touches a network
bundle exec rake graph_weaver:schema:diff     # has the class moved past the dump?
bundle exec rake graph_weaver:queries:check   # do the queries still validate?
bundle exec rake graph_weaver:verify          # is the checked-in Ruby current?
bundle exec rake graph_weaver:cassettes:check # do the recordings still cast?
```

In-process the order is the repair order: refresh the dump, regenerate,
re-record. As a GitHub Actions job:

```yaml
# .github/workflows/graphql.yml
name: graphql
on: [push]
jobs:
  graph_weaver:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - run: bundle exec rake graph_weaver:verify
      - run: bundle exec rake graph_weaver:cassettes:check
      - run: bundle exec rake graph_weaver:queries:check
      - run: bundle exec rake graph_weaver:schema:diff
        env:
          GRAPHWEAVER_AUTH: ${{ secrets.GRAPHWEAVER_AUTH }}
```

An in-process schema needs no `env:` — it answers introspection itself.

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

### The selections nothing reads

`rake graph_weaver:unused` asks the one question the others can't: not "is the
Ruby fresh" but "does the app still use what the query asks for". A field
someone stopped rendering stays in the `.graphql` forever — the query keeps
validating, the struct keeps casting, and the server keeps paying to resolve
it. graphql-client catches that at runtime by masking the data a caller didn't
declare; the structs are checked in here, so it can be recovered without
running anything:

```
app/graphql/queries/products.graphql: Products.sku — selected, never read (Catalog::ProductsQuery::Result::Products#sku)
app/graphql/queries/products.graphql: Products.blurb — selected, never read (Catalog::ProductsQuery::Result::Products#blurb)

13 selections, 2 unread — 2 queries, 58 files swept under .
```

Each line names the query file, the selection to go and delete, and the
generated prop behind it. It reads the generated structs for the props a
query produced, then sweeps your `.rb`, `.rake`, `.builder`, `.erb`, `.slim`,
`.haml` and `.jbuilder` **once** for every name they could be read by —
`.sku`, `sku:`, `:sku`, `"sku"`. `PATHS=app,lib` narrows the sweep, and a
`PATHS=` naming a directory that isn't there is refused rather than swept as
nothing. Everything under a directory named `generated`, plus `vendor`,
`node_modules`, `tmp` and `log`, is skipped either way, as is any file
defining a graphql-ruby **type** — `< GraphQL::Schema::Object` or the
`< Types::BaseObject` the generator writes — since a `field :sku` there is
your *server* offering a field, not this app reading one back. A `Resolver` or
a `Mutation` is swept like any other code: that is where a BFF reads the graph
it consumes. Nothing is edited and the exit is 0; `STRICT=1` exits 1 when
anything is unread, for teams who want the gate.

A line handing a query module straight to a serializer — `render json:`,
`to_h`, `to_json`, `as_json`, `serialize`, `deconstruct_keys` — reads every
prop at once, so that module is excused and the line is quoted, because
matching a serializer by name is the softest thing here and a wrong excuse
should be obvious:

```
Accounts::MeQuery: every prop counted as read — handed whole to a serializer at app/controllers/accounts_controller.rb:3
  render json: Accounts::MeQuery.execute!.me
```

A local counts too, which is what makes the ordinary two-line controller work
— `result = Accounts::MeQuery.execute!` on one line, `render json: result.me`
on the next — and the excuse names the local it followed.

**It is a lint, not a proof**, and the task's own footer says so. It matches
names as text, so a prop called `name` counts as read the moment anything at
all says `.name`; and it can't see a prop reached by `public_send` or a read
in a file type it doesn't sweep. The example above is the best case, not the
typical one: measured against real corpora, **half to two thirds of genuinely
unread selections go unreported**, the share rising with the size of the app,
because common prop names collide with ordinary words somewhere in it.
Silence is the safe direction here. Treat a finding as a prompt to go and
look, and a clean run as nothing more than the absence of an obvious one —
which is why it exits 0 unless you ask it not to.

## Your app's own schema, in-process

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

Each query gets its own copy of that hash, so a resolver writing
`context[:loader] =` can't hand what it wrote to the next request — which
matters because one in-process client is normally the whole app's.

**Keep the dump in step with the schema.** Codegen reads the committed
dump at `GraphWeaver.schema_path`, never the live class — that's what
makes `rake graph_weaver:verify` a deterministic CI check. The generator
writes the first dump; after that it's an artifact derived from code in
your own repo, and the same two tasks a remote schema uses keep it in step:

```sh
rake graph_weaver:schema:diff      # what has the class changed since the dump?
rake graph_weaver:schema:refresh   # rewrite the dump from the class
rake graph_weaver:generate
```

Neither touches a network here — your schema class answers introspection
itself — and `refresh` rewrites the dump in whatever format it already is, so
a repo that chose `cache: :graphql` keeps SDL. graphql-ruby's own
`GraphQL::RakeTask` writes the same artifact, but you don't need to wire it
up: `schema:refresh` writes to the path graph_weaver already reads, and is
what `schema:diff` and a runtime "the schema may have changed" error both
name.

`verify` **fails** when the dump has fallen behind the class, rather than
calling the tree up to date: generating from a dump that old would produce
Ruby for a schema your resolvers have already left. `queries:check` is
unaffected either way — running in-process it validates against the live
class, not the dump — so the two can disagree about the same query while the
dump is stale, and `schema:refresh` is what settles it.

**Scaffolding the app too?** On a `rails new --skip-active-record`,
`rails g graphql:install` writes `config.active_record.query_log_tags` lines
into `config/application.rb` that an app without ActiveRecord can't boot
with — a graphql-ruby bug. Run it as
`rails g graphql:install --skip-query-logs`, or delete the lines it wrote.

## A schema dump you already have

```sh
rails g graph_weaver:install db/schema.graphql
```

Sets `GraphWeaver.schema_path` to that file rather than writing a second
copy, and introspects nothing. A dump has no resolvers, so it can't
execute — set `GraphWeaver.client` to whatever serves the API.

## More than one schema

The five steps above describe one graph — a schema, its queries, its output.
An app with a second schema declares each one:

```ruby
# config/initializers/graph_weaver.rb
GraphWeaver.graph :billing do
  schema    -> { Billing::Schema }
  queries   "app/graphql/billing/queries"
  output    "app/graphql/billing/generated"
  client    "Billing::Schema"
  namespace "Billing"
  register_scalar "Money", BigDecimal
end

GraphWeaver.graph :github do
  schema    "db/github.json"
  queries   "app/graphql/github/queries"
  output    "app/graphql/github/generated"
  client    "GITHUB"
  namespace "GitHub"
end
```

One `rake graph_weaver:generate` does the app, one `rake graph_weaver:verify`
gates it, and `rake graph_weaver:graphs` lists what is configured. Everything a
graph knows is said inside the block — six settings, and the same three
registrations you write at the top level. Each setting falls back to the
matching top-level one, so a graph says only what differs, and anything else
the block calls is refused naming the nine it takes.

| setting | takes |
|---|---|
| `schema` | a graphql-ruby schema class, a [`Client`](transports.md), a path to a dump, SDL, or a lambda returning one |
| `queries` | a directory, or a list of them — the `.graphql` files this graph generates from |
| `output` | one directory — where this graph's generated Ruby is written |
| `client` | a constant, or its name — what this graph's modules execute against |
| `namespace` | a constant, or its name — what every constant this graph generates nests under |
| `types_module` | a constant name for the shared types module (default: `GraphQLTypes`, under `namespace`) |

**`client` names a constant, not a url.** Its value is spelled into every module
this graph generates and resolved the first time one of them executes — so it
has to be something generated source can write down, and a url is not. Build
the client wherever you like and put the constant holding it here:

```ruby
GITHUB = GraphWeaver.new("https://api.github.com/graphql", auth: ENV["GITHUB_TOKEN"])
```

Resolving at first use rather than at declaration is what lets an initializer
name `Billing::Schema` before Zeitwerk has loaded it, and what lets a dev reload
swap the class object underneath. A graph with no `client` generates modules
that fall back to `GraphWeaver.client`, the app default.

`schema "x"` sets and a bare `schema` reads back. There is no `schema = "x"`
form: the block is `instance_eval`'d, so that would be a local variable that
silently does nothing — the same reason graphql-ruby writes `field :name`.

### Two remote APIs, and no schema of your own

An app that is a pure client of someone else's GraphQL owns no schema class at
all, so every graph's schema is a dump — and the dumps have to come from
somewhere. Name the file you want and the client that can fetch it, and
`schema:refresh` writes it:

```ruby
# config/initializers/graph_weaver.rb
COUNTRIES = GraphWeaver.new("https://countries.trevorblades.com/")
POKE      = GraphWeaver.new("https://beta.pokeapi.co/graphql/v1beta")

GraphWeaver.graph :countries do
  schema    "app/graphql/countries/schema.json"
  queries   "app/graphql/countries/queries"
  output    "app/graphql/countries/generated"
  client    "COUNTRIES"
  namespace "Countries"
end

GraphWeaver.graph :poke do
  schema    "app/graphql/poke/schema.json"
  queries   "app/graphql/poke/queries"
  output    "app/graphql/poke/generated"
  client    "POKE"
  namespace "Poke"
end
```

```sh
rake graph_weaver:schema:refresh   # introspects each graph's client into its schema
rake graph_weaver:generate
```

A graph whose dump isn't there yet is introspected from the url its own client
posts to, and the dump records that url — so every later `schema:refresh` and
`schema:diff` re-reads the right server without being told again. `URL=` is for
the app that has one dump and no graphs; it names a single endpoint, and here
each graph has its own.

In specs, `graph:` is how an example says which graph a helper stands in for —
`graphql_fake(graph: :poke, "pokemon_v2_pokemon.name" => "pikachu")`. See
[testing.md](testing.md).

**In Rails, declare graphs in the initializer itself, and name an autoloaded
schema class with a lambda** — `schema -> { Billing::Schema }` — as above.
Zeitwerk is set up *after* `config/initializers` run, so a bare
`Billing::Schema` there raises `uninitialized constant`; the lambda is resolved
when generation asks, and resolved again after a dev reload has replaced the
class object. (`client` and `namespace` take the constant or its name, since
either way it is baked into generated source as a name.)

**The block runs where you write it**, registrations included — so a
registration naming one of your own constants is in exactly the position a
top-level one is, and has the same answer: declare that graph from a
`to_prepare` block, as [above](#2-run-the-generator).

```ruby
Rails.application.config.to_prepare do
  GraphWeaver.graph :billing do
    schema    Billing::Schema
    queries   "app/graphql/billing/queries"
    output    "app/graphql/billing/generated"
    namespace "Billing"
    register_enum "Species", PetKind
  end
end
```

Re-running is safe — the name is the identity, so the second declaration
replaces the first — and watch mode sees the graph either way.

One constraint: `to_prepare` runs after Rails has set Zeitwerk up, and Zeitwerk
reads its ignore list only then, so an `output` declared there can't be hidden
from autoloading. Under the conventional `app/graphql/*/generated` it already
is; anywhere else is refused at boot, naming the two fixes — declare the graph
in `config/initializers` with `schema -> { Billing::Schema }`, or add the
directory to `GraphWeaver.generated_paths` there.

Two things are worth knowing:

- **`namespace` nests everything that graph generates** — `person.graphql`
  becomes `Billing::PersonQuery`, and its shared types module becomes
  `Billing::GraphQLTypes`. Constants are global, so two schemas that both have a
  `person.graphql`, or that both hoist an enum, would otherwise fight over one
  name. Without a namespace the collision is refused at generation, naming both
  files.
- **The block's registrations reach that graph alone**, laid over the top-level
  ones. That is what makes the build quiet: `Money` is checked against the
  schema it was registered for, and against no other. The top-level layer is
  read when generation asks, not when the graph is declared, so a
  `register_scalar` in another initializer reaches every graph whichever
  initializer Rails happened to run first.

Declaring any graph replaces the implicit one the settings describe — an app
either has graphs or has settings, never a silent third thing. The name is the
identity, so re-declaring `:billing` replaces it rather than adding a second
one; a `to_prepare` block that re-runs on every reload is safe.

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
`GraphWeaver.extend_t_sig = true`/`false`.

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

Those paths are the Rails convention, not a requirement: put the files where
your project already puts things and say so with `GraphWeaver.queries_paths`
and `GraphWeaver.generated_paths`.

Add `require "graph_weaver/tasks"` to your Rakefile for the rake tasks —
and, since there's no `:environment` hook to run your registrations,
require the file that does them from the Rakefile too.

**Or skip rake too.** The tasks are a thin wrapper over public calls, so a
script of your own does the same work — and `cache: true` writes the dump on
that first introspection, so there's nothing to refresh first:

```ruby
client = GraphWeaver.new("https://api.example.com/graphql", cache: true)
client.schema                     # introspects once, writing the dump

schema = GraphWeaver::SchemaLoader.load(GraphWeaver.schema_path)
GraphWeaver.generate!(schema:)    # => every file the plan produces
GraphWeaver.changed_files         # => only the ones whose bytes moved
```

Pruning, the shared types module, and `verify_generated!` — the freshness
guard `rake graph_weaver:verify` runs — are in
[generated modules](generated_modules.md#generating).

`graphql.config.yml` is copy/paste from [editors](editors.md).
