# Testing

One line in your spec helper:

```ruby
require "graph_weaver/rspec"
```

Then **one tag says what an example runs against** — on the example, or on
the group it belongs to, since rspec metadata inherits:

```ruby
describe "checkout", graphql: :router do
  it "stitches the dashboard" do … end     # every example here, too
end

it "renders the empty state", graphql: :fake do … end
it "authorizes drafts",       graphql: :in_process do … end
```

| mode | reach for it when | what it costs |
|---|---|---|
| `graphql: :fake` | most unit tests — you need *a* well-shaped response | no resolver code runs |
| `graphql: :in_process` | the point of the test is that your resolver logic works | slower; needs a live schema class |
| `graphql: :router` | the same, across a federated graph | needs a composed supergraph; [refuses](#what-it-refuses) shapes it can't plan faithfully |
| [cassettes](cassettes.md) | pinning a real server's exact response | must be re-recorded when the query changes |

The tag installs its client as `GraphWeaver.client` for that example and
restores the previous one after, so generated modules run against it with
zero per-test setup. (Generate them *without* a baked `client:` — a module
that has one never consults `GraphWeaver.client`.) `rspec --tag
graphql:router` runs one mode's examples; an untagged example is left
alone unless you set `config.default_mode`.

Everything here is a *client* — the one interface queries run through:
anything with `execute(query, variables:, operation_name:)` returning
`{"data" => ..., "errors" => ...}` (see [transports](transports.md)). Fakes,
the router, failures, and cassettes all slot in wherever a real transport
would, so they work outside rspec too (`require "graph_weaver/testing"` —
never from production code).

## Nothing to configure

Each mode works out what to run against, and **refuses — naming what it
looked for — rather than guessing**:

- **the schema** is `config.schema` if you set one, else the committed dump
  at `GraphWeaver.schema_path`, else the schema `GraphWeaver.client` talks to.
- **`:in_process`** needs the live schema *class*, since only that has
  resolvers: the one your client already runs in-process, else the loaded
  class that defines everything the schema declares — the same
  derive-verify-refuse rule that [maps subgraphs](#which-schema-serves-which-subgraph).
- **`:router`** plans against the composed supergraph. If your committed
  dump *is* one (it carries `@join__*` markers), that's it — no config at
  all. Subgraphs are derived either way.

A client can't supply a supergraph, and the refusal says why:

```
:router needs the composed supergraph SDL — a client's schema is the API schema
the router serves, with the @join__* routing table stripped out, so the
supergraph has to be named. app/graphql/schema.json carries no @join__*
markers. Set GraphWeaver::Testing.config.router = { supergraph: "supergraph.graphql" }.
```

So configure only to override a derivation, or to tune fabricated values:

```ruby
GraphWeaver::Testing.configure do |config|
  # config.schema = MySchema         # the live class, rather than the dump
  # config.router = { supergraph: Rails.root.join("supergraph.graphql") }
  # config.context = { tenant: }     # baseline context every example starts from
  # config.default_mode = :fake      # what an UNtagged example runs against
  # config.mode = :faker             # or :literal (plain typed values); nil = auto
  # config.overrides = { "Person.name" => "Daniel" }
  # config.list_size = 1..3
  # config.null_chance = 0.1         # nullable fields go nil sometimes
end
```

All three modes, tagged and running end to end, are in
[`spec/rspec_spec.rb`](../spec/rspec_spec.rb).

## The context your resolvers see

`graphql_context` is available in every example. It **merges** onto
`config.context` — the baseline survives unless you override a key — and is
**reset before the next example**, so one example running as somebody else
can't leak into the one after it:

```ruby
it "shows the owner's drafts", graphql: :in_process do
  graphql_context(current_user: alice)
  expect(DraftsQuery.execute!.drafts.size).to eq 2
end
```

Pass a block to scope it, for the example that needs two identities:

```ruby
graphql_context(admin: true) { expect(SettingsQuery.execute!.settings).to be_present }
```

Called with nothing it reads the context back. Under `graphql: :fake` it
refuses: there are no resolvers to receive a context, and silently ignoring
one would leave an example asserting on data nothing scoped.

## Fabricated data — `graphql: :fake`

`FakeClient` fabricates schema-correct responses for whatever query
arrives: real enum values, valid `__typename` members, iso8601 date scalars
— every fake casts cleanly through your generated structs.

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

`rspec --seed 1234` reproduces fake data along with test order. `config.mode`
picks value fabrication: `:faker` (semantic, field-name matched — raises if
the gem is missing), `:literal` (plain type-derived), or nil to auto-detect
faker.

Need the schema itself inside an example — to sample a field, or build a
query on the fly? The client in play exposes it as
`GraphWeaver.client.schema`, and `GraphWeaver::Testing.config.schema` reads
back what `config.schema =` set, falling back to the committed dump.

Test-only generated modules don't have to live in `app/` —
`generated_paths` is an appendable list, so the same support file can
register a spec-local set that `load_generated!` (and the Railtie) pick up:

```ruby
GraphWeaver.generated_paths << "spec/support/graphql/generated"
```

## Simulating failures

Every failure mode is just a client, so
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

## Capture and replay

Cassettes record real API responses and replay
them offline, above the transport (no HTTP interception):

```ruby
# records against the live client when the file is missing, replays after
client = GraphWeaver::Testing.cassette("github", client: live)
```

Re-record with `GRAPHWEAVER_RECORD=1`, and set `config.anonymize = true` so
real data never lands in a committed file — the full workflow guide is
**[cassettes](cassettes.md)**.


## Real resolvers, one schema — `graphql: :in_process`

Your actual resolvers, your actual `context`, in the same process — no
socket, no serialization, and a resolver's real backtrace when it raises.

```ruby
it "hides other people's drafts", graphql: :in_process do
  graphql_context(current_user: alice)
  expect(DraftsQuery.execute!.drafts.map(&:owner)).to all(eq alice.name)
end
```

The live schema *class* is found for you (a schema dump has no resolvers,
so it won't do). If two loaded classes match, or none does, it says so and
asks for `config.schema = MySchema` — and in Rails, remember that an
autoloaded schema isn't loaded until something references it.

## The in-process router — `graphql: :router`

If your app is a client of a **federated** graph, its subgraphs are Ruby
schema classes you can run in-process. `Testing::Router` takes the composed
supergraph and those classes and satisfies the client contract, so every
generated module runs against the real resolvers — no gateway, no node, no
sockets. It is not a mock: your resolvers run, which is the whole point.

```ruby
describe "the dashboard", graphql: :router do
  it "stitches a user's reviews" do
    graphql_context(current_user: user)
    expect(DashboardQuery.execute!.me.reviews.size).to eq 2
  end
end
```

The router is built once for the suite (parsing a supergraph per example
would be real time) and installed as `GraphWeaver.client` for each; its
context is reset from `config.context` every time, so an example that runs
as someone else can't leak into the next. Outside rspec, build one yourself:

```ruby
GraphWeaver.client = GraphWeaver::Testing::Router.new(
  supergraph: Rails.root.join("supergraph.graphql"),
  context: { current_user: user },
)
```

### Which schema serves which subgraph

`subgraphs:` is optional. Left out, each one is **derived from what the loaded
schemas define**: a schema serves subgraph `s` when it defines every type and
field the routing table says `s` resolves. That's evidence rather than a guess
— matching on class names would be one (`Accounts::Schema`, `AccountsSchema`,
`Subgraphs::Accounts`), and a wrong guess points a suite at the wrong resolvers
and still passes. So exactly one match is used, and anything else refuses,
naming the candidates or what it looked for.

Name them yourself when you'd rather have the wiring committed, or when
detection can't settle it — including partially, with the rest derived:

```ruby
subgraphs: { "accounts" => Accounts::Schema }   # products, reviews derived
```

Either way the map is **checked**: a schema that doesn't define what the
supergraph says its subgraph resolves fails at construction, naming what's
missing, rather than surfacing as a mystery three fetches later.

```
subgraphs["accounts"] is Products::Schema, which doesn't define User,
User.email, User.username, Query.me, Query.user and 1 more — the supergraph
says accounts resolves them. Did two entries get swapped?
```

Detection only sees what's **loaded**, and in Rails an autoloaded schema isn't
until something references it — so the not-found message says so. To see what
detection sees (and get a map to paste):

```
$ rake graph_weaver:federation:subgraphs SUPERGRAPH=supergraph.graphql
subgraphs: {
  "accounts" => Accounts::Schema,  # matched: defines Query.me, Query.user, Query.users
  "products" => Products::Schema,  # matched: defines Product.name, Product.price, Product.weight
  "reviews" => nil,                # no loaded schema defines Query.feed, Review.author, Query — fill this in
}
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

A **`@requires` field set** is supplied by the router rather than by the
subgraph that declares the field, so it's a fetch before the fetch:

```ruby
router.execute("{ reviews { product { shippingEstimate } } }")
router.trace.map { _1[:subgraph] }   # => ["reviews", "products", "reviews"]
```

`shippingEstimate` resolves in `reviews` and `@requires "price weight"`, which
`products` owns — so the plan fetches those into hidden keys, hands them back
in the representation, and only then asks for the estimate. One hop: the key
for the first fetch has to come from the subgraph already in hand, so a chain
can't grow a chain. When that first fetch finds no entity the required fields
don't exist, so the field that needs them is null and propagation takes it from
there.

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
User.reviews is fetched on User's "id", and this selection aliases username as
"id" over it — Apollo's router resolves that collision in favour of its own
injected key and a spec-conformant server doesn't, so there is no one answer to
agree with. Rename the alias.
```

What's left, and why:

| Refusal | Why |
|---|---|
| an alias shadowing an injected `@key` | Apollo's router lets its injected key win over your alias and a spec-conformant server doesn't — there is no one answer to agree with |
| an abstract type at a boundary | a representation names one concrete `__typename`, and the router doesn't resolve a type per object to build one |
| a nested `@key`/`@requires` field set | representations are built from flat field sets only |
| no usable `@key` | nothing to build a representation from |
| a mutation whose root fields span subgraphs | root mutation fields run in series, and splitting them would run them in whatever order the plan happened to (query roots are independent, so those are fine) |

It also refuses at construction, before a single query, a supergraph carrying
a `@join__*` construct the routing table hasn't been taught — an incomplete
table makes every answer a guess — and any subgraph map it can't settle
(above).

Introspection is answered from the composed API schema, never from a subgraph,
which would reply with its own slice — the one split a real router also makes.

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
A second example checks the gateway answers every refusal cleanly, so each is a
capability gap rather than a broken query, and a third pins the ten queries the
pass-through router used to answer: still one fetch each, still identical.
`make integration` runs it (node required).

The five deliberate failures are the ones that matter most. A resolver that
errors under a stitched fetch, an entity nothing can resolve, and a `@requires`
fetch that comes back empty all put a null where the composed schema says
non-null — and a merge that doesn't re-propagate hands back a populated tree
where the real router answers `data: null`. That is the failure mode this whole
design exists to make impossible, so it's tested against the real thing rather
than against an expectation someone wrote down.
