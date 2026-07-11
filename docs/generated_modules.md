# Generated modules

`GraphWeaver::Codegen` turns one GraphQL operation into one `# typed: strict`
Ruby module. Everything srb tc knows about your query results comes from this
file — there is no runtime schema, no lazy wrapper, no reflection.

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
- enum variables generate module-level `T::Enum`s and serialize themselves
- custom scalars serialize through the [scalar registry](scalars.md)

**Input objects** generate module-level `T::Struct`s with a `serialize`
producing the wire hash — optional fields default nil and stay off the wire:

```ruby
input = AdoptQuery::AdoptionInput.new(name: "Rex", species: AdoptQuery::Species::Dog)
AdoptQuery.execute!(input:)
```

Nested inputs work (dependencies emit first); recursive input types are not
yet supported.

## Selections

- **Fragments** — inline fragments and named spreads flatten into the
  selection; type conditions match exact names or interfaces/unions the type
  belongs to.
- **Unions and interfaces** — each abstract selection site emits a module:
  one member struct per possible type, `Type = T.type_alias { T.any(...) }`,
  and a `from_h` dispatching on `__typename`. Generation *requires*
  `__typename` in the selection so dispatch is possible.
- **`@skip` / `@include`** — a directive-conditional field may be absent from
  the response regardless of schema nullability, so its generated type is
  always nilable.
- **Aliases** — result keys follow aliases; props are the underscored alias.

## Naming

Module names derive from the operation name (`query GetPerson` → `GetPerson`);
`GraphWeaver.parse` on a `.graphql` file derives from the file name
(`person.graphql` → `PersonQuery`). Pass `module_name:`/`name:` to override.
File generation requires a deliberate name for anonymous operations; dynamic
`parse` defaults to `Query` (its constants are container-scoped, so collisions
are impossible).

Nested struct names come from GraphQL type names, disambiguated one level by
field name on collision.

## Executors

An executor is anything with `execute(query, variables:)` whose result `to_h`s
into `{"data" => ..., "errors" => ...}`. Resolution order:

1. per call: `execute(..., executor: something)`
2. per module: `PersonQuery.executor = something`
3. baked constant: `Codegen.generate(..., executor: MyApi::Executor)`
4. global: `GraphWeaver.executor` (raises helpfully when unconfigured)

Generate *without* a baked constant when you want modules to follow the
global — that's also what lets [testing's auto_fake](testing.md) swap in a
fake per example.

## Dynamic mode

`GraphWeaver.parse` generates + evals in one step (no build artifact, evaled
into an anonymous container — no global constants leak). Same runtime
semantics; invisible to srb tc, so prefer the build step where static
checking matters. `GraphWeaver.execute(schema:, query:, variables: {})` is
the one-shot form.

Generated source is eval'd, so inputs are validated: module names must be
constant names, and query heredocs can't be terminated early. Still: queries
are code — don't feed untrusted strings to parse.
