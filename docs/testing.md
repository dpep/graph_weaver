# Testing

Everything here is a *client* — the one interface queries run
through: anything with `execute(query, variables:, operation_name:)` returning
`{"data" => ..., "errors" => ...}` (see [transports](transports.md)).
Fakes, failures, and cassettes all slot in wherever a real transport
would.

`require "graph_weaver/rspec"` from your spec helper (or
`graph_weaver/testing` outside rspec — never in production) for a
zero-setup fake backend. `FakeClient` fabricates
schema-correct responses for whatever query arrives: real enum values,
valid `__typename` members, iso8601 date scalars — every fake casts
cleanly through your generated structs.

```ruby
fake = GraphWeaver::Testing::FakeClient.new   # schema: falls back to Testing.config

person = PersonQuery.execute!(fake, id: "1").person
person.name       # => "Eliza Kertzmann" (faker-matched on field name, when faker is loaded)
person.birthday   # => a real Date
```

Pin what matters, keyed by GraphQL names (schema vocabulary — keys
survive query refactors); `"Type.field"` beats `"field"`:

```ruby
GraphWeaver::Testing::FakeClient.new(schema:, overrides: {
  "Person.name" => "Daniel",
  "email" => -> { "test@example.com" },
})
```

Keys are checked against the schema, spellchecked — `"Person.nmae"` raises
rather than quietly pinning nothing and leaving the example green against
random data.

With rspec, the setup is two lines in `spec/support/graph_weaver.rb` —
the require, plus an explicit opt-in to per-example fakes (deliberately
not a default: silently swapping every example onto a fake would be
surprising). The schema auto-locates from the committed dump at
`GraphWeaver.schema_path`:

```ruby
require "graph_weaver/rspec"   # seed follows --seed

GraphWeaver::Testing.configure do |config|
  config.auto_fake = true              # every example runs against a fresh fake
  # config.schema = MySchema           # the live class instead of the dump
  # config.mode = :faker               # or :literal (plain typed values); nil = auto
  # config.overrides = { "Person.name" => "Daniel" }
  # config.list_size = 1..3
  # config.null_chance = 0.1           # nullable fields go nil sometimes
end
```

In an app that serves its own schema, set `config.schema` to the live class:
fakes are then fabricated from the schema the app actually runs, so they can't
drift from it the way a stale committed dump can.

With the rspec integration, `rspec --seed 1234` reproduces fake data
along with test order, and `auto_fake` installs a seeded fake as the
app client per example (generate modules *without* a baked `client:` so
they consult `GraphWeaver.client`). `mode:` picks value fabrication: `:faker`
(semantic, field-name matched — raises if the gem is missing),
`:literal` (plain type-derived), or nil to auto-detect faker.

Need the schema itself inside an example — to sample a field, or build a
query on the fly? `GraphWeaver::Testing.config.schema` reads back what
`config.schema =` set, falling back to the committed dump; under
`auto_fake` the client in play exposes the same object as
`GraphWeaver.client.schema`.

Test-only generated modules don't have to live in `app/` —
`generated_paths` is an appendable list, so the same support file can
register a spec-local set that `load_generated!` (and the Railtie) pick up:

```ruby
GraphWeaver.generated_paths << "spec/support/graphql/generated"
```

**Simulating failures** — every failure mode is just a client, so
error-handling paths are testable without a server that misbehaves on cue:

```ruby
Failure = GraphWeaver::Testing::Failure

PersonQuery.execute(Failure.transport, id: "1")             # TransportError (cause preserved)
PersonQuery.execute(Failure.server(status: 502), id: "1")   # ServerError
PersonQuery.execute(Failure.throttled, id: "1")             # QueryError, code THROTTLED
PersonQuery.execute(Failure.stale_schema, id: "1")          # schema_stale? => true
PersonQuery.execute(Failure.graphql("boom", data: {...}), id: "1")  # partial failure

# retries: clients run in sequence (the last repeats) — here, two
# transport failures and then a FakeClient serving good responses
fake = GraphWeaver::Testing::FakeClient.new(schema:)
GraphWeaver::Testing::Sequence.new(Failure.transport, Failure.transport, fake)

# type mismatch: corrupt: derives a wrong-typed wire value for the field —
# casting raises GraphWeaver::TypeError (overrides remain the manual escape hatch)
GraphWeaver::Testing::FakeClient.new(schema:, corrupt: "Person.birthday")

# stale schema naming a real (sampled) field
Failure.stale_schema(schema: MySchema)

# field-level partial failure with real GraphQL null propagation: the error
# lands with its concrete path and nulls bubble to the nearest nullable spot
GraphWeaver::Testing::FakeClient.new(schema:, fail_at: { path: "person.email", code: "PRIVATE" })
```

**Capture and replay** — cassettes record real API responses and replay
them offline, above the transport (no HTTP interception):

```ruby
# records against the live client when the file is missing, replays after
client = GraphWeaver::Testing.cassette("github", client: live)
```

Re-record with `GRAPHWEAVER_RECORD=1`, and set `config.anonymize = true` so
real data never lands in a committed file — the full workflow guide is
**[cassettes](cassettes.md)**.


## A local federation router

If your app is a client of a **federated** graph, its subgraphs are Ruby
schema classes you can run in-process. `Testing::Router` takes the composed
supergraph and those classes and satisfies the client contract, so every
generated module runs against the real resolvers — no gateway, no node, no
sockets:

```ruby
GraphWeaver.client = GraphWeaver::Testing::Router.new(
  supergraph: Rails.root.join("supergraph.graphql"),
  subgraphs: { "accounts" => Accounts::Schema, "products" => Products::Schema },
  context: { current_user: user },
)
```

Fakes fabricate plausible data; this runs your actual resolvers, with your
actual `context`, against the schema the router serves. `router.trace` records
the fetches one `execute` made, in order (subgraph, query, variables) — the same
lines go to `GraphWeaver.logger` at `:debug`.

### What it plans

An operation that resolves in **one subgraph** goes over verbatim. One that
**crosses a boundary** is split at the crossing: the plan injects the entity's
`@key` under a reserved alias, refetches it from the owning subgraph through
`_entities(representations:)`, and stitches the answer back.

```ruby
router.execute("{ me { username reviews { id body } } }")
router.trace.map { _1[:subgraph] }   # => ["accounts", "reviews"]
```

Every node at one level goes in **one** `_entities` call, so a list of users
and all their reviews' products is three fetches, not one per row. Root fields
that resolve in different subgraphs get one fetch each. A `@provides` copy is
read in place — the router does that too, so nothing leaves the subgraph for a
field the copy already holds.

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

### What it refuses

Everything it can't plan **faithfully** raises
`GraphWeaver::Testing::Unplannable` (a `GraphWeaver::Error`), at plan time,
before any subgraph runs — so a refusal is never a half-executed query.
Apollo's planner is ~20k lines; a double that approximated the rest of it would
let a test pass on an answer production disagrees with, which is the most
expensive thing this library can produce.

```
Product.shippingEstimate runs in reviews and @requires "price weight", which
reviews doesn't hold (price, weight come from products) — the router fetches
those first and hands them back, a chain the local router doesn't plan. Run
this one against a real router.
```

What's left, and why:

| Refusal | Why |
|---|---|
| `@requires` needs a fetch chain | one pass isn't enough — the fields have to be fetched elsewhere and handed back before the owning subgraph can run |
| an abstract type at a boundary | a representation names one concrete `__typename`, and the router doesn't resolve a type per object to build one |
| an alias shadowing an injected `@key` | Apollo's router lets its injected key win over your alias and a spec-conformant server doesn't — there is no one answer to agree with |
| a nested `@key`/`@requires` field set | representations are built from flat field sets only |
| no usable `@key` | nothing to build a representation from |
| a mutation whose root fields span subgraphs | root mutation fields run in series, and splitting them would run them in whatever order the plan happened to (query roots are independent, so those are fine) |

Two things it refuses at construction, before a single query: a supergraph
carrying a `@join__*` construct the routing table hasn't been taught (an
incomplete table makes every answer a guess), and a `subgraphs:` hash that
doesn't name every subgraph in the supergraph.

Introspection is answered from the composed API schema, never from a subgraph,
which would reply with its own slice — the one split a real router also makes.

### Is it worth wiring up? Measure.

The router's value is one number — the fraction of *your* queries it can plan —
and that depends on the shape of your graph and of your queries, so measure it
rather than guess:

```
$ rake graph_weaver:federation:coverage SUPERGRAPH=supergraph.graphql
16/17 queries plannable locally (94%)
  accounts 4, reviews 4, accounts+reviews 2, products 2, products+reviews 2, accounts+products 1, accounts+products+reviews 1

refused (1)

  @requires needs a fetch chain (1)
    reviewed_product_shipping.graphql  Product.shippingEstimate runs in reviews and @requires "price weight", ...
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
them a defect: match, refuse, or answer differently. On 39 queries — the corpus,
seventeen boundary probes, and four where a subgraph deliberately fails — the
local router is byte-identical to the gateway on 37, refuses 2, and is wrong on
none. A second example checks the gateway answers every refusal cleanly, so each
is a capability gap rather than a broken query, and a third pins the ten queries
the pass-through router used to answer: still one fetch each, still identical.
`make integration` runs it (node required).

The four deliberate failures are the ones that matter most. A resolver that
errors under a stitched fetch, and an entity nothing can resolve, both put a
null where the composed schema says non-null — and a merge that doesn't
re-propagate hands back a populated tree where the real router answers
`data: null`. That is the failure mode this whole design exists to make
impossible, so it's tested against the real thing rather than against an
expectation someone wrote down.
