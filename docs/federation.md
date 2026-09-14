# Federation

For an app that is a client of a federated graph, a subgraph in one, or both. Two
halves: **generating** against a composed supergraph, which mostly means "point it
at the file and forget", and the **local router**, which runs a stitched query
against your own resolvers in-process so specs need no gateway. Any federation
artifact works — a supergraph, an API schema, a subgraph SDL, or a live router;
`SchemaLoader.load` (and `Client.new(path_or_sdl)`) recognize which they got, as an
SDL file or an introspection dump.

**Which half is yours** depends on what your app does with the graph, and most apps
are only one:

- **You call the gateway and compose nothing.** [Generating for a federated
  graph](#generating-for-a-federated-graph) and [the local
  router](#the-local-router) are the whole document for you.
- **You publish a subgraph.** Add [generating against a
  subgraph](#generating-against-a-subgraph) and [a subgraph that calls its own
  graph](#a-subgraph-that-calls-its-own-graph).
- **You own the supergraph.** All of it, plus [producing
  one](#producing-a-supergraph), [`federation:diff`](#has-the-supergraph-been-recomposed)
  and [in CI](#in-ci).

## Generating for a federated graph

**Queries go through the gateway?** Generate against the supergraph. It is the
whole graph in one schema, so every registration matches and there is nothing else
to decide.

**Calling subgraphs directly?** One graph per subgraph, declared once:

```ruby
GraphWeaver.graph :billing do
  schema    "billing.graphql"
  queries   "app/graphql/billing"
  output    "app/graphql/generated/billing"
  namespace "Billing"
  register_scalar "Money", Money
end
```

One `rake graph_weaver:generate` generates every graph, and each subgraph is held
only to the registrations declared for it. (Naming a live subgraph *class* from a
Rails initializer takes a lambda — `schema -> { Billing::Schema }` — see
[getting started](getting_started.md#more-than-one-schema).)

Registrations made at the *top* level still reach every graph, because names
compose by identity across a graph — `Money` is one Ruby type wherever it appears,
and `Person` is one entity even though a single subgraph owns `birthday`. So a
registration a given subgraph doesn't declare is not an error; generation warns
and carries on, printing the list once per run:

```
register_scalar("Money") matches no scalar in Billing::Schema — a typo, or a registration for another schema
```

`GraphWeaver.unmatched_registrations` is that same list as data, and moving a
registration into the graph block that needs it is what makes the lines go away.
Entity fields work the same way: a subgraph carrying `Person` for its `@key` alone
sees a top-level `register_scalar("Person.birthday", Date)` as a field it doesn't
own — a warning, not a failure. What a subgraph *can* disprove still fails
generation: a name it declares as something else, or a coordinate whose field it
declares as a composite. Neither is redeemable by any schema in the graph.

### Generating against a supergraph

A supergraph SDL works as-is. On load, GraphWeaver strips the composition
machinery — the synthetic `join__*`/`link__*` types and directive definitions, and
every `@join__*`/`@link` application on the real types — so codegen sees the
merged graph's ordinary type shapes. Field shapes (nullability, args, enums,
inputs) are identical to the API schema, so your generated structs are correct.

**Which names count as machinery is read off the schema**, not a fixed list.
Federation namespaces itself through [`@link`](https://specs.apollo.dev/link/v1.0/)
(v2) or [`@core`](https://specs.apollo.dev/core/v0.2/) (v1), and those declarations
are applied as written: the spec URL's name segment gives the namespace
(`https://specs.apollo.dev/join/v0.3` → `join__`), `as:` renames it, `import:`
binds names into the root namespace. So a fed 2.5+ graph's `@requiresScopes` /
`@policy` / `@context` machinery strips the same way `join__` does, a renamed
`@inaccessible` still hides what it marks, and v1 supergraphs load identically. A
schema that declares nothing still gets the `join__`/`link__`/`core__` floor.

A supergraph is also a **superset** of the API schema: it carries elements the
public API hides, marked `@inaccessible`. Loading strips every `@inaccessible`
element and cascades — a field, argument, union member or interface referencing a
removed type goes too, and a type left empty is removed in turn — so codegen
validates against what clients can actually query, with no need for Apollo's JS
tooling to subtract the API schema first. (The derivation is diffed against
Apollo's own `composeServices` + `toAPISchema()` in
[`spec/integration/api_schema_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/integration/api_schema_spec.rb).)
Two bounds: the directive is matched by the **local name it was linked under**, so
an `import:` alias subtracts what that alias marks; and the subtraction runs **only
on the supergraph path** — plain and subgraph SDL are taken at face value.
Directives that hide nothing keep their field: `@requiresScopes` / `@policy` /
`@authenticated` enforce at runtime, `@tag` / `@requires` / `@provides` /
`@external` are metadata.

### Contracts and variants

A contract variant is a supergraph built from the same subgraphs with some
coordinates filtered out: a subgraph marks them `@tag(name: "internal")`, and
GraphOS builds a second supergraph where everything carrying that tag is
`@inaccessible`. Nothing special is needed to generate against one — the
subtraction above is exactly what makes it the narrower schema its clients see. A
query selecting an internal-only field generates against **internal** and, against
**public**, fails codegen with a `QueryValidationError` naming the field, because
the load subtracted it before validation saw it. That is the guarantee: a client
generated against the variant it calls cannot select something the router will
reject.

One app calling two variants is
[two graphs](getting_started.md#more-than-one-schema), each with its own `schema`,
`queries`, `output` and a `namespace` if any module name would collide; a variant
is mechanically just another graph. But **nothing cross-checks the variant you
generated against with the endpoint you call** — generate against internal, deploy
against public, and every check stays green until a live 400 — and
**`federation:diff` can't tell the variants apart** either, since it reads the
routing table and `@inaccessible` is a directive the table doesn't carry. Point
each graph at the variant it actually calls.

## The local router

Specs for a federated app have a bad choice: fake the whole graph, or boot a
gateway. `Testing::Router` is the third one. It takes the composed supergraph and
the Ruby schema classes serving its subgraphs, plans the query, and satisfies the
[client contract](transports.md) — so a generated module runs against your **real
resolvers**, in-process, with no gateway, no node and no sockets. It is not a mock:
your resolvers run, which is the whole point.

In rspec that's the [`graphql: :router`](testing.md#a-federated-graph--graphql-router)
tag and there is nothing to pass — the tag builds it, once for the suite. It finds
the supergraph where you have already said it is: `Testing.config.router =
{ supergraph: … }` if you named one there, else the schema a
[graph](getting_started.md#more-than-one-schema) declares when that schema is
composed, else the committed dump when *that* is. Two graphs may name one
supergraph; two naming different ones is refused rather than picked between.
Outside rspec, build it yourself:

```ruby
GraphWeaver.client = GraphWeaver::Testing::Router.new(
  supergraph: Rails.root.join("supergraph.graphql"),
  context: { current_user: user },
)
```

`context:` reaches every subgraph, because every subgraph is a Ruby call here. A
request's **headers** don't: the gateway and the Apollo Router both start a subgraph
call with none of the client's unless you configure forwarding, so don't let a spec
conclude an auth header arrived somewhere it wouldn't.

`router.trace` records the fetches made since the last `reset_trace`, in order
(subgraph, query, variables); the same lines go to `GraphWeaver.logger` at
`:debug`, and the rspec tag resets it before each example. It **accumulates across
executes**, because the question worth asking is which subgraphs a code path
touched. But the count is the **local router's plan, not the gateway's**: the data
is faithful — a real gateway answers byte-identically, or this refuses — while a
[`@requires` prefetch](#what-it-plans) is still its own call where a gateway merges
it into the read beside it. So assert on a **bound**
(`expect(router.trace.size).to be <= 8`) or on the **subgraph set**
(`router.trace.map { _1[:subgraph] }.uniq`): both move when an N+1 appears, and
neither pins a number production doesn't have.

The router hands back a result hash *above* the wire, so the transport your app
ships never runs. When that transport is the thing under test — a caller tag, an
APM header, mTLS — [`graphql: :wire`](testing.md#over-the-wire--graphql-wire) serves
this same router at the endpoint your client posts to and leaves your client in
place: real serialization, the same plan over the same resolvers, `from_h` over the
server's own bytes, and a `context:` proc reading the headers that arrived. It
refuses exactly what the router refuses — a hop, not a capability — and the hop is
served through webmock, so that tag needs `require "webmock/rspec"`.

**[`examples/federation.rb`](https://github.com/dpep/graph_weaver/blob/main/examples/federation.rb)**
is the whole shape in one runnable file, and
[`spec/router_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/router_spec.rb)
is the exhaustive reference — every plan shape and every refusal, each as a named
example.

### What it refuses

Everything it can't plan **faithfully** raises `GraphWeaver::Testing::Unplannable`
(a `GraphWeaver::Error`), at plan time, before any subgraph runs — so a refusal is
never a half-executed query. A double that approximated the rest of Apollo's
planner would let a test pass on an answer production disagrees with, which is the
most expensive thing this library can produce. Each refusal names the coordinate
that stopped it and what to do.

Every category, in the words `Unplannable#label` uses (`#category` is the matching
symbol):

| Refusal | Why |
|---|---|
| no `@key` to cross the boundary on | an entity fetch sends a representation built from a `@key`; with none there is nothing to send |
| an abstract type the supergraph doesn't break down | bucketing needs the concrete types a subgraph answers a union or interface with, and `@join__unionMember`/`@join__implements` is where a supergraph records that. A composition old enough to carry neither leaves nothing but a guess |
| an `@interfaceObject` the routing table can't attribute | one subgraph resolves a whole interface's implementations, so the supergraph never says which subgraph answers each of its fields. Per query, not per graph: a query that doesn't reach the type plans as if the directive weren't there |
| a `@fromContext` argument no fetch here can supply | federation 2.8's `@context`/`@fromContext` fills a field's argument from a selection on an ancestor, and only the gateway that planned the fetch knows what to put there — a subgraph's own resolver never fills one, so this is refused on any path, including the one where a single subgraph answers the whole query. Per query, like `@interfaceObject` |
| a response delivered in more than one payload | `@defer`/`@stream` stream the rest of the answer over a multipart body after the first payload, and this router answers in one. Refused by name rather than left to validation, so the guarantee doesn't rest on whether the composed schema happens to declare the directive |
| a progressive `@override` still rolling out | federation 2.7's `@override(label:)` leaves *both* subgraphs resolving the field — the gateway splits traffic per request by the label's rule, and a local router can't evaluate a rollout percentage. Finish the rollout (drop the label) and composition drops the losing copy, which plans normally |
| a `@requires` whose field set names another `@requires` field | the router satisfies a `@requires` with one fetch, so it can't first satisfy that field's own requirement |
| a nested field set no one fetch can build | a nested field set crosses as one object, so one fetch has to answer the whole of it. Nesting itself is fine — this is the set whose fields are split across subgraphs, so the object would arrive half-built from each |
| `@skip`/`@include` on both a fragment and its field | one selection can't carry two conditions of the same name. Spell the condition once |
| an alias shadowing an injected `@key` | a fetch carries the `@key` it crosses on under a response key — Apollo under the field's own name, the local router under a reserved one — and an alias spelling either claims a key the fetch needs |
| a mutation's root fields span subgraphs | root mutation fields run in series, and splitting them across subgraphs would run them in whatever order the plan happened to. Sharing one subgraph they're fine, stitching below them and all. Query roots are independent, so those are always fine |
| the routing table names no subgraph | nothing can route a field the supergraph doesn't place |
| a subgraph nothing here serves | it's served by another process, so there is nothing here to ask — unless you [fake it](#a-supergraph-only-partly-local) |
| introspection mixed with data | introspection is answered from the composed API schema and data from the subgraphs, and the two can't be merged. Split them into two operations |
| the document isn't one operation | pass `operation_name:` naming one of them |
| not a query or a mutation | the router plans against the composed schema's query and mutation roots; a subscription has neither |
| a fragment the document never defines | define it, or point the query at the file that does — validation rejects it first, so what you actually get back is an `errors` response |
| a federation construct the routing table doesn't read | an incomplete table makes every answer about this supergraph a guess. The one refusal raised **at construction**, before a single query |
| nested deeper than the router walks | past the walk's depth limit, which validation would have rejected first |

A document that fails ordinary GraphQL validation never reaches any of this: it
gets the same `errors` response a plain client gets. The construction-time refusal
is worth planning around, though — a `@join__` directive the table doesn't read
refuses `Router.new` for the **whole graph**, so one team adopting a newer
federation feature is an upgrade-timing event for every team that tests with
`:router`. A subgraph two loaded schemas both fit raises a `ConfigurationError`
instead, being a wiring mistake rather than a query the router declines, but it
raises where every other one does: on the query that reaches the subgraph.

### Which schema serves which subgraph

`subgraphs:` is optional. Left out, each one is **derived from what the loaded
schemas define**: a schema serves subgraph `s` when it defines every type and field
the routing table says `s` resolves, plus at least one coordinate attributed to
that subgraph **alone** (what two subgraphs share can't tell them apart). That's
evidence rather than a guess, and a wrong guess would point a suite at the wrong
resolvers and still pass — so exactly one match is used. Neither other outcome
refuses at construction, since which classes are loaded is not a fact about the
query you're running: **no** match means the subgraph is served somewhere else
(below), and **two** means detection can't say which class serves it. Both are
refused by the query that reaches the subgraph's fields, each naming its own fix —
for two, `subgraphs: { "reviews" => App::Reviews::Schema }` pins it, and
`router.ambiguous` lists them.

Name them yourself when you'd rather have the wiring committed, or when detection
can't settle it — including partially, with the rest derived. Either way the map is
**checked** at construction, so a swapped pair fails naming what's missing rather
than surfacing as a mystery three fetches later:

```
subgraphs["accounts"] is Products::Schema, which doesn't define Query.me,
Query.user, Query.users, User, User.email and 1 more — the supergraph says
accounts resolves them. Did two entries get swapped?
```

Detection only sees what's **loaded**, and in Rails an autoloaded schema isn't until
something references it — which is why an unmatched subgraph reads as absent. The
`federation:*` rake tasks eager-load the app for you; a spec suite is your own
`config.eager_load`, which Rails leaves off outside CI. To see what detection sees,
and get a map to paste:

```
$ rake graph_weaver:federation:subgraphs
subgraphs: {
  "accounts" => Accounts::Schema,  # matched: defines Query.me, Query.user, Query.users
  "products" => Products::Schema,  # matched: defines Product.name, Product.price, Product.weight
}
```

A row nothing matched comes back `nil`, naming the coordinates it looked for —
that's the map to fill in, or the subgraph that lives elsewhere.

### A supergraph only partly local

The usual migration shape: the supergraph is composed from several services and
only **some** of them run in your process. Requiring a Ruby schema for the rest
would refuse the whole suite over fields most of your queries never touch, so a
subgraph nothing here defines is **absent**, and the router builds and runs anyway.
Absence costs you exactly the queries that reach into it:

```ruby
router.absent                                            # => ["shipping"]
router.execute("{ me { username reviews { body } } }")   # real data, as always
router.execute("{ shipments { carrier } }")              # GraphWeaver::Testing::Unplannable
```

That refusal is a plan-time one like every other, so nothing has executed when it
raises, and it names the subgraph, the field that reached for it, and both ways out
— name a schema for it, or fake it:

```ruby
subgraphs: { "shipping" => :fake }   # any other absent subgraph still refuses
```

If the subgraph *is* here and detection just couldn't see it — a Rails schema class
nothing has referenced yet — loading it is the fix, which in a spec suite means
`config.eager_load = true`. `=> :fake` is the other one: mid-migration, letting an
absent subgraph answer with schema-correct fabricated data exercises the rest of
the query. It speaks the whole subgraph contract, `_entities(representations:)`
included, so it works under a stitched fetch as well as at a root field.

Refusing stays the default, and the opt-in is **per subgraph** on purpose: silently
substituting invented data is the failure mode this library keeps designing
against. For the same reason faking is **loud** — every faked fetch is marked
`faked: true` in `router.trace` and logged at `:warn`, `router.faked` lists them,
and `router.inspect` shows what's served, faked and absent. Values come from the
same engine as [`graphql: :fake`](testing.md#fabricated-data--graphql-fake), and
`fake:` says how they fabricate: the [pins](testing.md#pins) and options a fake
takes, in one hash, on `Router.new` outside rspec, on `Testing.config.router` for
the suite, or on `graphql_router(fake: { "Shipment.carrier" => "UPS" })` for the one
example that cares. One `fake:` covers every faked subgraph, since a pin's key
already says which type it means, and the router is still built once for the suite —
only the options last one example.

## Generating against a subgraph

A raw subgraph SDL — `rover subgraph fetch`, `_service { sdl }`, or the `.graphql`
in a service repo — loads too. It applies `@key`/`@external`/`@shareable`/… without
declaring them (federation v1 leaves them implicit, v2 imports them via `@link`),
so the missing definitions are supplied on load; anything the file declares itself
wins. Whatever the `@link` header says the directives are called is what's supplied
— the bare `@key`, the namespaced `@federation__key`, or `@primaryKey` from
`import: [{name: "@key", as: "@primaryKey"}]`. The header itself is read and then
dropped: it describes the file, not the graph. The federation directives generate
no code either way — codegen is query-driven.

Reach for this when the subgraph is what you have, or to type an `_entities` query.
But a subgraph is one service's slice of the graph, and its field shapes are not
always the composed ones (an `@external` field is a reference, not something that
subgraph serves) — for a client of the whole graph, feed the composed artifact.

### `_entities`

Every subgraph serves the entity resolver
`_entities(representations: [_Any!]!): [_Entity]!`, and **no subgraph SDL contains
it**: `_service { sdl }` and `rover subgraph fetch` print the *published* schema,
where the plumbing is implicit. So it's supplied on the subgraph path — `_Any`,
`_Service`, and an `_Entity` union over the file's own `@key`'d types — the same
way the `@key`/`@external` definitions are. A file that declares its own keeps it.

The read side is a normal union selection; `alias:` turns the single-entity case
into a clean accessor (see
[flat accessors](generated_modules.md#flat-accessors-with-alias)):

```ruby
GraphWeaver.extend_type("Query", alias: { entity: "_entities.first" }, optional: true)
```

The **input** side is generated. A representation must carry `__typename` and
satisfy one of the entity's `@key` field sets — both hard requirements of the
subgraph spec, and neither expressible in a bare `[_Any!]!` — so a query selecting
entities gets a `Representations` builder per entity it reaches, typed from the
`@key` directives:

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
| `"id lineItems { sku }"` over a `[LineItem!]!` | `Representations.order(id: "1", line_items: [{ sku: "a" }, { sku: "b" }])` |
| `"id"` **and** `"serial"` (alternatives) | `Representations.variant(id: "1")` *or* `(serial: "s")` |

A key field the schema declares as a **list** takes a list, and stays one on the
wire — a single object there would describe an entity that doesn't exist. A type
with one `@key` types its fields as **required kwargs**, so an incomplete
representation is an `srb tc` error rather than a round trip; what a sig can't say
is checked at runtime and raises `GraphWeaver::InputError` naming the type and the
field:

```
Variant representation satisfies none of its @keys — supply "id", or "serial"
Listing representation is missing @key "organization.id"
Product representation sku: expected an Int, got "forty-two"
```

Key fields take the same loose input an `execute` kwarg does, so a `params[:sku]`
String converts to the `Int` the `@key` declares. A `@key` field whose name a
generated method can't take as a kwarg — `class`, `hash`, or a Ruby keyword — takes
a trailing underscore, the same one its prop took, and still sends the schema's
spelling on the wire: a subgraph's `@key` field is not yours to rename, so weaver
renames its own side rather than refusing. Only the declared key fields reach the
wire, builders are emitted only for the entities a query actually selects, and a
`@key(..., resolvable: false)` builds nothing, since it declares a key this subgraph
does *not* answer for. Every shape above is a named example in
[`spec/federation_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/federation_spec.rb).

**Off-label**, a subgraph that generates against its *own* SDL gets a typed gate for
a raw incoming representation, before `resolve_reference` sees one — with two
bounds: a single-`@key` builder takes required kwargs, so splatting a hash that is
short a field raises Ruby's `ArgumentError` rather than an `InputError`, and where
two key sets overlap the first fully supplied one wins silently.

## A subgraph that calls its own graph

A subgraph resolver that reaches for the composed graph — a cross-cutting report, a
field easier to answer through the gateway than by hand — is an ordinary thing to
write and the one shape **every** test tier is blind to, because each of them
intercepts exactly that call. Under `:in_process` the client points back at the
subgraph under test, so the loopback runs against a schema with none of those root
fields. Under `:router` it re-enters the router it is already inside. Under `:wire`
it is a second POST to the endpoint WebMock has stubbed. All three answer; none of
them is the address production will use.

So give the call its own graph, beside the one for the subgraph itself, with a
client distinct from the one the app uses to reach the gateway from outside:

```ruby
# config/initializers/graph_weaver.rb — beside GraphWeaver.graph :reviews,
# whose client is "Reviews::Schema"
PLATFORM = GraphWeaver.new(ENV.fetch("PLATFORM_GRAPHQL_URL"))

GraphWeaver.graph :platform do
  schema    "app/graphql/supergraph.graphql"
  queries   "app/graphql/platform/queries"
  output    "app/graphql/platform/generated"
  client    "PLATFORM"
  namespace "Platform"
end
```

The resolver then calls `Platform::ProductsQuery.execute!` instead of
`GraphWeaver.client`, which buys three things. The target is named where someone
deploying can see it (`rake graph_weaver:graphs` prints it, and `ENV.fetch` fails at
boot rather than at the first request). A helper stands in for one graph at a time,
so a spec has to say `graphql_router(graph: :reviews)`, and can't cover the
loopback by accident. And with two graphs `GraphWeaver.client` under a mode refuses
by name rather than reaching a real endpoint, so a stray call is loud.

What none of that gives you is proof the url resolves. That is a smoke request
against a running gateway, and it is the only thing that will.

## Producing a supergraph

GraphWeaver consumes a supergraph; composing one is Apollo's job. Composition takes
one SDL file per subgraph, so the question is where each file comes from.

**Yours.** [`apollo-federation`](https://github.com/Gusto/apollo-federation-ruby)
is the gem that makes a graphql-ruby schema a subgraph — `@key`,
`resolve_reference`, the directives — and it adds `federation_sdl`, which prints
exactly what a composer wants:

```ruby
File.write("supergraph/accounts.graphql", Accounts::Schema.federation_sdl)
```

Two traps in that gem. Declare `orphan_types` **before** `query`: it computes the
`_Entity` union when `query` is called, so an `orphan_types` after it drops those
types from the printed SDL and from `_entities` with no error at all. That is also
what an **extend-only type** needs — one this subgraph adds fields to but never
returns from its own `Query` — since nothing reaches it from a root field, so
`federation_sdl` never prints it and the fields don't compose. Second, it writes its
directives **un-imported** (`@federation__key`), while `@apollo/composition`
(2.14.4) asserts on the short spelling: get a `fields:` argument wrong and instead
of "Cannot query field `nosuchfield` on type `User`" you get `Error: Unexpected
element: federation__key` and a JS stack. Only the diagnosis is lost — adding
`@link(import: ["@key", "@provides"])` gets the real message back.

**Everyone else's.** From the team that runs it: a file they publish, `rover
subgraph fetch` against their endpoint, or your schema registry.

**Composed.** [`rover supergraph compose`](https://www.apollographql.com/docs/rover/commands/supergraphs)
reads a config naming each subgraph's routing url and SDL file, and prints the
supergraph to stdout:

```yaml
# supergraph-config.yaml
federation_version: =2.14.4   # rover wants an exact one
subgraphs:
  accounts:
    routing_url: https://accounts.internal/graphql
    schema: { file: ./accounts.graphql }
```

```sh
rover supergraph compose --config supergraph-config.yaml \
  --elv2-license accept > supergraph.graphql
```

`--elv2-license accept` accepts the Elastic license on the composition binary rover
downloads; without it rover asks, and a CI job has nobody to answer. Commit the
result — from here it is an ordinary schema dump, and
[`federation:diff`](#has-the-supergraph-been-recomposed) is what catches it going
stale. Already on a node toolchain? `@apollo/composition` composes in-process with
no rover install; the suite does it that way, in
[`recompose.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/support/federation/recompose.rb)
driving [`compose.mjs`](https://github.com/dpep/graph_weaver/blob/main/spec/support/federation/compose.mjs).

## Has the supergraph been recomposed?

A committed supergraph is a snapshot of a composition. Change a subgraph and skip
the recompose and it quietly describes a graph that no longer exists — the failure
that bites a federated app mid-migration, and the one the other checks don't ask
about. `verify` asks whether the generated Ruby is fresh, `schema:diff` whether
whatever your dump came from has drifted, `queries:check` whether drift broke a
query. This asks whether the supergraph still describes your subgraphs, reading the
routing table and the subgraph schemas loaded in this process — **no network** —
and exiting non-zero on drift, so CI can gate on it:

```
$ rake graph_weaver:federation:diff
supergraph.graphql: 1 stale, 1 shape, 1 not composed in (checked 1 of 3 subgraphs)

stale — the supergraph carries these, no schema here defines them (recompose):
  Product.weight (products)

shape — both carry these, with different types (recompose):
  Warehouse.code (inventory): String! in the supergraph, ID! here

not composed in — a schema here defines these, the supergraph doesn't carry them:
  Product.dimensions (Products::Schema)

not checked — no schema here matches what the supergraph says only these resolve (running elsewhere, or the subgraph is gone):
  shipping (Shipment, Shipment.eta, Order.shipment)

not checked — answered with fabricated data:
  reviews
```

Three kinds, because they mean different things: **stale** is "recompose",
**shape** is "recompose" for a field neither side dropped, and **not composed in**
is "publish the subgraph". Stale and shape name the subgraph the supergraph blames.
Field-set comparison is deliberately looser than equality, since a subgraph carries
plumbing no supergraph has and a field can legitimately sit in more than one
(`@external` copies, `@shareable`), so one candidate schema agreeing settles it.

**A supergraph is routinely only partly local**, so the report counts three states:
checked, not here, and [faked](#a-supergraph-only-partly-local). Only drift fails
the task — absence is a supported setup — but checking **none** of them fails too,
since "checked 0 of 4" attached to exit 0 is a gate that passes whatever the
subgraphs say. The mirror of that is a subgraph **retired** from the composition
whose Ruby class is still loaded: every check walks the supergraph's subgraph list,
so that one sits on the side nothing looks at, and it is named on stderr as `not
placed`. A warning rather than drift, deliberately — a process that loads a
subgraph of a supergraph this run never reads is the same picture. (A schema is a
subgraph here if it serves `Query._service`.)

**Every `federation:*` task finds the supergraph the same way**: once per declared
graph whose schema is a composed one, each report headed with that graph's name. A
graph that is in none is simply not a subject for these tasks.
`SUPERGRAPH=supergraph.graphql` overrides that for one run and reaches the
`federation:*` tasks and **nothing else** — every other task reads the schema its
graph declares, and one pointed at an ad-hoc supergraph would collapse a
multi-graph app into a single unnamed graph, so they refuse it rather than ignore
it. To check queries against a supergraph, declare it:
`GraphWeaver.graph(:api) { schema "supergraph.graphql" }`.

`Drift` is the API under the task, and it takes the same `subgraphs:` map
[`Testing::Router`](#the-local-router) does — which matters twice. **Name the schema
whenever you are diffing a *proposal***, since detection unions every loaded schema
that fits a subgraph, so a console session holding both the changed SDL and the
unmodified class reports clean. And because `Drift` **never calls a resolver**, it
takes what the router can't — a **subgraph SDL** from a non-Ruby team loads into a
resolver-less schema it compares like any other:

```ruby
require "graph_weaver/federation"   # the rake tasks do this for you

GraphWeaver::Federation::Drift.new(
  supergraph: "supergraph.graphql",
  subgraphs: { "products" => Products::Schema, "inventory" => :fake,
               "accounts" => GraphWeaver::SchemaLoader.load(File.read("accounts.graphql")) },
).report
```

`#to_h` is the JSON-ready `{"stale" => …, "shape" => …, "uncomposed" => …,
"skipped" => …, "faked" => …}` — a `shape` entry is `{"subgraphs" => […],
"supergraph" => "String!", "here" => ["ID!"]}` — `#drift?` is what the task exits
on, and `#unplaced` is the warning above rather than drift.

### What federation:diff can't see

**What is compared is a coordinate's presence and its type, and nothing else.** The
`@key` it is part of, a field's arguments, its directives, and everything a type
says about itself beyond its fields are not read, and a change to any of them
reports clean. Two ordinary subgraph edits land in that gap, and both break the
*next* composition while the report stays green: a **`@key` added, removed or
turned `resolvable: false`** is a directive, so nothing here reads it (the last of
those makes recomposition impossible and still reports clean); and a **field one
subgraph adds that another already owns, neither marked `@shareable`**, is
invisible because the coordinate is already in the supergraph, so "not composed in"
doesn't fire, while its original owner still declares it, so neither does "stale".

So **`federation:diff` answers "did you forget to recompose the schema you have",
never "would the next recompose succeed"** — the second question needs the JS
composer, a network and npm dependency this deliberately doesn't take. A clean
report says so on its own line rather than leaving you to infer it:

```
supergraph.graphql: matches the schemas here, field for field and type for type (checked 3 of 3 subgraphs)
not compared: @key (added, removed, or made unresolvable), and one field two subgraphs define without @shareable — recompose to catch those
```

An `@override` migration is asymmetric for the same reason: a supergraph published
*ahead* of the code is caught (the old side's field is `stale`), but code ahead of
the supergraph is not, because both sides carry the field and its type and only the
`@override` marker says ownership is moving. **Finish an `@override` migration from
the old side** — deleting the *new* side's copy first hands ownership back to the
subgraph you were migrating away from, and every check reports clean because the
coordinate never moved.

### Two changes every gate calls clean

`federation:diff` reads coordinates and types; `queries:check` and `generate` read
what a query *says*. Two ordinary schema changes fall between them, and on both,
`schema:diff`'s `breaking: true` line is the only warning anyone gets — once, in
the run that first sees it:

- **A scalar swapped for one that serializes the same way.** `Widget.price` going
  `String!` → `Currency!` leaves a client that hasn't regenerated with
  `const :price, String`, which a `Currency` arriving as a JSON string — `"$19.99"`
  where `"19.99"` used to be — satisfies exactly. Sorbet asks whether it is *a*
  String, which it is, and `"$19.99".to_f` is `0.0`. Regenerating surfaces it, and
  only if the client [registers the scalar](scalars.md#registering-a-class-of-your-own).
- **An enum value removed.** `queries:check` and `generate` are clean for every
  query that selects a `status` field without naming `ACTIVE` in the document —
  validation has nothing to check a value against unless the value is written down.
  The generated `T::Enum` keeps the constant and keeps deserializing it; the server
  simply never sends it again.

So a supergraph owner announcing either of these should not expect a client's CI to
notice. Deprecate first: `schema:diff` reports a deprecation's arrival, and that is
the one place it shows up, since generated code carries no trace of it.

## In CI

`federation:diff` needs no network, so it belongs beside the other checks in the
normal PR run — the [GitHub Actions job](getting_started.md#5-verify-in-ci) has the
step. Add it where the subgraph classes live: an app that only *calls* the gateway
loads none of them, and the task aborts rather than pass having checked nothing.

**What that job does not do is look at the schema production is serving**, and on a
federated graph nothing here can: every check in it compares the app to artifacts
checked in beside it. `schema:diff` is the one that reads a live source, and it
can't be pointed at a supergraph — a composed supergraph records no source url
because no endpoint serves one, and a production router refuses introspection by
default. Hot-reload a router onto a supergraph that dropped a field your queries
select and all of it still exits 0 while every one of those requests fails.

That gap is Apollo's to close, and it has two commands for it:

```sh
rover subgraph check my-graph@prod --name products --schema products.graphql
rover supergraph fetch my-graph@prod   # then recompose and diff what you get back
```

`rover subgraph check` asks GraphOS whether publishing this subgraph would break the
composition or a client operation registered against the variant — the pre-merge
half. `rover supergraph fetch` hands you the supergraph the router is running, which
is what `federation:diff` should be pointed at when the question is "does the
deployed graph still answer my queries".

Nothing in this gem talks to GraphOS, so without them the runtime is where a
federated app finds out: a query the served supergraph rejects comes back with
`schema_stale?` true and a message naming the repair
([errors → stale schemas](errors.md#stale-schemas)). That is detection at the point
of damage, which is why those two commands belong in the same job as the five tasks.

## Details

### The routing table

Stripping the machinery answers "what does this graph look like". The other question
a supergraph answers is "who resolves what", and `SchemaLoader.routing_table` keeps
that side rather than discarding it:

```ruby
table = GraphWeaver::SchemaLoader.routing_table("supergraph.graphql")

table.subgraphs                                # => ["accounts", "products", "reviews"]
table.owners("Product", "shippingEstimate")    # => ["reviews"]
table.owners("User", "username")               # => ["accounts"] — the @external copy isn't an owner
table.keys("User", "accounts")                 # => [["id"]]
table.field("Product", "shippingEstimate").requires  # => "price weight"
table.possible_types("Purchasable", "products")      # => ["Bundle", "Product"]
```

Subgraphs are named the way `@join__graph(name:)` names them — the strings a router
config and `rover` use, not the SDL's uppercase enum spelling. A `@key` field set
comes back as dotted paths (`"id organization { id }"` → `["id",
"organization.id"]`). A field with no `@join__field` at all lives wherever its type
does; that omission is how the composer says "everywhere". `possible_types` answers
the abstract side, from `@join__unionMember`/`@join__implements`, and is `nil` where
the supergraph doesn't say — a different fact from "none". A `@join__` directive the
table hasn't been taught lands in `#unsupported` rather than being skipped, and
callers refuse on a non-empty list: a table that silently ignores half a spec
version answers confidently and wrongly. `#interface_objects` is the one construct
kept out of that list (`{"Media" => ["catalog"]}`), being a fact about one *type*
rather than about the table — the router refuses the queries that reach it and plans
the rest.

The table is also what a good error message wants. When the schema dump is a
composed supergraph, `rake graph_weaver:queries:check` brands each validation error
with the subgraphs behind the type it names, and `check_queries` carries the same
list as a `"subgraphs"` key:

```
app/graphql/queries/product.graphql
  4:5  Field 'dimensions' doesn't exist on type 'Product' (products, reviews)
```

### What it plans

An operation that resolves in **one subgraph** goes over verbatim. One that
**crosses a boundary** is split at the crossing: the plan injects the entity's
`@key` under a reserved alias, refetches it from the owning subgraph through
`_entities(representations:)`, and stitches the answer back. Every node at one level
goes in **one** `_entities` call, so a list of users and all their reviews' products
is three fetches, not one per row. Root fields that resolve in different subgraphs
get one fetch each, and a `@provides` copy is read in place.

A **`@requires` field set** is supplied by the router rather than by the subgraph
that declares the field, so it's a fetch before the fetch:

```ruby
router.reset_trace
router.execute("{ reviews { product { shippingEstimate } } }")
router.trace.map { _1[:subgraph] }   # => ["reviews", "products", "reviews"]
```

`shippingEstimate` resolves in `reviews` and `@requires "price weight"`, which
`products` owns — so the plan fetches those into hidden keys, hands them back in the
representation, and only then asks for the estimate. One hop only: the key for the
first fetch has to come from the subgraph already in hand, so a chain can't grow a
chain. Two `@requires` sets crossing into the same subgraph on the same `@key` ride
one prefetch, as Apollo's do.

A **nested field set** — `@key(fields: "id organization { id }")` — crosses as one
object: the fetch asks for `organization { id }` under a reserved alias, and the
representation carries it back in the shape the SDL spells, to any depth, nulls and
all. Where a type has more than one `@key`, the plan takes the first the fetching
subgraph can supply.

A **union or interface at a boundary** is planned per concrete type, because a
representation names one `__typename` and which one an object has isn't in the
query:

```ruby
router.reset_trace
router.execute("{ purchasables { name ... on Product { reviews { body } } } }")
router.trace.map { _1[:subgraph] }   # => ["products", "reviews"]
```

The plan holds a branch per type the supergraph says that subgraph can answer with;
the fetch asks for `__typename` under a reserved alias and buckets what comes back
by it — one `_entities` fetch per concrete type, none for an empty bucket. A
fragment whose condition can't hold there is dropped, as a real router drops it.

Three things it does that a naive merge doesn't, and that being wrong about would be
worse than refusing: it **re-applies GraphQL's null propagation** to the merged tree,
where a stitched fetch can put a null the composed schema says can't be there and no
subgraph is in a position to notice; it **re-paths errors and stamps the subgraph**,
so a subgraph's `_entities.2.shippingEstimate` reaches you as
`topProducts.2.shippingEstimate` with `extensions.service` naming it (whatever the
resolver put in `extensions` is left alone, and `locations` are dropped rather than
pointing into a query you never wrote — that is for a `GraphQL::ExecutionError`, and
a resolver raising anything else propagates out of `execute` as a Ruby exception);
and a field **`@skip`/`@include` removes comes back absent, not null**. Introspection
is answered from the composed API schema, never from a subgraph, which is the one
split a real router also makes.

**A wire fault at one subgraph has no representation here.** A subgraph is a Ruby
call, not a socket: `:router` fetches in-process, and `:wire` stubs one endpoint in
front of the whole router. So a timeout, an HTTP 500, malformed JSON, or a bare
`errors` with no `data` — anything that is a property of the *transport* to one
subgraph — is out of reach. A subgraph that *fails* is expressible (raise from its
resolver, or fake it), but partial availability is a gateway's property, not this
double's.

### How faithful is it, really

A double that quietly answered *differently* from the router would be worse than no
double at all, so
[`spec/integration/router_parity_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/integration/router_parity_spec.rb)
(`make integration`, node required) serves the demo subgraphs over HTTP, boots a
real `@apollo/gateway` on the same supergraph, and runs the whole corpus through
both — plus boundary probes and queries where a subgraph deliberately **fails**,
the cases where a merge that doesn't re-propagate hands back a populated tree while
the real router answers `data: null`. Match, refuse, or answer differently: the
spec fails on the third.

**But "a real router" is two things, and they disagree** — and a production one
shows you less than either. Everything above is measured against `@apollo/gateway`,
the deprecated JS gateway; the Rust Apollo Router differs on a subgraph 500's error
shape, on malformed JSON from a subgraph, on `@defer` (it supports it, behind an
`Accept: multipart/mixed` header) and on introspection, which it disables by
default — and with `include_subgraph_errors` omitted it answers `{"message" =>
"Subgraph errors redacted", "path" => […]}` where this router hands you the
subgraph's own message and its `service` stamp. So run a refusal you're unsure
about against the router you deploy, and assert on `path` rather than a message
that only survives locally:
[testing → production redacts what this router hands you](testing.md#production-redacts-what-this-router-hands-you).

### Is it worth wiring up? Measure.

The router's value is one number — the fraction of *your* queries it can plan — and
that depends on the shape of your graph and of your queries, so measure it rather
than guess:

```
$ rake graph_weaver:federation:coverage
17/17 queries plannable locally (100%), 17 servable here
  accounts 4, reviews 4, products+reviews 3, accounts+reviews 2, products 2, accounts+products 1, accounts+products+reviews 1
```

**Two numbers, because they answer different questions.** *Plannable* is about the
graph — could the router split this query faithfully at all. *Servable here* is what
your suite actually gets: every subgraph that plan reaches is one this process
serves. In a [partly-local supergraph](#a-supergraph-only-partly-local) they differ,
and the plannable number alone reads optimistically — so the report lists the
queries that plan but reach a subgraph nothing here serves, each with the subgraph
that stopped it and the three ways out (name a schema, fake it, or run it against a
real router).

`QUERIES=` picks the directory; by default each graph's report measures that graph's
own `queries`, since a query written against one supergraph says nothing about the
next one along. Planning needs the supergraph and nothing else, so this runs in CI
with the SDL alone — with no subgraph loaded the report drops the second number and
says it counted planning only. Anything refused is listed grouped by category, so
one glance says whether the gap is one construct or many. (The run above is the demo
graph in `spec/support/federation`, not a real app's mix.)
