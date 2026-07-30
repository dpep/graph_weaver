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

A supergraph SDL works as-is. When `SchemaLoader` sees the `@join__*` markers it
strips the composition machinery before building the schema — the synthetic
`join__*`/`link__*` types and directive definitions, and every `@join__*`/`@link`
application on the real types — so what codegen sees is the merged graph's
ordinary type shapes, with no federation plumbing leaking into `schema.types`.
(It's a pure AST rewrite of the SDL; no graphql-ruby monkeypatch, and plain
schemas pass through untouched.) Field shapes — nullability, args, enums,
inputs — are identical to the API schema, so your generated structs are correct;
and because codegen is **query-driven**, nothing federation-internal could
generate code anyway.

A supergraph is a **superset** of the API schema — it carries elements the
public API hides, marked `@inaccessible`. Weaver removes those on load (below),
so the schema it generates against is the API schema, not the superset.

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

Weaver derives the API schema from the supergraph for you: loading strips every
`@inaccessible` element and cascades — a field/argument/union-member/interface
referencing a removed type goes too, and a type left empty is removed in turn —
so codegen validates against **exactly** what clients can query. There's no
over-permit gap, and no need for Apollo's JS tooling (`@apollo/federation-internals`)
to subtract the API schema first; feed weaver the raw supergraph and you get the
router's contract. (This is a pure SDL rewrite at load time — see
[`SchemaLoader`](../lib/graph_weaver/schema_loader.rb).)

Other federation directives hide nothing from the schema, so weaver keeps the
field and ignores the directive: `@requiresScopes` / `@policy` / `@authenticated`
enforce access at runtime; `@tag` / `@requires` / `@provides` / `@external` are
metadata.

## Which schema to feed

Any of these — they all produce the same generated code:

- **The supergraph SDL** — weaver strips the `@join__*`/`@link` machinery and
  derives the API schema (removing `@inaccessible`). The common case.
- **The API schema SDL** — already subtracted (e.g. emitted in your CI); loads
  as an ordinary schema.
- **The live router** — introspect it; it already serves the API schema.

A large real supergraph carries more constructs than a toy one (interface
objects via `@join__type(isInterfaceObject:)`, `@join__unionMember`, enum join
directives). The stripping holds across them, but the honest check is to run
codegen against your actual composed schema plus a couple of representative
queries before relying on it.
