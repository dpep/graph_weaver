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

## Open questions

- Can the wrapper-class generation layer (`GraphQL::Client::Schema.generate`) be swapped/extended to emit our own classes directly, instead of hydrating afterwards?
- Sorbet codegen: derive `T::Struct` definitions per query from `Query#schema_class` / the selection AST — what does prior art look like?
- How do fragments map onto wrapper classes (they generate separate modules that structs would need to compose)?
