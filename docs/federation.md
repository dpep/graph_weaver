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

### The routing table

Stripping the machinery answers "what does this graph look like". The other
question a supergraph answers is "who resolves what", and
`SchemaLoader.routing_table` keeps that side rather than discarding it:

```ruby
table = GraphWeaver::SchemaLoader.routing_table("supergraph.graphql")

table.subgraphs                                # => ["accounts", "products", "reviews"]
table.owners("Product", "shippingEstimate")    # => ["reviews"]
table.owners("User", "username")               # => ["accounts"] — the @external copy isn't an owner
table.keys("User", "accounts")                 # => [["id"]]
table.field("Product", "shippingEstimate").requires  # => "price weight"
```

Subgraphs are named the way `@join__graph(name:)` names them — the strings a
router config and `rover` use, not the SDL's uppercase enum spelling. A `@key`
field set comes back as dotted paths (`"id organization { id }"` → `["id",
"organization.id"]`), so a nested one is recognizable by its shape. A field
with no `@join__field` at all lives wherever its type does; that omission is
how the composer says "everywhere".

A `@join__` directive the table hasn't been taught lands in `#unsupported`
rather than being skipped — a table that silently ignores half a spec version
answers confidently and wrongly. Callers refuse on a non-empty list; that is
what bounds the maintenance tail across federation spec versions.

The table is what [`Testing::Router`](testing.md#the-in-process-router--graphql-router)
plans against, and it's a reasonable read on its own — "which subgraph owns
this field" is the sentence a good error message wants.

Weaver says it where it has the coordinate to say it about. When the schema
dump is a composed supergraph, `rake graph_weaver:queries:check` brands each
validation error with the subgraphs behind the type it names:

```
app/graphql/queries/product.graphql
  4:5  Field 'dimensions' doesn't exist on type 'Product' (products, reviews)
```

`Product.dimensions` says what broke; `(products, reviews)` says whose code to
look at. `check_queries` carries the same list as a `"subgraphs"` key. A plain
schema has no routing table, so nothing changes for it.

### Has the supergraph been recomposed?

A committed supergraph is a snapshot of a composition. Change a subgraph and
skip the recompose and it quietly describes a graph that no longer exists —
the failure that bites a federated app mid-migration, and the one the other
checks don't ask about. `graph_weaver:verify` asks whether the generated Ruby
is fresh, `schema:diff` whether the *server* has drifted from your dump,
`queries:check` whether drift broke a query. This asks whether the supergraph
still describes your subgraphs:

```sh
rake graph_weaver:federation:diff SUPERGRAPH=supergraph.graphql
```

It reads the routing table and the subgraph schemas loaded in this process —
**no network** — so it belongs in the normal PR run, and it exits non-zero on
drift so CI can gate on it:

```
supergraph.graphql: 1 stale, 1 not composed in (checked 2 of 4 subgraphs)

stale — the supergraph carries these, no schema here defines them (recompose):
  Product.weight (products)

not composed in — a schema here defines these, the supergraph doesn't carry them:
  Product.dimensions (Products::Schema)

not checked — nothing here defines what the supergraph says these declare
(running elsewhere, or the type is gone):
  inventory (Warehouse)

not checked — answered with fabricated data:
  reviews
```

Both directions, because they mean opposite things: **stale** is "recompose",
**not composed in** is "publish the subgraph". The stale side names the
subgraph the supergraph blames, which is the sentence you want — whose code to
look at, whose team to talk to.

What counts as "defines" is deliberately looser than field-set equality, which
would be wrong in both directions: a subgraph carries federation plumbing
(`_entities`, `_service`) no supergraph has, and a field can legitimately sit
in more than one subgraph (`@external` copies, `@shareable`). So a coordinate
is compared only against the schemas that could *be* the subgraph the
supergraph attributes it to — the ones defining every non-root type it
declares — the uncomposed side reports only a field the supergraph's type
doesn't carry **at all** (not one it merely attributes elsewhere), and
underscore-prefixed fields never count.

**A supergraph is routinely only partly local**, so the report names three
states rather than two: checked, not here (running elsewhere — or the type is
gone), and [faked](testing.md#the-in-process-router--graphql-router). You can't compare
against what isn't here, and saying nothing about it is right — but a clean
report that quietly checked two of four subgraphs would be actively
misleading, so the headline counts them and the sections name them. Only drift
fails the task; absence is a supported setup, not a failure.

Detection is what drift breaks — a schema is recognized by what it defines,
and a subgraph whose *types* are gone stops being recognizable — so the same
`subgraphs:` map [`Testing::Router`](testing.md#the-in-process-router--graphql-router)
takes is accepted here, and a named schema skips detection:

```ruby
GraphWeaver::Federation::Drift.new(
  supergraph: "supergraph.graphql",
  subgraphs: { "products" => Products::Schema, "inventory" => :fake },
).report
```

`#to_h` is the JSON-ready `{"stale" => …, "uncomposed" => …, "skipped" => …,
"faked" => …}`, and `#drift?` is what the task exits on.

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
single-entity case into a clean accessor (see
[flat accessors](generated_modules.md#flat-accessors-with-alias)):

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
