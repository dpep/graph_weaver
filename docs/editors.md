# Editor support: five lines of YAML

Your `.graphql` files are plain GraphQL documents and your schema dump is a plain
introspection result, so the whole JavaScript GraphQL editor toolchain works on a
Ruby repo — **with no JS project, no `package.json`, and no `npm install`**. It
just needs one config file telling it where the two live. Ruby developers mostly
don't know this, which is the only reason it's worth a page.

```yaml
# graphql.config.yml — repo root
schema: app/graphql/schema.json
documents:
  - app/graphql/queries/**/*.{graphql,gql}
  - app/graphql/fragments/**/*.{graphql,gql}
```

That's the whole setup, and `rails g graph_weaver:install` writes it. The paths
are graph_weaver's conventions (`GraphWeaver.schema_path`, `queries_paths`,
`fragments_paths`) — if you moved them, move these to match. Include the
fragments directory: an editor validating a query that spreads a shared fragment
reports `Unknown fragment` unless the fragment files are in `documents` too. The
generator writes that line whether or not you have fragments yet, and a glob
matching nothing is fine.

Introspection JSON is read directly — graphql-config ships a JSON loader, so
`schema.json` needs no conversion step. An SDL dump works just as well if you
took one (`cache: :graphql`): point `schema:` at `app/graphql/schema.graphql`.
graph_weaver also writes a `graph_weaver` provenance key alongside the
introspection result; if some tool objects to it, use the SDL dump instead.

## What it buys you

Two editor plugins read this file:
**[vscode-graphql](https://marketplace.visualstudio.com/items?itemName=GraphQL.vscode-graphql)**,
whose README states it **requires** a graphql-config file — which is why nothing
works without the YAML above — and **the JetBrains GraphQL plugin**, bundled with
recent RubyMine. Either one gives you, inside a `.graphql` file:

- validation as you type — a typo'd field is red before you run anything
- field and argument autocomplete off the real schema
- go-to-definition and hover docs into schema types, including the descriptions
  the API author wrote

That is the same feedback the generator gives you, one round trip earlier — you
find the typo while typing the query, not at `rake graph_weaver:generate`. The
same globs also feed the JS CI tools, if you want them (these *do* need npm,
unlike the editor path): [graphql-inspector](https://the-guild.dev/graphql/inspector)
`validate` and [@graphql-eslint](https://the-guild.dev/graphql/eslint/docs) for
lint rules over your documents.

## What it doesn't buy you

**Nothing links a `.graphql` file to the Ruby it generates.** There is no
go-to-definition from a query field to its `T::Struct`, no rename that moves both,
no warning that a struct went unused. The editor plugin understands GraphQL and
Sorbet understands Ruby, and no tool in any ecosystem bridges the two except
where documents and types share a single language service.

So the division of labour is:

| Question | Answered by |
|---|---|
| Is this query valid, right now, as I type it? | the editor plugin |
| Do the result types match the query? | `rake graph_weaver:generate` + `srb tc` |
| Is my checked-in Ruby stale? | `rake graph_weaver:verify` |
| Did the server break my queries? | `rake graph_weaver:queries:check` |

The last two are the Ruby-side answers, and they need no JS at all — see
[getting started](getting_started.md#5-verify-in-ci).
