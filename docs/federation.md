# Federation

For an app that is a client of a federated graph, a subgraph in one, or both.
Two halves: **generating** against a composed supergraph (which mostly means
"point it at the file and forget"), and the **local router**, which runs a
stitched query against your own resolvers in-process so specs need no gateway.

GraphWeaver takes any federation artifact — a supergraph, an API schema, a
subgraph SDL, or a live router — and recognizes which it got.
`SchemaLoader.load` (and `Client.new(path_or_sdl)`) accept each as an SDL file
or an introspection dump.

## Generating for a federated graph

**Queries go through the gateway?** Generate against the supergraph. It is the
whole graph in one schema, so every registration matches and there is nothing
else to decide.

**Calling subgraphs directly?** One graph per subgraph, declared once:

```ruby
GraphWeaver.graph :billing do
  schema    "billing.graphql"
  queries   "app/graphql/billing"
  output    "app/graphql/generated/billing"
  namespace "Billing"
  register_scalar "Money", Money
end

GraphWeaver.graph :directory do
  schema    "directory.graphql"
  queries   "app/graphql/directory"
  output    "app/graphql/generated/directory"
  namespace "Directory"
  register_scalar "Person.birthday", Date
end
```

One `rake graph_weaver:generate` generates both, and each subgraph is held only
to the registrations declared for it. (Naming a live subgraph *class* from a
Rails initializer takes a lambda — `schema -> { Billing::Schema }` — see
[getting started](getting_started.md#more-than-one-schema).)

Registrations made at the *top* level still reach every graph, because names
compose by identity across a graph — `Money` is one Ruby type wherever it
appears, and `Person` is one entity even though a single subgraph owns
`birthday`. So a registration a given subgraph doesn't declare is not an error;
generation warns and carries on. `rake graph_weaver:generate` and `verify` print
the list once per run, after the files:

```
register_scalar("Money") matches no scalar in Billing::Schema — a typo, or a registration for another schema
```

`GraphWeaver.unmatched_registrations` is that same list as data, for a Rakefile
or a spec that would rather gate on it than read it. Moving a registration into
the graph block that needs it is what makes those lines go away.

This holds for entity fields too, which is the case that would otherwise bite:
every subgraph referencing an entity declares it, so a subgraph carrying
`Person` for its `@key` alone sees a top-level
`register_scalar("Person.birthday", Date)` as a field it doesn't own — a
warning, not a failure.

What a subgraph *can* disprove still fails generation: a name it declares as
something else (`register_scalar("Species")` where `Species` is an enum), and a
coordinate whose field it declares as a composite. Neither is redeemable by any
schema in the graph.

## Generating against a supergraph

A supergraph SDL works as-is. On load, GraphWeaver strips the composition
machinery — the synthetic `join__*`/`link__*` types and directive definitions,
and every `@join__*`/`@link` application on the real types — so codegen sees the
merged graph's ordinary type shapes with no federation plumbing in
`schema.types`. Field shapes (nullability, args, enums, inputs) are identical to
the API schema, so your generated structs are correct.

**Which names count as machinery is read off the schema**, not a fixed list.
Federation namespaces itself through [`@link`](https://specs.apollo.dev/link/v1.0/)
(v2) or [`@core`](https://specs.apollo.dev/core/v0.2/) (v1), and those
declarations are applied as written: the spec URL's name segment gives the
namespace (`https://specs.apollo.dev/join/v0.3` → `join__`), `as:` renames it,
`import:` binds names into the root namespace. So a fed 2.5+ graph's
`@requiresScopes` / `@policy` / `@context` machinery strips the same way
`join__` does, a renamed `@inaccessible` still hides what it marks, and v1
supergraphs (`@core` + `@join__owner`) load identically. A schema that declares
nothing still gets the `join__`/`link__`/`core__` floor.

### `@inaccessible`

A supergraph is a **superset** of the API schema: it carries elements the public
API hides, marked `@inaccessible`. You'll meet the directive rolling out a change
to a **shared type** — add the field to one subgraph marked `@inaccessible` so
composition doesn't require every subgraph to have it yet, roll it out, then drop
the directive to publish it. (Apollo contracts also pair `@tag` + `@inaccessible`
to build filtered API variants.)

Loading strips every `@inaccessible` element and cascades: a
field/argument/union-member/interface referencing a removed type goes too, and a
type left empty is removed in turn. So codegen validates against what clients can
actually query, with no need for Apollo's JS tooling to subtract the API schema
first — feed it the raw supergraph and you get the router's contract. The
derivation is diffed against Apollo's own `composeServices` + `toAPISchema()` in
[`spec/integration/api_schema_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/integration/api_schema_spec.rb).

Two bounds. The directive is matched by the **local name it was linked under**, so
an `import:` alias subtracts what that alias marks. And the subtraction runs
**only on the supergraph path** — plain and subgraph SDL are taken at face value,
where `@inaccessible` stays a directive and its fields stay queryable. Directives
that hide nothing keep their field and are ignored: `@requiresScopes` / `@policy`
/ `@authenticated` enforce at runtime, `@tag` / `@requires` / `@provides` /
`@external` are metadata.

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
table.possible_types("Purchasable", "products")      # => ["Bundle", "Product"]
```

Subgraphs are named the way `@join__graph(name:)` names them — the strings a
router config and `rover` use, not the SDL's uppercase enum spelling. A `@key`
field set comes back as dotted paths (`"id organization { id }"` → `["id",
"organization.id"]`), so a nested one is recognizable by its shape. A field
with no `@join__field` at all lives wherever its type does; that omission is
how the composer says "everywhere". `possible_types` answers the abstract
side — the concrete types one subgraph can answer a union or interface with,
from `@join__unionMember`/`@join__implements` — and `nil` where the supergraph
doesn't say, which is a different fact from "none".

A `@join__` directive the table hasn't been taught lands in `#unsupported`
rather than being skipped, and callers refuse on a non-empty list: a table that
silently ignores half a spec version answers confidently and wrongly.
`#interface_objects` is the one construct kept out of that list
(`{"Media" => ["catalog"]}`), because it's a fact about one *type* rather than
about the table — the router refuses the queries that reach it and plans the rest.

The table is what [`Testing::Router`](#the-local-router) plans against, and it's
a reasonable read on its own — "which subgraph owns this field" is the sentence a
good error message wants. So when the schema dump is a composed supergraph,
`rake graph_weaver:queries:check` brands each validation error with the subgraphs
behind the type it names:

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
supergraph.graphql: 1 stale, 1 not composed in (checked 1 of 3 subgraphs)

stale — the supergraph carries these, no schema here defines them (recompose):
  Product.weight (products)

not composed in — a schema here defines these, the supergraph doesn't carry them:
  Product.dimensions (Products::Schema)

not checked — nothing here defines what the supergraph says only these resolve (running elsewhere, or the subgraph is gone):
  shipping (Shipment, Shipment.eta, Order.shipment)

not checked — answered with fabricated data:
  reviews
```

Both directions, because they mean opposite things: **stale** is "recompose",
**not composed in** is "publish the subgraph". The stale side names the
subgraph the supergraph blames — whose code to look at, whose team to talk to.
"Defines" is deliberately looser than field-set equality, since a subgraph
carries plumbing (`_entities`, `_service`) no supergraph has and a field can
legitimately sit in more than one subgraph (`@external` copies, `@shareable`).

**A supergraph is routinely only partly local**, so the report names three
states rather than two: checked, not here (running elsewhere — or the subgraph
is gone), and [faked](#the-local-router). A clean report that quietly checked one
subgraph of three would be actively misleading, so the headline counts them and
the sections name them. Only drift fails the task; absence is a supported
setup. Checking **none** of them fails too — "checked 0 of 4" attached to exit 0
is a gate that passes whatever the subgraphs say. (Under Rails it won't come up:
the `federation:*` tasks eager-load the app, because `config.rake_eager_load`
defaults to false and detection only sees loaded classes.)

A schema is recognized by the types the supergraph says its subgraph declares,
plus at least one coordinate attributed to that subgraph **alone**. What two
subgraphs share can't tell them apart — every subgraph has a `Query`, and the
entity `accounts` and `prefs` both extend is declared by both — so a subgraph
whose own fields are nowhere in this process is "not here", not stale.
Detection is therefore what drift breaks, so the same
`subgraphs:` map [`Testing::Router`](#the-local-router) takes is accepted here,
and a named schema skips detection:

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
tag and there is nothing to pass — the tag builds it, once for the suite. It
finds the supergraph where you have already said it is: `Testing.config.router
= { supergraph: … }` if you named one there, else the schema a
[graph](getting_started.md#more-than-one-schema) declares when that schema is
composed, else the committed dump when *that* is. Two graphs may name one
supergraph; two naming different ones is refused rather than picked between.
`router.trace` records the fetches made since the last `reset_trace`, in order
(subgraph, query, variables); the same lines go to `GraphWeaver.logger` at
`:debug`. It **accumulates across executes**, because the question worth asking
is which subgraphs a code path touched and a service object rarely runs one
query. The rspec tag resets it before each example; outside rspec call
`router.reset_trace` around the code path you're measuring.

The router hands back a result hash *above* the wire, so the transport your app
ships never runs. When that transport is the thing under test — a caller tag, an
APM header, mTLS — [`graphql: :wire`](testing.md#over-the-wire--graphql-wire)
serves this same router at the endpoint your client posts to and leaves your
client in place: real serialization, the same plan over the same resolvers,
`from_h` over the server's own bytes, and a `context:` proc reading the headers
that arrived. It refuses exactly what the router refuses — a hop, not a
capability.

**[`examples/federation.rb`](https://github.com/dpep/graph_weaver/blob/main/examples/federation.rb)** is the whole shape
in one runnable file, and the only example that needs no network: three real
subgraphs, a boundary-crossing query through a generated module, the trace,
and a refusal. [`spec/router_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/router_spec.rb) is the
exhaustive reference — every plan shape, every refusal, the partly-local
graph and the `:fake` opt-in, each as a named example.

### Which schema serves which subgraph

`subgraphs:` is optional. Left out, each one is **derived from what the loaded
schemas define**: a schema serves subgraph `s` when it defines every type and
field the routing table says `s` resolves. That's evidence rather than a guess,
and a wrong guess would point a suite at the wrong resolvers and still pass — so
exactly one match is used. Neither other outcome refuses at construction, since
which classes are loaded is not a fact about the query you're running: **no**
match means the subgraph is served somewhere else (next section), and **two**
means detection can't say which loaded schema class serves it. Both are refused
by the query that reaches the subgraph's fields, each naming its own fix — for
two, `subgraphs: { "reviews" => App::Reviews::Schema }` pins it, and
`router.ambiguous` lists them.

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
absent. The `federation:*` rake tasks eager-load the app for you; a spec suite
is your own `config.eager_load`, which Rails leaves off outside CI. To see what
detection sees, and get a map to paste:

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
subgraphs: { "shipping" => :fake }   # any other absent subgraph still refuses
```

If the subgraph *is* here and detection just couldn't see it — a Rails schema
class nothing has referenced yet — loading it is the fix, and in a spec suite
that means `config.eager_load = true` (naming it in
`Testing.config.router = { subgraphs: … }` works too). `=> :fake` is the
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

`fake:` says how they fabricate — the [pins](testing.md#pins) and options a
fake takes, in one hash. It goes on `Router.new` outside rspec, on
`Testing.config.router` for the suite, and on `graphql_router` for the one
example that cares:

```ruby
Testing.config.router = { subgraphs: { "shipping" => :fake },
                          fake: { list_size: 2 } }

it "shows the carrier" do
  graphql_router(fake: { "Shipment.carrier" => "UPS" })
  ...
end
```

One `fake:` covers every faked subgraph, because a pin's key
(`"Shipment.carrier"`) already says which type it means. And `graphql_router` is
`graphql: :router` with somewhere to put arguments — the router itself is still
built once for the suite, and the options last one example.

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
router.reset_trace
router.execute("{ reviews { product { shippingEstimate } } }")
router.trace.map { _1[:subgraph] }   # => ["reviews", "products", "reviews"]
```

`shippingEstimate` resolves in `reviews` and `@requires "price weight"`, which
`products` owns — so the plan fetches those into hidden keys, hands them back
in the representation, and only then asks for the estimate. One hop only: the
key for the first fetch has to come from the subgraph already in hand, so a
chain can't grow a chain. And two `@requires` field sets crossing into the same
subgraph on the same `@key` ride **one** prefetch, as Apollo's do — the
representations would be identical, so a second call would only re-run the
resolvers.

A **nested field set** — `@key(fields: "id organization { id }")`,
`@requires(fields: "origin { lat lon }")` — is a selection set like any other,
so it crosses as one: the fetch asks for `organization { id }` under a
reserved alias, and the representation carries the object back in the shape
the SDL spells it, to any depth, nulls and all. Where a type has more than one
`@key`, the plan takes the first one the fetching subgraph can supply.

A **union or interface at a boundary** — a feed, a search page, any
polymorphic list — is planned per concrete type, because a representation names
one concrete `__typename` and which one an object has isn't in the query:

```ruby
router.reset_trace
router.execute("{ purchasables { name ... on Product { reviews { body } } } }")
router.trace.map { _1[:subgraph] }   # => ["products", "reviews"]
```

The plan holds a branch per type the supergraph says that subgraph can answer
with; the fetch asks for `__typename` under a reserved alias, and the objects
that come back are bucketed by it — one `_entities` fetch per concrete type,
none for a bucket nothing lands in. A fragment whose condition can't hold there
(`... on Note` where that subgraph's union has no Note) never matches, so it is
dropped, which is the answer a real router gives too.

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
before any subgraph runs — so a refusal is never a half-executed query. A double
that approximated the rest of Apollo's planner would let a test pass on an
answer production disagrees with, which is the most expensive thing this library
can produce. Each refusal names the coordinate that stopped it and what to do —
`examples/federation.rb` prints one.

Every category, in the words `Unplannable#label` uses (`#category` is the
matching symbol):

| Refusal | Why |
|---|---|
| no `@key` to cross the boundary on | an entity fetch sends a representation built from a `@key`; with none there is nothing to send |
| an abstract type the supergraph doesn't break down | bucketing needs the concrete types a subgraph answers a union or interface with, and `@join__unionMember`/`@join__implements` is where a supergraph records that. A composition old enough to carry neither leaves nothing but a guess |
| an `@interfaceObject` the routing table can't attribute | one subgraph resolves a whole interface's implementations, so the supergraph never says which subgraph answers each of its fields. Per query, not per graph: a query that doesn't reach the type plans as if the directive weren't there |
| a `@fromContext` argument no fetch here can supply | federation 2.8's `@context`/`@fromContext` fills a field's argument from a selection on an ancestor, and only the gateway that planned the fetch knows what to put there. Per query, like `@interfaceObject`: a subtree one subgraph answers whole sets its own context and plans normally |
| a `@requires` whose field set names another `@requires` field | the router satisfies a `@requires` with one fetch, so it can't first satisfy that field's own requirement |
| a nested field set no one fetch can build | a nested field set crosses as one object, so one fetch has to answer the whole of it. Nesting itself is fine — this is the set whose fields are split across subgraphs, so the object would arrive half-built from each |
| `@skip`/`@include` on both a fragment and its field | one selection can't carry two conditions of the same name. Spell the condition once |
| an alias shadowing an injected `@key` | a fetch carries the `@key` it crosses on under a response key — Apollo under the field's own name, the local router under a reserved one — and an alias spelling either claims a key the fetch needs |
| a mutation's root fields span subgraphs | root mutation fields run in series, and splitting them across subgraphs would run them in whatever order the plan happened to. Sharing one subgraph they're fine, stitching below them and all — that's an ordinary read afterwards. Query roots are independent, so those are always fine |
| the routing table names no subgraph | nothing can route a field the supergraph doesn't place |
| a subgraph nothing here serves | it's served by another process, so there is nothing here to ask — unless you fake it (above) |
| introspection mixed with data | introspection is answered from the composed API schema and data from the subgraphs, and the two can't be merged. Split them into two operations |
| the document isn't one operation | pass `operation_name:` naming one of them |
| not a query or a mutation | the router plans against the composed schema's query and mutation roots; a subscription has neither |
| a fragment the document never defines | define it, or point the query at the file that does |
| a federation construct the routing table doesn't read | an incomplete table makes every answer about this supergraph a guess. The one refusal raised **at construction**, before a single query |
| nested deeper than the router walks | past the walk's depth limit, which validation would have rejected first |

A subgraph two loaded schemas both fit raises a `ConfigurationError` rather than
an `Unplannable` — it's a wiring mistake, not a query the router declines — but
it raises where every other one does, on the query that reaches the subgraph.
Which classes happen to be loaded is not a fact about the query under test.
Naming a class in `subgraphs:` *is* a claim, so a wrong one still fails at
construction.

A double that quietly answered *differently* from the router would be worse than
no double at all, so
[`spec/integration/router_parity_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/integration/router_parity_spec.rb)
serves the demo subgraphs over HTTP, boots a real `@apollo/gateway` on the same
supergraph, and runs the whole corpus through both — plus boundary probes and
queries where a subgraph deliberately **fails**, which are the cases where a
merge that doesn't re-propagate hands back a populated tree while the real router
answers `data: null`. Three outcomes, one of them a defect: match, refuse, or
answer differently, and the spec fails on the third. `make integration` runs it
(node required).

### Is it worth wiring up? Measure.

The router's value is one number — the fraction of *your* queries it can plan —
and that depends on the shape of your graph and of your queries, so measure it
rather than guess:

```
$ rake graph_weaver:federation:coverage SUPERGRAPH=supergraph.graphql
17/17 queries plannable locally (100%), 17 servable here
  accounts 4, reviews 4, products+reviews 3, accounts+reviews 2, products 2, accounts+products 1, accounts+products+reviews 1
```

**Two numbers, because they answer different questions.** *Plannable* is about
the graph — could the router split this query faithfully at all. *Servable
here* is what your suite actually gets: every subgraph that plan reaches is one
this process serves. In a [partly-local supergraph](#a-supergraph-only-partly-local)
they differ, and the plannable number alone reads optimistically — sketched
here on a graph whose `billing` and `shipping` run elsewhere:

```
5/5 queries plannable locally (100%), 2 servable here
  accounts 1, billing 1, reviews 1, reviews+shipping 1, shipping 1

plannable, but nothing here serves what they reach (3) — name a schema for those subgraphs, fake them (subgraphs: { "shipping" => :fake }), or run these against a real router:
  invoices.graphql         billing
  shipping_quotes.graphql  shipping
  tracking.graphql         shipping
```

`QUERIES=` picks the directory (default `GraphWeaver.queries_paths`). Planning
needs the supergraph and nothing else, so this runs in CI with the SDL alone —
with no subgraph loaded the report drops the second number and says it counted
planning only. The subgraph line says which subgraphs each query touches, and
anything refused is listed after it grouped by category, so one glance says
whether the gap is one construct or many. (The first run above is the demo graph
in `spec/support/federation`, not a real app's mix.)

## Generating against a subgraph

A raw subgraph SDL — `rover subgraph fetch`, `_service { sdl }`, or the
`.graphql` in a service repo — loads too. It applies `@key`/`@external`/
`@shareable`/… without declaring them (federation v1 leaves them implicit, v2
imports them via `@link`, including under a namespace as
`@federation__key`), so the missing definitions are supplied on load; anything
the file declares itself wins. The federation directives themselves generate no
code — codegen is query-driven.

Reach for this when the subgraph is what you have, or to type an `_entities`
query (below). But a subgraph is one service's slice of the graph, and its
field shapes are not always the composed ones (an `@external` field is a
reference, not something that subgraph serves) — for a client of the whole
graph, feed the composed artifact.

### `_entities`

Every subgraph serves the entity resolver
`_entities(representations: [_Any!]!): [_Entity]!`, and **no subgraph SDL
contains it**: `_service { sdl }` and `rover subgraph fetch` print the
*published* schema, where the plumbing is implicit. So it's supplied on the
subgraph path — `_Any`, `_Service`, and an `_Entity` union over the file's own
`@key`'d types — the same way the `@key`/`@external` definitions are. A file
that declares its own keeps it.

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
the type and the field:

```
Variant representation satisfies none of its @keys — supply "id", or "serial"
Listing representation is missing @key "organization.id"
```

Key fields take the same loose input an `execute` kwarg does — a `params[:sku]`
String converts to the `Int` the `@key` declares — and a value that converts to
nothing raises `GraphWeaver::InputError` naming the representation and the
field:

```
Product representation sku: expected an Int, got "forty-two"
```

Only the declared key fields reach the wire — an extra key in a nested hash is
dropped. Builders are emitted **only for the entities a query's `_entities`
selection reaches** (codegen is query-driven, so a subgraph with fifty entities
emits nothing for the forty-nine you didn't name), and a
`@key(..., resolvable: false)` declares a key this subgraph does *not* answer
for, so it builds nothing. Key fields typed as scalars get their registered Ruby
type; anything else (a nested selection) is an open `Hash` the runtime narrows.
Every shape above is a named example in
[`spec/federation_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/federation_spec.rb).
