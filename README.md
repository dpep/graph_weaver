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

## Open questions

- fragments and interfaces/unions: the spike only handles plain field
  selections; fragment spreads gather via `WithDefinition` spreads and unions
  dispatch on `__typename` — both need design for a struct emitter
- static typing of query results: the structs exist only at runtime; getting
  `srb tc` to see them per query needs codegen (tapioca-style DSL compiler
  that parses `.graphql` files / Client.parse calls and writes rbi or
  concrete struct definitions to disk)
