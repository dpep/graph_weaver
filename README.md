graphql-client exploration
======

Scratch repo exploring how [graphql-client](https://github.com/github-community-projects/graphql-client)
deserializes responses, and how to hydrate results into custom Ruby classes
(including Sorbet `T::Struct`s).

The specs are the documentation — each one asserts an observed behavior:

```
bundle exec rspec
```

## Findings so far

- The client runs fine against an in-process schema: `GraphQL::Client.new(schema: Schema, execute: Schema)` — no HTTP involved.
- Each query selection gets its own dynamically generated wrapper class (subclass of `GraphQL::Client::Schema::ObjectClass`); fields are snake_case readers, and unselected fields raise instead of returning nil.
- **Custom scalars are deserialized automatically** when the client is built from a live schema class: the reader casts wire values through the scalar's `coerce_input` (e.g. `"1990-06-15"` → `Date`). This is the built-in hook for producing rich Ruby values.
  - Caveat: this only works with `schema:` as a live schema class. A schema loaded from an introspection JSON dump has no coercion logic, so scalars would stay raw.
- `to_h` returns the raw wire values (strings), not the casted ones — hydration code should read via the typed readers, not `to_h`.
- Hydrating into `T::Struct`s is straightforward manually; the interesting next step is generating the structs (or a generic hydrator) from the parsed query definition, since the client already knows each selection's shape and types.

## Swapping the class-generation layer (answered: yes)

`lib/struct_types.rb` + `spec/struct_types_spec.rb` prove the generation layer
can be replaced wholesale — the client deserializes straight into generated
`T::Struct`s, no `ObjectClass` involved.

How the pipeline hangs together (graphql-client 0.26.0):

- `Client#initialize` builds the types module: `@types = Schema.generate(schema)`
  (`attr_reader :types`, no setter — swap via `instance_variable_set` or a subclass).
- `Client#parse` → `Definition#initialize` calls
  `client.types.define_class(definition, ast_nodes, type)` and stores the result
  as `definition.schema_class`. This is the ONLY thing the client asks of the
  types module.
- `Client#query` → `definition.new(data, errors)` → `schema_class.new(data, errors)`.
- Everything below that is the `cast(value, errors)` protocol, composed
  recursively per the query selection (NonNull/List wrappers, scalars, objects).

So the replacement contract is just:
- `define_class(definition, ast_nodes, type)` returning casters
- casters respond to `cast(value, errors)`
- the top-level caster must satisfy `Definition#new`'s case dispatch, which
  tests `===` against the `GraphQL::Client::Schema::ObjectType` module —
  including that module in your caster class is enough, plus a
  `new(data, errors)` method

Gotchas found:
- the client injects `__typename` into every selection (`QueryTypename`), so a
  custom generator must skip/handle `__`-prefixed fields
- scalar casting reuses the schema type's `coerce_isolated_input` — same hook
  the stock `ScalarType` uses
- prop nullability comes for free from the type walk: everything is
  `T.nilable` unless wrapped in NON_NULL

## Sorbet

- `sorbet` + `tapioca` are set up (`bundle exec srb tc` is green); rbis in `sorbet/rbi/gems`
- `struct_types.rb` typechecks at `# typed: true`
- generated structs are real `T::Struct`s: schema-derived prop types
  (`T.nilable(Date)`, `T::Array[StructTypes::Pet]`) and runtime type
  enforcement on bad wire data

## Codegen: srb tc sees query result types (answered: yes)

`lib/struct_codegen.rb` goes one step further than the runtime swap: it
emits plain `# typed: strict` Ruby source from a query + schema — nested
`T::Struct` classes, fully generated `from_h` casting code (no runtime
reflection), and a sig'd `execute`.

- source of truth: `queries/*.graphql`; regenerate with `bin/generate`
  into `lib/generated/`; a spec asserts the checked-in output is current
- queries are validated against the schema at generation time
- `srb tc` statically checks result access end to end:
  `result.person&.nmae` → `Method nmae does not exist on
  PersonQuery::Result::Person`
- custom scalar deserialization is inlined by the generator
  (`Date.iso8601(...)`) via a scalar registry; nullability and list
  casting come from the NON_NULL/LIST walk
- note: generated `execute` runs against the schema directly, replacing
  graphql-client at runtime entirely — the client's remaining value here
  would be its HTTP adapter, which the generated code could target instead

## Fragments & unions (answered for codegen)

`queries/search.graphql` + `lib/generated/search_query.rb` exercise the
design:

- inline fragments and named fragment spreads are flattened into their
  matching member's selection (exact type-name condition match; interface
  conditions still open)
- unions emit a module per selection site: one `T::Struct` per possible
  type, a `Type = T.type_alias { T.any(...) }`, and a `from_h` that
  dispatches on `__typename` — codegen refuses union selections that
  don't select `__typename`
- every possible type gets a member struct even without a fragment (it
  still carries `__typename`), so dispatch is total

## Introspection / __type metadata

- `__type` / `__schema` queries work against the demo schema as expected
  (see `spec/introspection_spec.rb` for the shapes)
- the key result: `GraphQL::Schema.from_introspection(Demo::Schema.as_json)`
  produces a schema that codegen runs against **byte-identically** — so
  generation works for remote APIs known only via an introspection dump.
  Custom scalar handling survives because the codegen scalar registry is
  keyed by type *name*, unlike runtime `coerce_input` which needs the live
  schema class (the caveat that broke graphql-client's scalar casting)

## Federation / supergraph

- join__/link-annotated supergraph SDL parses via
  `GraphQL::Schema.from_definition`, and codegen runs against it
  unchanged — the directives are transparent to result typing
  (`spec/federation_spec.rb` generates from a mini supergraph and casts a
  response with no live subgraphs)
- gotcha: graphql-ruby's SDL builder does not apply directive-argument
  defaults, so real Apollo `join v0.3` SDL (non-null defaulted args like
  `extension: Boolean! = false`) fails to load unless those args are
  provided or the directive defs are trimmed — a compatibility issue a
  real tool would need to patch around
- client-side, federation needs nothing more: you query the router like
  any schema. The *server-side* angle (emitting `@key`/`@external` via
  apollo-federation) is a separate exploration — potentially relevant to
  autographql

## Round 2: enums, interface conditions, loaders, dynamic mode, HTTP

- **enums** generate `T::Enum` classes (`Species::Dog`), deserialized via
  `Species.deserialize(...)` in `from_h`; values sorted so output is
  deterministic across schema sources
- **interface fragment conditions** (`... on Named { name }`) apply via
  `schema.possible_types`, not just exact type-name match. Interface-typed
  *fields* (a field returning `Named`) are still open — they'd emit like
  unions with `__typename` dispatch
- **SchemaLoader** accepts both formats a remote service can hand you:
  introspection dump (`.json`) or SDL (`.graphql`/`.gql`); both generate
  byte-identically to the live schema class
- **dynamic mode**: `StructCodegen.load(...)` generates + evals in one
  step — no build artifact, same runtime semantics, right for development
  or one-off scripts. Tradeoff: the module is invisible to `srb tc`, so
  static checking of result access needs the build step
- **HTTP transport**: generated `execute` takes `executor:` — anything
  with `execute(query, variables:)` returning `{"data" => ...}`.
  `HttpExecutor` (Net::HTTP POST) runs the same generated structs against
  a live server (`spec/http_spec.rb` proves it against a local WEBrick
  serving Demo::Schema)
- **directive defaults gap**: root cause found —
  `BuildFromDefinition#prepare_directives` passes only usage-site args
  while `Directive#initialize` validates all defined args without
  applying `default_value`. `lib/directive_defaults_patch.rb` prepends
  the fix; the federation spec now loads the *real* join v0.3 SDL.
  Present in graphql 2.6.3 (latest) — worth an upstream issue/PR

## Open questions

- interface-typed fields (vs fragment conditions, which work)
- name collisions: the generator disambiguates one level (field-name
  prefix) and raises otherwise. A real gem needs a *stable* naming scheme:
  names shouldn't shift when unrelated selections are added (generated
  code is checked in and referenced by app code), which argues for
  path-based or explicitly-aliased names over first-come-first-served
- mutations/subscriptions (only query operations generate)
