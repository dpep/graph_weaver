# Federation

GraphWeaver generates a client for the **whole** graph, so with Apollo
Federation you point it at the *composed* schema — the supergraph or the API
schema — not at individual subgraph files.

## The schema you feed it

Three artifacts, easy to mix up:

| Artifact | What it is | Feed to weaver? |
|----------|------------|-----------------|
| **Subgraph SDL** | one service's `.graphql`, with `@key`/`@shareable`/`extend schema @link` | No — it's a fragment of the graph, and its federation directives are declared elsewhere (imported via `@link`), so plain SDL loading rejects them |
| **Supergraph** | the composed graph, annotated with `@join__*`/`@link` machinery | Yes — self-contained (see below) |
| **API schema** | the supergraph with federation internals stripped — exactly what the router serves and what an introspection query returns | Yes — the exact client contract |

`SchemaLoader.load` (and `Client.new(path_or_sdl)`) take the supergraph or the
API schema as an SDL file or introspection dump; or point weaver at the router
URL to introspect the API schema live.

## Pointing weaver at a supergraph

A supergraph SDL works as-is. It declares its own `@join__*`/`@link` directives
and `join__*` types, so graphql-ruby builds it; weaver reads field types and
args, not directives, so the join plumbing is ignored; and because codegen is
**query-driven**, the federation-internal types generate no code unless a query
names them (none would). Field shapes — nullability, args, enums, inputs — are
identical to the API schema, so your generated structs are correct.

The one caveat: a supergraph is a **superset** of the API schema, so weaver can
only ever **over-permit** — it will never reject a valid query, but it won't
flag one that selects a field the API *hides*. In practice that's exactly one
thing: `@inaccessible`.

### `@inaccessible`

A federation-v2 directive marking an element as *present in the federated graph
but removed from the public API schema*. Its common use is safely rolling out a
change to a **shared type**: add the field to one subgraph marked
`@inaccessible` (so composition doesn't require every subgraph to have it yet),
roll it out to the rest, then drop the directive to publish it. (Apollo
contracts also pair `@tag` + `@inaccessible` to build filtered API variants.)
It's a fed-v2 feature — common in mature, multi-team graphs with lots of shared
types, rare in small or young ones, and targeted where present (a handful of
elements, not every field).

Reading the raw supergraph, weaver would let you select an `@inaccessible`
field — but the router serves the API schema and rejects it at runtime (a
"field doesn't exist" error, surfaced as [`QueryError` / `schema_stale?`](errors.md)).
So the gap is narrow (you'd have to query a hidden field on purpose) and fails
loudly, not silently.

One grep says whether it affects you at all:

```sh
grep -c '@inaccessible' supergraph.graphql
```

Zero, and the supergraph *is* the API schema for weaver's purposes — feed it
directly.

Other federation directives hide nothing from the schema:
`@requiresScopes` / `@policy` / `@authenticated` keep the field and enforce
access at runtime; `@tag` / `@requires` / `@provides` / `@external` are metadata
weaver ignores.

## The exact contract: the API schema

To make codegen match the router precisely (no over-permit), feed weaver the
**API schema** instead of the raw supergraph. Deriving it is a *subtraction*
from the composed graph — not composition — done with Apollo's tooling:

```sh
rover supergraph compose --config supergraph.yaml > supergraph.graphql
```

```js
// then, in JS, strip to the API schema:
import { Supergraph } from '@apollo/federation-internals';
import { printSchema } from 'graphql';

const api = Supergraph.fromString(supergraphSdl).apiSchema().toGraphQLJSSchema();
process.stdout.write(printSchema(api));   // api.graphql — feed this to weaver
```

Check the API SDL in (many teams already emit it in CI) and point weaver at it:
codegen then validates against exactly what clients can query, with no live
gateway involved.

## Which to use

- **No `@inaccessible`** → point weaver at the supergraph and move on.
- **Uses `@inaccessible`, and you want codegen to catch hidden-field mistakes** →
  feed the derived API schema (above), or introspect the live router.

A large real supergraph carries more constructs than a toy one (interface
objects via `@join__type(isInterfaceObject:)`, `@join__unionMember`, enum join
directives). The mechanism holds, but the honest check is to run codegen against
your actual composed schema plus a couple of representative queries before
relying on it.
