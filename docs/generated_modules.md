# Generated modules

`GraphWeaver::Codegen` turns one GraphQL operation into one `# typed: strict`
Ruby module. Everything `srb tc` knows about your query results comes from this
file — there is no runtime schema, no lazy wrapper, no reflection.

This is the production path — checked in, reviewed, statically checked
(assembled step by step in the [getting started](getting_started.md), including
[what Sorbet does and doesn't require](getting_started.md#sorbet-with-or-without)).
For consoles and dev there's [dynamic mode](#dynamic-mode); for one-off
scripts, `client.execute!` skips modules entirely.

## Generating

The workflow that keeps generated code honest: queries live as `.graphql`
files (the source of truth), generation writes the Ruby, and verification
fails when the two drift. The conventional layout (configurable via
`GraphWeaver.queries_path` / `generated_path` / `schema_path`):

```text
app/graphql/
  schema.json        # introspection dump (or schema.graphql SDL)
  queries/           # *.graphql — hand-written, reviewed
  generated/         # *_query.rb — generated, checked in, never edited
```

The schema dump is step 0 — codegen reads it, never a live endpoint.
`cache: true` on a url client writes it on first introspection
(`GraphWeaver.new(url, cache: true).schema` in a console bootstraps it);
generating without one fails pointing at exactly that.

Rake tasks (self-registering in Rails; elsewhere add
`require "graph_weaver/tasks"` to your Rakefile):

```sh
rake graph_weaver:generate    # queries_path -> generated_path
rake graph_weaver:verify      # fail if anything is stale — run in CI
```

Scalar/enum/type registrations are baked into generated source, so they
must run before the tasks do. In Rails they will — the tasks depend on
`:environment`, which runs your initializers. Outside Rails, require the
file that does your registrations from the Rakefile yourself.

Or call the same APIs directly:

```ruby
schema = GraphWeaver::SchemaLoader.load(GraphWeaver.schema_path)
GraphWeaver.generate!(schema:)            # write the modules
GraphWeaver.verify_generated!(schema:)    # the freshness guard, one line in a spec
```

In Rails, loading is automatic — the Railtie requires every file under
`generated_path` at boot, after your initializers (so registrations run
first). Elsewhere it's explicit, factory_bot-style:

```ruby
GraphWeaver.load_generated!   # require every file under generated_path
```

(Plain requires, not Zeitwerk: Zeitwerk would expect
`Generated::PersonQuery` from `generated/person_query.rb`, and generated
code only changes on regeneration — restart, like a schema migration.)

Regenerate when: a query changes, the schema changes (a
[`schema_stale?`](errors.md) error in production is the late signal — refresh
the schema dump and regenerate), a scalar registration changes, or GraphWeaver
itself upgrades (emission may differ across versions; `verify_generated!`
catches it).

Introspected dumps record their source url, so drift is checkable ahead
of the late signal: `rake graph_weaver:schema:verify` re-introspects the
recorded url and fails when the server has moved;
`rake graph_weaver:schema:refresh` rewrites the dump
(`GRAPHWEAVER_AUTH` supplies a token for private APIs). Don't confuse
the two verifies: `graph_weaver:verify` asks "is the generated code
fresh?" — local, every CI run; `graph_weaver:schema:verify` asks "has the
*server* drifted from the dump?" — network, needs the recorded url, run
on a schedule.

In development, skip the build entirely — `client.load_queries!` parses
every query file into modules with the same names generation would use
(see [dynamic mode](#dynamic-mode)).

## Anatomy

```ruby
module PersonQuery
  QUERY = "..."                  # the operation, verbatim

  class Result < T::Struct       # the response shape, exactly as selected
    class Person < T::Struct
      const :name, String        # non-null in the schema
      const :birthday, T.nilable(Date)

      def self.from_h(data) ...  # generated casting — no reflection
    end

    const :person, T.nilable(Person)
  end

  def self.executor ...          # default transport (see below)
  def self.execute(id:, executor: self.executor)   # -> GraphWeaver::Response[Result]
  def self.execute!(id:, executor: self.executor)  # -> Result, or raises QueryError
end
```

- `execute` returns the **envelope** — `GraphWeaver::Response[Result]` with
  `#data`, `#data!`, `#errors`, `#extensions` — so partial data and
  cost/throttle metadata survive.
- `execute!` is the shortcut: the typed result or a raised
  `GraphWeaver::QueryError`.

## Variables become typed kwargs

```graphql
mutation($name: String!, $species: Species!, $note: String) { ... }
```

```ruby
AddPetQuery.execute!(name: "Rex", species: AddPetQuery::Species::Dog)
```

- required vs optional falls out of nullability and defaults: nullable or
  defaulted variables become optional kwargs (nil is omitted from the wire,
  so server-side defaults apply)
- enum variables generate module-level `T::Enum`s and accept the enum or
  its wire value (`species: Species::Dog` or `species: "DOG"`)
- custom scalars serialize through the [scalar registry](scalars.md)

**Input objects**: when an operation's only variable is a required input
object (the Relay convention), the input's fields flatten straight into
`execute`'s kwargs — no wrapper at the call site:

```graphql
mutation($input: AdoptionInput!) { adopt(input: $input) { ... } }
```

```ruby
AdoptQuery.execute!(name: "Rex", species: "DOG", nickname: "Rexy")
```

The wrapping level is rebuilt on the wire, and each field type-checks
exactly like a variable would. Operations with more than one variable (or
a nullable input) keep the variable-per-kwarg surface — there the input
kwarg accepts the generated `T::Struct` or a plain hash (`.coerce`
normalizes underscored Symbol/String keys; enums accept wire values;
nested inputs accept hashes; unknown keys raise with a spellchecked
hint rather than silently dropping):

```ruby
AdoptQuery.execute!(input: { name: "Rex", species: "DOG" }, detail: true)
```

The structs themselves are module-level (`AdoptQuery::AdoptionInput`) with
`serialize` (aliased as `to_h`) producing the wire hash — optional fields
default nil and stay off the wire. Nested inputs work (dependencies emit
first), including recursive ones — Hasura's self-referential `bool_exp`
filters generate cleanly (`_and:`/`_not:` fields typed as the struct
itself), so variable-driven filtering works:

```ruby
where = mod::PokemonBoolExp.coerce(
  _and: [{ name: { _like: "%chu" } }, { _not: { name: { _eq: "raichu" } } }],
)
mod.execute!(where:)
```

## Selections

- **Fragments** — inline fragments and named spreads flatten into the
  selection; type conditions match exact names or interfaces/unions the type
  belongs to.
- **Unions and interfaces** — when the selection *varies by concrete
  type*, each abstract site emits a module: one member struct per
  possible type, `Type = T.type_alias { T.any(...) }`, and a `from_h`
  dispatching on `__typename` — which generation therefore *requires* in
  the selection (the wire response carries no type tag unless you ask).
  Two narrower shapes skip the dispatch (and the `__typename`) entirely:
  interface-level fields only → one shared struct; a single `... on X`
  condition and nothing else → `X`'s struct, always nilable — a
  non-matching runtime type comes back as `nil`, so narrowing doubles as
  filtering.
- **`@skip` / `@include`** — a directive-conditional field may be absent from
  the response regardless of schema nullability, so its generated type is
  always nilable.
- **Aliases** — result keys follow aliases; props are the underscored alias.

Props are always snake_case (`nameWithOwner` → `name_with_owner`). Reaching
for the wire name is a classic stumble, so it fails helpfully at both
layers: `srb tc` flags it statically, and at runtime (consoles, dynamic
mode) the struct raises a NoMethodError naming the prop that does exist —
`use 'name_with_owner'` for the exact wire name, `did you mean ...?` for
a near-miss typo in either casing.

## Naming

Module names derive from the operation name (`query GetPerson` → `GetPerson`);
`GraphWeaver.parse` on a `.graphql` file derives from the file name
(`person.graphql` → `PersonQuery`). Pass `module_name:`/`name:` to override.
`Codegen.generate` requires a deliberate name for anonymous operations; dynamic
`parse` defaults to `Query` (its constants are container-scoped, so collisions
are impossible).

Nested struct names come from GraphQL type names, disambiguated one level by
field name on collision.

## Executors

An executor is anything with `execute(query, variables:)` whose result `to_h`s
into `{"data" => ..., "errors" => ...}`. Resolution: per call → per module →
baked constant → `GraphWeaver.executor=` → `GraphWeaver.client` — the
canonical list lives in [transports](transports.md#executor-resolution).

Generate *without* a baked constant when you want modules to follow the
app default (`GraphWeaver.client =` in an initializer) — that's also what
lets [testing's auto_fake](testing.md) swap in a fake per example.

## Dynamic mode

`GraphWeaver.parse` generates + evals in one step (no build artifact, evaled
into an anonymous container — no global constants leak). Same runtime
semantics; invisible to `srb tc`, so prefer the build step where static
checking matters. `GraphWeaver.execute(schema:, query:, variables: {})` is
the one-shot form.

Generated source is eval'd, so inputs are validated: module names must be
constant names, and query heredocs can't be terminated early. Still: queries
are code — don't feed untrusted strings to parse.
