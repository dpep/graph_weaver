# Editor support: five lines of YAML

Your `.graphql` files are plain GraphQL documents and your schema dump is a
plain introspection result, so the whole JavaScript GraphQL editor toolchain
works on a Ruby repo — **with no JS project, no `package.json`, and no `npm
install`**. It just needs one config file telling it where the two live.

Ruby developers mostly don't know this, which is the only reason it's worth a
page.

## The file

```yaml
# graphql.config.yml — repo root
schema: app/graphql/schema.json
documents:
  - app/graphql/queries/**/*.graphql
  - app/graphql/fragments/**/*.graphql
```

That's the whole setup. The paths are graph_weaver's conventions
(`GraphWeaver.schema_path`, `queries_path`, `fragments_paths`) — if you moved
them, move these to match. Include the fragments directory: an editor
validating a query that spreads a shared fragment reports `Unknown fragment`
unless the fragment files are in `documents` too.

An SDL dump works just as well if you took one (`cache: :graphql`):

```yaml
schema: app/graphql/schema.graphql
```

Introspection JSON is read directly — graphql-config ships a JSON loader, so
`schema.json` needs no conversion step. graph_weaver also writes a
`graph_weaver` provenance key alongside the introspection result; if some tool
objects to it, point `schema:` at an SDL dump instead.

## What it buys you

The two editor plugins that read this file:

- **[vscode-graphql](https://marketplace.visualstudio.com/items?itemName=GraphQL.vscode-graphql)**
  (~2.8M installs) — its README states it **requires** a graphql-config file,
  which is why nothing works without the YAML above.
- **The JetBrains GraphQL plugin** (~6.1M downloads, bundled with recent
  RubyMine) reads the same file.

Either one gives you, inside a `.graphql` file:

- validation as you type — a typo'd field is red before you run anything
- field and argument autocomplete off the real schema
- go-to-definition and hover docs into schema types, including the
  descriptions the API author wrote

That is the same feedback the generator gives you, ~90 seconds earlier — you
find the typo while typing the query, not at `rake graph_weaver:generate`.

The same globs also feed the JS CI tools, if you want them (these *do* need
npm, unlike the editor path):
[graphql-inspector](https://the-guild.dev/graphql/inspector) `validate` and
[@graphql-eslint](https://the-guild.dev/graphql/eslint/docs) for lint rules
over your documents.

## What it doesn't buy you

**Nothing links a `.graphql` file to the Ruby it generates.** There is no
go-to-definition from a query field to its `T::Struct`, no rename that moves
both, no warning that a struct went unused. The editor plugin understands
GraphQL and Sorbet understands Ruby, and no tool in any ecosystem bridges the
two except where documents and types share a single language service.

So the division of labour is:

| Question | Answered by |
|---|---|
| Is this query valid, right now, as I type it? | the editor plugin |
| Do the result types match the query? | `rake graph_weaver:generate` + `srb tc` |
| Is my checked-in Ruby stale? | `rake graph_weaver:verify` |
| Did the server break my queries? | `rake graph_weaver:queries:check` |

The last two are the Ruby-side answers, and they need no JS at all — see
[getting started](getting_started.md#5-verify-in-ci).
