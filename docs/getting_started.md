# Getting started: the production path (Rails)

The setup that ships, end to end: queries live as `.graphql` files, generation
writes `# typed: strict` Ruby you check in, and CI fails when anything drifts.
Follow it once when you add the gem to an app. Rails is assumed;
[not Rails?](#not-rails) covers the differences. Exploring an API from a console
instead? Start with [dynamic mode](real_world.md) — no build step. No Sorbet in
your app? None needed — [Sorbet, with or without](#sorbet-with-or-without).
Already have a GraphQL client? [Migrating](migrating.md) is the order to move
off it in.

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

The argument is whatever you'd pass to `GraphWeaver.new` — the same three source
forms the library takes — and the generator writes the initializer that fits:

| source | |
|---|---|
| `https://api.example.com/graphql` | an endpoint: introspected now, and the dump committed |
| `MyApp::Schema` | your own graphql-ruby schema, executing [in-process](#your-apps-own-schema-in-process) |
| `db/schema.graphql` | a [dump you already have](#a-schema-dump-you-already-have) — pointed at, not copied |

| flag | |
|---|---|
| `--auth` | name of the ENV var holding the auth token — default `GRAPHWEAVER_AUTH`, url only, omitted for a public API. The name is recorded into the dump, so `schema:refresh`/`schema:diff`/`queries:check` read the same one the initializer does |
| `--no-schema` | skip writing the dump; `rake graph_weaver:schema:refresh` does it later (`URL=...` to name an endpoint the first time) |

Re-running is safe: every file goes through the usual Rails conflict prompt, so
an initializer you've edited is never overwritten silently. The schema dump is
the exception — it is **kept** rather than prompted for, since replacing it
would drop the source url it records; delete it and re-run to re-introspect.

What it wrote:

- **`config/initializers/graph_weaver.rb`.** `GraphWeaver.client =` is the
  load-bearing line: generated modules belonging to no declared graph resolve to
  it at execute time (the full
  [resolution order](transports.md#client-resolution)). Custom
  scalars/enums/type helpers register here too — the rake tasks bake them into
  generated source, so they have to run first ([scalars](scalars.md)):

  ```ruby
  GraphWeaver.register_scalar("Money", Money)   # a scalar the registry can't know
  ```

  Every setting also takes the block form — `GraphWeaver.configure { |config| … }`,
  where `config` is `GraphWeaver` itself, so the two spellings are one call.

  A registration that names one of your **own** constants — a `T::Enum` for
  `register_enum`, a mixin for [`extend_type`](generated_modules.md#type-helpers)
  — goes in a `to_prepare` block instead, because autoloading is set up after
  `config/initializers` run. Generation depends on `:environment`, which runs
  `to_prepare` too, so the registration is still in place before it emits:

  ```ruby
  Rails.application.config.to_prepare do
    GraphWeaver.register_enum("Species", PetKind, fallback: PetKind::Unknown)
    GraphWeaver.extend_type("Pet", PetHelpers)
  end
  ```
- **`app/graphql/schema.json`.** The schema dump codegen reads
  (`GraphWeaver.schema_path`) — never written by hand, always committed.
  `cache: true` in the initializer reuses it; delete the file to re-introspect.
  Prefer PR-reviewable diffs? `cache: :graphql` writes SDL instead; both
  generate identical code. (`cache:`/`ttl:` apply only to url clients — a schema
  source never introspects, so passing them raises.) A dump records the url it
  came from, so a second client at a second origin caches under
  `app/graphql/schema-<digest>.json` rather than overwriting the first's; name
  the file yourself (`cache: "app/graphql/billing.json"`) to say which is which.
- **`graphql.config.yml`.** Five lines of YAML that give VS Code and RubyMine
  schema autocomplete, hover docs, and validation as you type in `.graphql`
  files — no JS project, no `npm install`. See [editors](editors.md).
- **`app/graphql/queries/`, `app/graphql/fragments/`, `app/graphql/generated/`.**
  Where you write queries, where shared fragments live, and where generation
  writes Ruby.
- **`.rubocop.yml`**, if you have one. Generated code is machine-written and
  marked "do not edit," so the output directory is added to `AllCops: Exclude:`.
  An `AllCops:` you already have is left alone (a second one would replace it,
  not merge); the generator prints the line to add.
- **`.gitattributes`** — `app/graphql/generated/** linguist-generated`, which is
  how GitHub is told the same thing: it collapses those files in a pull-request
  diff and leaves them out of the repository's language breakdown. Display only,
  so they stay versioned and expandable
  ([the three tellings](generated_modules.md#make-your-tooling-treat-generated-as-generated)).

Rake needs no wiring: in Rails the `graph_weaver:*` tasks register themselves and
depend on `:environment`, so your initializer runs first. The generated modules
load at the end of boot, after your initializers and after any `to_prepare`
block of yours, so a helper or enum you registered is already in place when the
file that names it loads.

All of that describes **one** schema, which is the usual case; an app with a
second one declares each as a graph ([more than one
schema](#more-than-one-schema)).

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
as plain JSON — types, fields, descriptions — already in your repo, and
[your editor reads it](editors.md) as you type the query.

**In development you don't type that command again.** While the server is
running, a `.graphql` edit — or a refreshed schema dump — regenerates before the
next request, the way a route change takes effect; a query that doesn't compile
is logged with its file and position while the modules already loaded keep
serving, so a file saved mid-edit doesn't take the server down. Development
only, and `config.graph_weaver.watch = false` turns it off. The generated files
are still what ships: commit them, and keep `rake graph_weaver:verify` in CI.

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

One payoff: when a shared fragment *is* the whole selection on a field, its type
is hoisted once into `GraphQLTypes` under the fragment's name and every query
that spreads it gets the same Ruby type — so a presenter can take a
`GraphQLTypes::PersonFields`, and a union's `case … T.absurd` works everywhere.
See [hoisting](generated_modules.md#a-shared-fragment-is-one-type).

## 4. Test against fakes

The generator put `require "graph_weaver/rspec"` in your `spec/rails_helper.rb`
— add it there yourself if rspec arrived after the install, since the tags below
do nothing without it.

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

The tag installs a seeded, schema-correct `FakeClient` for that example, and
**nothing leaves the process**: no server, no HTTP, so no webmock and no VCR.
`rspec --seed 1234` reproduces the fake data along with test order. Pin the value
the assertion is about and everything else in the selection is still fabricated.
Tag `graphql: :in_process` instead and the same example runs against your real
resolvers. Pins, simulating failures, and the federated `graphql: :router` are in
[testing](testing.md).

A fresh `rails g rspec:install` leaves the `spec/support` glob commented out in
`spec/rails_helper.rb`, so uncomment it — or put the require in
`rails_helper.rb` itself. Nothing warns you that a support file went unread.

## 5. Verify in CI

Five questions, five tasks — the last only on a federated graph:

| ask | task | needs network |
|---|---|---|
| is the checked-in Ruby fresh? | `rake graph_weaver:verify` | no |
| has the server's schema drifted from the dump? | `rake graph_weaver:schema:diff` | yes |
| did that drift break any of my queries? | `rake graph_weaver:queries:check` | yes |
| does the app still read what it selects? | `rake graph_weaver:unused` | no |
| did a subgraph change without a recompose? | `rake graph_weaver:federation:diff` | no |

Every one of them exits non-zero on a finding, so the gate is a chain.
`verify` compares the committed generated files against what the current schema
+ queries + registrations would produce, so it belongs in every CI build.
`schema:diff` asks whatever the dump came from — the source url the dump
recorded (with `GRAPHWEAVER_AUTH` for private APIs), your own schema class when
the app [serves the schema itself](#your-apps-own-schema-in-process), else the
client this graph's modules already post to — and
`rake graph_weaver:schema:refresh` is the repair either way. On an app with more
than one schema, `rake graph_weaver:graphs` lists which graphs are configured,
where each generates, and what each registers.

The two topologies differ only in what reaches a network:

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
re-record. In GitHub Actions each line is one `- run:` step; the remote chain
wants `GRAPHWEAVER_AUTH: ${{ secrets.GRAPHWEAVER_AUTH }}` in the `env:` of the
two steps that re-introspect, and an in-process schema needs no `env:` at all,
since it answers introspection itself. A federated app adds `rake
graph_weaver:federation:diff` to either chain — it needs no network.

**On a federated graph, none of the five looks at the schema production is
serving**, because no endpoint serves a composed supergraph. The pre-deploy
check against the live graph is Apollo's, not this gem's — run `rover subgraph
check` and `rover supergraph fetch` in the same job. See
[federation → in CI](federation.md#in-ci).

`schema:diff` names what moved, breaking changes first — breaking meaning a
query written against your dump stops validating, or stops casting:

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

Nullability is judged from your side, which is why the two above point opposite
ways: `Person.pets` losing its `!` hands a generated struct the nil it declared
it wouldn't get, while `AdoptionInput.nickname` gaining one rejects a query that
omits it. Any drift exits non-zero — whether a change matters is yours to judge.
`GraphWeaver::SchemaLoader.diff(path)` is the same summary as an object
(`#breaking`, `#compatible`, `#to_h`, `#empty?`).

`queries:check` answers the question that matters when the schema *has* moved:
**which of your queries no longer validate, and why.** It re-introspects
whatever is behind each graph's dump (without rewriting the dump) — the same
source `schema:refresh` rewrites from and `schema:diff` compares against — and
validates every `.graphql` file against the schema as it is right now, naming
each error's line and column:

```
app/graphql/queries/person.graphql
  4:5  Field 'nmae' doesn't exist on type 'Person' (Did you mean `name`?)

1 invalid query
```

A dump that records no url has nothing to re-read, and so does a graph that
names its own schema: both are checked as they stand on disk. That is `verify`'s
question rather than this one's, so the passing verdict names the file instead of
claiming a check against the server ([a dump you already
have](#a-schema-dump-you-already-have)).

`GraphWeaver.check_queries` returns the same findings as data — a hash of file
to `message`/`line`/`column`, empty when everything validates — so you can wire
it into a spec, a Slack ping, an issue. Pass it `schema:` a *loaded* schema (not
a path) and nothing touches the network, which is how you check your queries
against a proposed subgraph before it's live.

A query you have as a **string** rather than on disk asks the same client the
same question, and gets the same entries back:

```ruby
client.check_query('query($id: ID!) { person(id: $id) { nmae } }')
# => [{ "message" => "Field 'nmae' doesn't exist on type 'Person' (Did you mean `name`?)",
#       "line" => 1, "column" => 37 }]
```

Empty means it validates. It checks against that client's own schema — the one
`execute` would run against — so nothing re-introspects, and an unparseable
source comes back as an entry rather than an exception. Shared fragments are
inlined from `fragments:`, defaulting to `GraphWeaver.fragments_paths` the way
`parse` does.

### The selections nothing reads

`rake graph_weaver:unused` asks the one question the others can't: not "is the
Ruby fresh" but "does the app still use what the query asks for". A field
someone stopped rendering stays in the `.graphql` forever — the query keeps
validating, the struct keeps casting, and the server keeps paying to resolve it.

```
app/graphql/queries/products.graphql: Products.sku — selected, never read (Catalog::ProductsQuery::Result::Products#sku)

13 selections, 2 unread — 2 queries, 58 files swept under .
```

Each line names the query file, the selection to go and delete, and the
generated prop behind it. It reads the generated structs for the props a query
produced, then sweeps your `.rb`, `.rake`, `.builder`, `.erb`, `.slim`, `.haml`
and `.jbuilder` — plus Ruby carrying no extension, which is any name under
`bin/` or `exe/` and a ruby shebang anywhere else — for every name they could be
read by: `.sku`, `sku:`, `:sku`, `"sku"`. `PATHS=app,lib` narrows the sweep (a
`PATHS=` naming a directory that isn't there is refused rather than swept as
nothing); anything under a directory
named `generated`, plus `vendor`, `node_modules`, `tmp` and `log`, is skipped,
as is any file defining a graphql-ruby **type** — a `field :sku` there is your
*server* offering a field, not this app reading one back. A module handed whole
to a serializer (`render json:`, `to_h`, `as_json`, a local and all) counts every
prop as read, and the report quotes the line it followed — a plain local stands
for the module only inside the method it was assigned in, so a same-named block
param in the next method credits nothing, while an `@ivar` crosses that boundary
the way a `before_action` does. Nothing is edited and the exit is 0;
`STRICT=1` exits 1 when anything is unread.

**It is a lint, not a proof**, and the task's own footer says so. It matches
names as text, so a prop called `name` counts as read the moment anything says
`.name`, and it can't see a prop reached by `public_send`. Measured against real
corpora, **half to two thirds of genuinely unread selections go unreported**,
the share rising with the size of the app. Silence is the safe direction: treat
a finding as a prompt to go and look, and a clean run as nothing more than the
absence of an obvious one.

## Your app's own schema, in-process

An app that *serves* GraphQL with graphql-ruby can have the same typed access to
its own API — same generated structs, no socket, no HTTP:

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

`to_prepare`, not a bare assignment: the schema class is autoloaded, so it isn't
resolvable while initializers run, and a dev reload replaces it with a new class
object that a captured one would go stale against.

**Context is per request, not per app.** A resolver reading
`context[:current_user]` gets nil from the app default — build a client where
you know the request and pass it per call:

```ruby
client = GraphWeaver.new(MyApp::Schema, context: { current_user: })
PetQuery.execute!(client:, id: "1").pet.owner   # => the context's user
```

Each query gets its own copy of that hash, so a resolver writing
`context[:loader] =` can't hand what it wrote to the next request.

**Keep the dump in step with the schema.** Codegen reads the committed dump at
`GraphWeaver.schema_path`, never the live class — that's what makes `rake
graph_weaver:verify` a deterministic CI check, and why it **fails** when the
dump has fallen behind the class rather than calling the tree up to date. The
same two tasks a remote schema uses keep it in step, and neither touches a
network here:

```sh
rake graph_weaver:schema:diff      # what has the class changed since the dump?
rake graph_weaver:schema:refresh   # rewrite the dump from the class
rake graph_weaver:generate
```

`refresh` rewrites the dump in whatever format it already is, so a repo that
chose `cache: :graphql` keeps SDL. `queries:check` validates against the live
class rather than the dump, so the two can disagree about one query while the
dump is stale; `schema:refresh` settles it.

**Scaffolding the app too?** On a `rails new --skip-active-record`,
`rails g graphql:install` writes `config.active_record.query_log_tags` lines
into `config/application.rb` that an app without ActiveRecord can't boot with —
a graphql-ruby bug. Run it as `rails g graphql:install --skip-query-logs`, or
delete the lines it wrote.

## A schema dump you already have

```sh
rails g graph_weaver:install db/schema.graphql
```

Sets `GraphWeaver.schema_path` to that file rather than writing a second copy,
and introspects nothing. A dump has no resolvers, so it can't execute — set
`GraphWeaver.client` to whatever serves the API.

**A dump you brought from elsewhere has no provenance**: it doesn't record the
server it was introspected from, which is exactly what migrating off
graphql-client leaves you ([migrating](migrating.md)). `rake
graph_weaver:schema:refresh` adopts it — with no url on the file it introspects
the client the graph names, rewrites the dump, and records the source, so every
later refresh and `schema:diff` re-read the right server. `URL=` names the
endpoint instead, if you'd rather say it once than configure the client first.

Until there is something behind the dump to re-read — the url it records, or the
server the graph's client names — `queries:check` validates against the committed
file: a real check, but `verify`'s question rather than this one's, and the
verdict says which:

```
every query validates against db/schema.graphql as committed — not the server (rake graph_weaver:schema:diff asks whether the server moved)
```

A dump with no recorded url and no client behind it *is* the schema — a
hand-maintained SDL nothing serves. `schema:refresh` leaves that one alone
(`records no source url and the graph names no client — left as checked in`) and
refreshes the rest, rather than taking the whole task down with it.

## More than one schema

The five steps above describe one graph — a schema, its queries, its output. An
app with a second schema declares each one:

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
```

One `rake graph_weaver:generate` does the app, one `rake graph_weaver:verify`
gates it, and `rake graph_weaver:graphs` lists what is configured. Each setting
falls back to the matching top-level one, so a graph says only what differs, and
anything else the block calls is refused naming the nine it takes (these six,
plus `register_scalar`, `register_enum` and `extend_type`).

| setting | takes |
|---|---|
| `schema` | a graphql-ruby schema class, a [`Client`](transports.md), a path to a dump, SDL, or a lambda returning one |
| `queries` | a directory, or a list of them — the `.graphql` files this graph generates from |
| `output` | one directory — where this graph's generated Ruby is written |
| `client` | what this graph's modules execute against — a client, or the name of the constant holding one |
| `namespace` | a constant, or its name — what every constant this graph generates nests under |
| `types_module` | a constant name for the shared types module (default: `GraphQLTypes`, under `namespace`) |

**Declaring graph two means declaring graph one.** A declared graph *replaces*
the implicit one the top-level settings describe, so the moment any graph is
named, the `app/graphql/queries` and `app/graphql/generated` an existing app was
already using belong to no graph — and `generate` refuses the whole app rather
than leave them there silently. Wrap them in a graph of their own, its
directories and nothing else: no `schema`, so it keeps reading the one
`schema_path` names, and no `namespace`, so every constant keeps the name it has.

```ruby
GraphWeaver.graph :app do
  queries "app/graphql/queries"
  output  "app/graphql/generated"
end
```

**`client` is where this graph's endpoint lives** — its modules say which graph
they belong to and nothing about transport, so they read it when they execute.
A graph with no `client` falls back to `GraphWeaver.client`, the app default.
Name the object (`client GraphWeaver.new(url, auth: …)`) or, when the constant
holding it is defined later than the graph block, its name (`client "GITHUB"`),
which is resolved on first use. `schema "x"` sets and a bare `schema` reads
back; there is no `schema = "x"` form, since the block is `instance_eval`'d and
that would be a local variable that silently does nothing.

**`namespace` nests everything that graph generates** — `person.graphql` becomes
`Billing::PersonQuery` ([naming](generated_modules.md#naming)). Constants are
global, so two schemas that both have a `person.graphql` would otherwise fight
over one name; without a namespace the collision is refused at generation,
naming both files. **The block's registrations reach that graph alone**, laid
over the top-level ones — so `Money` is checked against the schema it was
registered for, and against no other.

An app that is a pure client of someone else's GraphQL owns no schema class, so
every graph's `schema` is a dump. Give each the file you want and a `client`
that can fetch it: `rake graph_weaver:schema:refresh` introspects each graph's
client into its own dump, recording the url so every later `schema:refresh` and
`schema:diff` re-reads the right server. A graph with neither a recorded url nor
a client is left as checked in and the rest still refresh. (`URL=` is for the
app that has one dump and no graphs.)

In specs, `graph:` is how an example says which graph a helper stands in for —
`graphql_fake(graph: :poke, "pokemon_v2_pokemon.name" => "pikachu")`. See
[testing](testing.md).

**In Rails, declare graphs in the initializer itself, and name an autoloaded
schema class with a lambda** — `schema -> { Billing::Schema }`, as above.
Zeitwerk is set up *after* `config/initializers` run, so a bare
`Billing::Schema` there raises `uninitialized constant`; the lambda is resolved
when generation asks, and again after a dev reload has replaced the class
object.

A block **runs where you write it**, registrations included, so a graph whose
registrations name your own constants is declared from a `to_prepare` block for
the reason [above](#2-run-the-generator) — safely, since the name is the
identity and the second declaration replaces the first. One constraint there:
Zeitwerk reads its ignore list before `to_prepare` runs, so an `output` declared
in one can't be hidden from autoloading. Under the conventional
`app/graphql/*/generated` it already is; anywhere else is refused at boot,
naming the two fixes.

## Sorbet, with or without

`sorbet-runtime` is a hard dependency, so generated `T::Struct`s and sigs
enforce at runtime in every app — no Sorbet setup required on your end. The
*static* layer (`srb tc` flagging a typo'd field before anything runs) applies
only when your app runs Sorbet, and only to checked-in generated files — dynamic
`parse` is invisible to `srb tc`.

A misspelled field is caught either way — by `srb tc` before it runs, or by
`NoMethodError` the first time it does. Nullability is the gap:
`country.capital.upcase` is a typecheck error because `capital` is `T.nilable`,
but at runtime it only raises on the rows where `capital` really is nil — which
may be none of your dev data and plenty of production's.

If your app globally injects `T::Sig` (`class Module; include T::Sig`), the
per-struct `extend T::Sig` in generated files is redundant — rubocop's
`Sorbet/RedundantExtendTSig` flags it. GraphWeaver detects that at generation
time and skips the `extend`; override with `GraphWeaver.extend_t_sig =
true`/`false`.

### The types stop where your sigs do

That typo is caught where the struct comes back. Hand the struct to one method
without a sig and it is `T.untyped` from there on — the same typo, one layer in,
is silent — and a sig on the method that produced it is no help either:

```ruby
# typed: true
class PersonDirectory
  extend T::Sig

  sig { returns(T.nilable(PersonQuery::Result::Person)) }
  def person = PersonQuery.execute!(id: "1").person
end

class Profile
  def initialize(person)   # no sig, so @person is untyped
    @person = person
  end

  def title = @person.nmae   # "No errors! Great job."
end

class Page
  def initialize(directory)   # nor is the sig above any help here
    @directory = directory
  end

  def title = @directory.person&.nmae   # also clean
end
```

Every hop has to be sig'd: the method that produces the struct, any wrapper it
passes through, and the constructor that stored the collaborator. Two shapes
cover most of an app.

A wrapper that only passes a block through keeps the block's type with
`type_parameters`:

```ruby
# a rescue wrapper that keeps the block's type
sig do
  type_parameters(:T).params(blk: T.proc.returns(T.type_parameter(:T)))
   .returns(T.type_parameter(:T))
end
def people(&blk) = yield
```

A service boundary spells the struct it hands out, and whoever holds that
service types the ivar:

```ruby
class Page
  extend T::Sig

  sig { params(directory: PersonDirectory).void }
  def initialize(directory)
    @directory = directory   # the sig is what types this ivar
  end

  sig { returns(T.nilable(String)) }
  def title = @directory.person&.nmae   # now srb tc has it
end
```

That is sigs on half a dozen service methods and a couple of constructors before
the first typo in a layered app is caught. Budget it as its own piece of work
rather than as part of generating the types — and if it isn't work you're going
to do, the runtime half still holds: a bad field is a `NoMethodError` the first
time the line runs.

### Give a struct a short name where you name one

A generated struct's constant path spells out the query that produced it, which
is what makes it stable — and long. Where your own code names one in a sig, alias
it once, in the class that hands it out:

```ruby
# before
sig { params(code: String).returns(T.nilable(Countries::CountryProfileQuery::Result::Country)) }

# after
class Directory
  Country = Countries::CountryProfileQuery::Result::Country

  sig { params(code: String).returns(T.nilable(Country)) }
end
```

Use a plain constant, not `T.type_alias`: the constant works in a sig *and* as a
value (`Country.from_h`), and in a `# typed: strict` file it needs no `T.let`
around it. Reach for `T.type_alias` only where a constant can't express the type
— a union of two queries' structs.

That takes the worst sig in one migrated app from 116 characters to 72, and the
callers get the short name too: a presenter takes a `Directory::Country` and
stops knowing which `.graphql` file produced it. It is also what makes the sig
chain above affordable, since a sig usually goes unwritten because the line is
too long to want to write.

## Not Rails?

There's no generator, but what it writes is short — a few lines wherever your
app boots, two directories, and the schema dump:

```ruby
GraphWeaver.client = GraphWeaver.new(
  "https://api.example.com/graphql",
  auth: ENV["GRAPHWEAVER_AUTH"],
  cache: true,
)
GraphWeaver.load_generated!   # no Railtie to require the generated files
```

**`load_generated!` goes before your own requires** when anything your app loads
names a generated constant as it loads — a `STATUS_LABELS` table keyed on
`GraphQLTypes::ShipmentStatus` raises `uninitialized constant` otherwise, and
building it lazily to dodge that earns `Dynamic constant references are
unsupported` from `srb tc`. One line of ordering settles both.

```sh
mkdir -p app/graphql/queries app/graphql/generated
rake graph_weaver:schema:refresh URL=https://api.example.com/graphql
```

Those paths are the Rails convention, not a requirement: put the files where
your project already puts things and say so with `GraphWeaver.queries_paths` and
`GraphWeaver.generated_paths`.

Add `require "graph_weaver/tasks"` to your Rakefile for the rake tasks — and,
since there's no `:environment` hook to run your registrations, require the file
that does them from the Rakefile too.

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

Pruning, the shared types module, and `verify_generated!` — the freshness guard
`rake graph_weaver:verify` runs — are in
[generated modules](generated_modules.md#generating).

`graphql.config.yml` is copy/paste from [editors](editors.md).
