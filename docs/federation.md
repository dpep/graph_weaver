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

The table is what [`Testing::Router`](#the-local-router)
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
gone), and [faked](#the-local-router). A clean report that quietly checked two
of four subgraphs would be actively misleading, so the headline counts them and
the sections name them. Only drift fails the task; absence is a supported
setup, not a failure.

Detection is what drift breaks — a schema is recognized by what it defines,
and a subgraph whose *types* are gone stops being recognizable — so the same
`subgraphs:` map [`Testing::Router`](#the-local-router)
takes is accepted here, and a named schema skips detection:

```ruby
GraphWeaver::Federation::Drift.new(
  supergraph: "supergraph.graphql",
  subgraphs: { "products" => Products::Schema, "inventory" => :fake },
).report
```

`#to_h` is the JSON-ready `{"stale" => …, "uncomposed" => …, "skipped" => …,
"faked" => …}`, and `#drift?` is what the task exits on.

## The local router

Specs for a federated app have a bad choice: fake the whole graph, or boot a
gateway. `Testing::Router` is the third one. It takes the composed supergraph
and the Ruby schema classes serving its subgraphs, plans the query, and
satisfies the [client contract](transports.md) — so a generated module runs
against your **real resolvers**, in-process, with no gateway, no node and no
sockets. It is not a mock: your resolvers run, which is the whole point.

```ruby
GraphWeaver.client = GraphWeaver::Testing::Router.new(
  supergraph: Rails.root.join("supergraph.graphql"),
  context: { current_user: user },
)
```

In rspec that's the [`graphql: :router`](testing.md#a-federated-graph--graphql-router)
tag and there is nothing to pass — the tag builds it, once for the suite.
`router.trace` records the fetches one `execute` made, in order (subgraph,
query, variables); the same lines go to `GraphWeaver.logger` at `:debug`.

**[`examples/federation.rb`](../examples/federation.rb)** is the whole shape
in one runnable file, and the only example that needs no network: three real
subgraphs, a boundary-crossing query through a generated module, the trace,
and a refusal. [`spec/router_spec.rb`](../spec/router_spec.rb) is the
exhaustive reference — every plan shape, every refusal, the partly-local
graph and the `:fake` opt-in, each as a named example.

### Which schema serves which subgraph

`subgraphs:` is optional. Left out, each one is **derived from what the loaded
schemas define**: a schema serves subgraph `s` when it defines every type and
field the routing table says `s` resolves. That's evidence rather than a guess —
matching on class names would be one, and a wrong guess points a suite at the
wrong resolvers and still passes. So exactly one match is used, and **two**
matches refuse, naming both. **No** match isn't a refusal: that subgraph is
simply served somewhere else (next section).

Name them yourself when you'd rather have the wiring committed, or when
detection can't settle it — including partially, with the rest derived:

```ruby
subgraphs: { "accounts" => Accounts::Schema }   # products, reviews derived
```

Either way the map is **checked** at construction, so a swapped pair fails
naming what's missing rather than surfacing as a mystery three fetches later:

```
subgraphs["accounts"] is Products::Schema, which doesn't define Query.me,
Query.user, Query.users, User, User.email and 1 more — the supergraph says
accounts resolves them. Did two entries get swapped?
```

Detection only sees what's **loaded**, and in Rails an autoloaded schema isn't
until something references it — which is why an unmatched subgraph reads as
absent. To see what detection sees, and get a map to paste:

```
$ rake graph_weaver:federation:subgraphs SUPERGRAPH=supergraph.graphql
subgraphs: {
  "accounts" => Accounts::Schema,  # matched: defines Query.me, Query.user, Query.users
  "products" => Products::Schema,  # matched: defines Product.name, Product.price, Product.weight
  "reviews" => Reviews::Schema,    # matched: defines Product.reviews, Product.shippingEstimate, Query.feed
}
```

A row nothing matched comes back `nil`, naming the coordinates it looked for —
that's the map to fill in, or the subgraph that lives elsewhere.

### A supergraph only partly local

The usual migration shape: the supergraph is composed from several services and
only **some** of them run in your process. The rest are routed over the network,
so there is no Ruby schema here to serve them — and requiring one would refuse
the whole suite over fields most of your queries never touch.

So a subgraph nothing here defines is **absent**, and the router builds and runs
anyway. Absence costs you exactly the queries that reach into it:

```ruby
router.absent                                            # => ["shipping"]
router.execute("{ me { username reviews { body } } }")   # real data, as always
router.execute("{ shipments { carrier } }")              # GraphWeaver::Testing::Unplannable
```

That refusal is a plan-time one like every other, so nothing has executed when
it raises, and it names the subgraph, the field that reached for it, and both
ways out — name a schema for it, or fake it:

```ruby
subgraphs: { "shipping" => :fake }   # billing, being absent, still refuses
```

If the subgraph *is* here and detection just couldn't see it — a Rails schema
class nothing has referenced yet — naming it is the fix. `=> :fake` is the
other one: mid-migration, letting an absent subgraph answer with
schema-correct fabricated data exercises the rest of the query. It speaks the
whole subgraph contract, `_entities(representations:)` included, so it works
under a stitched fetch as well as at a root field.

Refusing stays the default, and the opt-in is **per subgraph** on purpose:
silently substituting invented data is the failure mode this library keeps
designing against. For the same reason faking is **loud** — every faked fetch
is marked `faked: true` in `router.trace` and logged at `:warn`.
`router.faked` lists them, and `router.inspect` shows what's served, faked and
absent. Values come from the same engine as
[`graphql: :fake`](testing.md#fabricated-data--graphql-fake), so `config.seed`,
`config.overrides` and the rest apply.

### What it plans

An operation that resolves in **one subgraph** goes over verbatim. One that
**crosses a boundary** is split at the crossing: the plan injects the entity's
`@key` under a reserved alias, refetches it from the owning subgraph through
`_entities(representations:)`, and stitches the answer back. Every node at one
level goes in **one** `_entities` call, so a list of users and all their
reviews' products is three fetches, not one per row. Root fields that resolve
in different subgraphs get one fetch each. A `@provides` copy is read in place,
so nothing leaves the subgraph for a field the copy already holds.

A **`@requires` field set** is supplied by the router rather than by the
subgraph that declares the field, so it's a fetch before the fetch:

```ruby
router.execute("{ reviews { product { shippingEstimate } } }")
router.trace.map { _1[:subgraph] }   # => ["reviews", "products", "reviews"]
```

`shippingEstimate` resolves in `reviews` and `@requires "price weight"`, which
`products` owns — so the plan fetches those into hidden keys, hands them back
in the representation, and only then asks for the estimate. One hop only: the
key for the first fetch has to come from the subgraph already in hand, so a
chain can't grow a chain.

Three things it does that a naive merge doesn't, and that being wrong about
would be worse than refusing:

- **Null propagation over the merged tree.** A stitched fetch can put a null
  where the composed schema says non-null, and no subgraph is in a position to
  notice. The router re-applies GraphQL's propagation rules to the merged
  result, so a subtree the real router would have nulled comes back null here.
- **Error re-pathing.** A subgraph reports `_entities.2.shippingEstimate`; you
  get `topProducts.2.shippingEstimate`. `locations` are dropped rather than
  pointing into a query you never wrote.
- **`@skip`/`@include` on a stitched field.** A skipped field comes back
  *absent*, not null.

Introspection is answered from the composed API schema, never from a subgraph,
which would reply with its own slice — the one split a real router also makes.

### What it refuses

Everything it can't plan **faithfully** raises
`GraphWeaver::Testing::Unplannable` (a `GraphWeaver::Error`), at plan time,
before any subgraph runs — so a refusal is never a half-executed query.
Apollo's planner is ~20k lines; a double that approximated the rest of it would
let a test pass on an answer production disagrees with, which is the most
expensive thing this library can produce. Each refusal names the coordinate
that stopped it and what to do — `examples/federation.rb` prints one.

What's left, and why:

| Refusal | Why |
|---|---|
| an alias shadowing an injected `@key` | Apollo's router lets its injected key win over your alias and a spec-conformant server doesn't — there is no one answer to agree with |
| an abstract type at a boundary | a representation names one concrete `__typename`, and the router doesn't resolve a type per object to build one |
| a nested `@key`/`@requires` field set | representations are built from flat field sets only |
| no usable `@key` | nothing to build a representation from |
| a mutation whose root fields span subgraphs | root mutation fields run in series, and splitting them would run them in whatever order the plan happened to (query roots are independent, so those are fine) |
| a subgraph nothing here serves | it's served by another process, so there is nothing here to ask — unless you fake it (above) |

It also refuses at construction, before a single query, a supergraph carrying
a `@join__*` construct the routing table hasn't been taught — an incomplete
table makes every answer a guess — and a subgraph two loaded schemas both fit
(above).

### Is it worth wiring up? Measure.

The router's value is one number — the fraction of *your* queries it can plan —
and that depends on the shape of your graph and of your queries, so measure it
rather than guess:

```
$ rake graph_weaver:federation:coverage SUPERGRAPH=supergraph.graphql
17/17 queries plannable locally (100%)
  accounts 4, reviews 4, products+reviews 3, accounts+reviews 2, products 2, accounts+products 1, accounts+products+reviews 1

refused (0)
```

`QUERIES=` picks the directory (default `GraphWeaver.queries_path`). Planning
needs the supergraph and nothing else, so this runs in CI with the SDL alone —
no subgraph has to be loadable. The second line says which subgraphs each query
touches, so a graph whose queries all sit in one is visibly a different
situation from one that stitches everywhere; the reasons group by category, so
one glance says whether the gap is one construct or many. The run above is
against the demo graph in `spec/support/federation`, not a real app's mix.

### How the refusals are kept honest

A double that quietly answered *differently* from the router would be worse
than no double at all, so
[`spec/integration/router_parity_spec.rb`](../spec/integration/router_parity_spec.rb)
serves the demo subgraphs over HTTP, boots a real `@apollo/gateway` on the same
supergraph, and runs every corpus query through both. Three outcomes, one of
them a defect: match, refuse, or answer differently. On 43 queries — the corpus,
twenty boundary probes, and five where a subgraph deliberately fails — the local
router is byte-identical to the gateway on 42, refuses 1, and is wrong on none.
It also checks that the gateway answers every refusal cleanly, so each is a
capability gap rather than a broken query. `make integration` runs it (node
required).

The five deliberate failures are the ones that matter most: a resolver erroring
under a stitched fetch, an entity nothing can resolve, a `@requires` fetch that
comes back empty. Each is a case where a merge that doesn't re-propagate hands
back a populated tree while the real router answers `data: null` — so it is
checked against the real thing rather than against an expectation someone wrote
down.

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
