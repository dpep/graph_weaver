# Federation

Feed weaver any federation artifact: a supergraph, an API schema, a subgraph
SDL, or the live router. It recognizes which it got — `SchemaLoader.load` (and
`Client.new(path_or_sdl)`) take each as an SDL file or an introspection dump.

## Pointing weaver at a supergraph

A supergraph SDL works as-is. When `SchemaLoader` recognizes a composed graph it
strips the composition machinery before building the schema — the synthetic
`join__*`/`link__*` types and directive definitions, and every `@join__*`/`@link`
application on the real types — so what codegen sees is the merged graph's
ordinary type shapes, with no federation plumbing leaking into `schema.types`.
(It's a pure AST rewrite of the SDL; no graphql-ruby monkeypatch, and plain
schemas pass through untouched.) Field shapes — nullability, args, enums,
inputs — are identical to the API schema, so your generated structs are correct;
and because codegen is **query-driven**, nothing federation-internal could
generate code anyway.

**Which names count as machinery is read off the schema**, not a fixed list.
Federation namespaces itself through [`@link`](https://specs.apollo.dev/link/v1.0/)
(v2) or [`@core`](https://specs.apollo.dev/core/v0.2/) (v1), and weaver applies
those declarations as written: a spec URL's name segment gives the namespace
(`https://specs.apollo.dev/join/v0.3` → `join__`), `as:` renames it, and
`import:` binds names into the root namespace, `{name: "@key", as: "@myKey"}`
renames included. So a graph on fed 2.5+ auth strips its `@requiresScopes` /
`@policy` / `@context` machinery (`federation__Scope`, `context__ContextFieldValue`,
…) the same way `join__` goes, and a renamed `@inaccessible` still hides what it
marks. A schema that declares nothing still gets the `join__`/`link__`/`core__`
floor.

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

The directive is matched by the **local name it was linked under**, so
`@link(url: "…/federation/v2.5", import: [{name: "@inaccessible", as: "@private"}])`
subtracts what `@private` marks.

**Only on the supergraph path.** The subtraction runs when weaver recognizes a
composed supergraph. Plain SDL and subgraph SDL are taken at face value:
`@inaccessible` there is left as a directive and its fields stay queryable.

Other federation directives hide nothing from the schema, so weaver keeps the
field and ignores the directive: `@requiresScopes` / `@policy` / `@authenticated`
enforce access at runtime; `@tag` / `@requires` / `@provides` / `@external` are
metadata.

The derivation is diffed against Apollo's own `composeServices` +
`toAPISchema()` in
[`spec/integration/api_schema_spec.rb`](../spec/integration/api_schema_spec.rb),
over composed supergraphs carrying `@interfaceObject`, `@join__unionMember`,
`@join__enumValue` and an aliased `@inaccessible` — identical in each.

## Pointing weaver at a subgraph

A raw subgraph SDL — `rover subgraph fetch`, `_service { sdl }`, or the
`.graphql` in a service repo — loads too. It applies `@key`/`@external`/
`@shareable`/… without declaring them (federation v1 leaves them implicit, v2
imports them via `@link`, including under a namespace as
`@federation__key`), so weaver supplies the missing definitions on load;
anything the file declares itself wins. The federation directives themselves
generate no code — codegen is query-driven.

Reach for this when the subgraph is what you have, or to type an `_entities`
query (below). But a subgraph is one service's slice of the graph, and its
field shapes are not always the composed ones (an `@external` field is a
reference, not something that subgraph serves) — for a client of the whole
graph, feed the composed artifact.

### `_entities`

Every subgraph serves the entity resolver
`_entities(representations: [_Any!]!): [_Entity]!`, and **no subgraph SDL
contains it**: `_service { sdl }` and `rover subgraph fetch` print the
*published* schema, where the plumbing is implicit. A supergraph omits it
deliberately, and live introspection carries no `@key` to type it from. So
weaver supplies it on the subgraph path — `_Any`, `_Service`, and an `_Entity`
union over the file's own `@key`'d types — the same way it supplies the
`@key`/`@external` definitions. A file that declares its own keeps it.

The read side is a normal union selection; `alias:` turns the
single-entity case into a clean accessor (see [scalars.md](scalars.md)):

```ruby
GraphWeaver.extend_type("Query", alias: { entity: "_entities.first" }, optional: true)
```

The **input** side is generated. A representation must carry `__typename` and
satisfy one of the entity's `@key` field sets — both hard requirements of the
subgraph spec, and neither expressible in a bare `[_Any!]!`. So a query
selecting entities gets a `Representations` builder per entity it can resolve,
typed from the `@key` directives:

```ruby
UserQuery::Representations.user(id: "1")
# => {"__typename" => "User", "id" => "1"}

UserQuery.execute(reps: [UserQuery::Representations.user(id: "1")])
```

Key field sets are selection sets, so they're parsed as such:

| `@key(fields:)` | Builder |
|---|---|
| `"id"` | `Representations.user(id: "1")` |
| `"upc sku"` (compound) | `Representations.product(upc: "u", sku: 42)` |
| `"id organization { id }"` (nested) | `Representations.listing(id: "1", organization: { id: "o" })` |
| `"id"` **and** `"serial"` (alternatives) | `Representations.variant(id: "1")` *or* `(serial: "s")` |

A type with one `@key` types its fields as **required kwargs**, so an
incomplete representation is an `srb tc` error rather than a round trip. What a
sig can't say is checked at runtime and raises `GraphWeaver::InputError` naming
the type and the field: which of two alternative keys you meant to supply, and
whether a nested sub-hash carries the fields the key set declares. Only the
declared key fields reach the wire — an extra key in a nested hash is dropped.

Two bounds worth knowing. Builders are emitted **only for the entities a
query's `_entities` selection reaches** — codegen is query-driven, so a
subgraph with fifty entities emits nothing for the forty-nine you didn't name.
And a `@key(..., resolvable: false)` declares a key this subgraph does *not*
answer for, so it builds nothing. Key fields typed as scalars get their
registered Ruby type; anything else (a nested selection) is an open `Hash` the
runtime narrows.
