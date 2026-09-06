# Federation

GraphWeaver generates a client for the **whole** graph, so with Apollo
Federation you normally point it at the *composed* schema — the supergraph or
the API schema. A single subgraph's SDL loads too, for the cases where that's
what you have or what you mean.

## The schema you feed it

Three artifacts, easy to mix up:

| Artifact | What it is | Feed to weaver? |
|----------|------------|-----------------|
| **Subgraph SDL** | one service's `.graphql`, with `@key`/`@shareable`/`extend schema @link` | Yes, but it's one service's slice of the graph (see below) |
| **Supergraph** | the composed graph, annotated with `@join__*`/`@link` machinery | Yes — self-contained (see below) |
| **API schema** | the supergraph with federation internals stripped — exactly what the router serves and what an introspection query returns | Yes — the exact client contract |

`SchemaLoader.load` (and `Client.new(path_or_sdl)`) take any of them as an SDL
file or introspection dump; or point weaver at the router URL to introspect
the API schema live. For a client of the whole graph, use the composed
artifact — the supergraph or the API schema.

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

Federation **v1** supergraphs (`@core` + `@join__owner`/`@join__type`) load the
same way — the older spelling of the same machinery is stripped too.

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
referencing a removed type goes too, and a type left empty is removed in turn.
So codegen validates against what clients can query, with no over-permit gap
and no need for Apollo's JS tooling (`@apollo/federation-internals`) to
subtract the API schema first; feed weaver the raw supergraph and you get the
router's contract. (A pure SDL rewrite at load time — see
[`SchemaLoader`](../lib/graph_weaver/schema_loader.rb).)

What makes that subtraction *exact* is composition, not the cascade: Apollo's
`REFERENCED_INACCESSIBLE` rule already refuses to compose a supergraph where a
visible element references a hidden one, so on a real supergraph the cascade
has nothing left to find. It earns its keep on hand-written or hand-edited
supergraphs, where nothing has checked that invariant.

**Only on the supergraph path.** The subtraction runs when weaver recognizes a
composed supergraph. Plain SDL and subgraph SDL are taken at face value:
`@inaccessible` there is left as a directive and its fields stay queryable.

Other federation directives hide nothing from the schema, so weaver keeps the
field and ignores the directive: `@requiresScopes` / `@policy` / `@authenticated`
enforce access at runtime; `@tag` / `@requires` / `@provides` / `@external` are
metadata.

## Pointing weaver at a subgraph

A raw subgraph SDL — `rover subgraph fetch`, `_service { sdl }`, or the
`.graphql` in a service repo — loads too. It applies `@key`/`@external`/
`@shareable`/… without declaring them (federation v1 leaves them implicit, v2
imports them via `@link`, including under a namespace as
`@federation__key`), so weaver supplies the missing definitions on load;
anything the file declares itself wins. The federation directives themselves
generate no code — codegen is query-driven.

Reach for this when the subgraph is what you have, or to type an `_entities`
query: `_entities`/`_service` are deliberately absent from a supergraph, so a
subgraph SDL is the only artifact that describes them. But a subgraph is one
service's slice of the graph, and its field shapes are not always the composed
ones (an `@external` field is a reference, not something that subgraph serves) —
for a client of the whole graph, feed the composed artifact.

## Which schema to feed

Any of these — they all produce the same generated code:

- **The supergraph SDL** — weaver strips the `@join__*`/`@link` machinery and
  derives the API schema (removing `@inaccessible`). The common case. Federation
  v1 supergraphs (`@core`/`@join__owner`) work the same way.
- **The API schema SDL** — already subtracted (e.g. emitted in your CI); loads
  as an ordinary schema.
- **The live router** — introspect it; it already serves the API schema.

A large real supergraph carries more constructs than a toy one (interface
objects via `@join__type(isInterfaceObject:)`, `@join__unionMember`, enum join
directives). The stripping holds across them, but the honest check is to run
codegen against your actual composed schema plus a couple of representative
queries before relying on it.
