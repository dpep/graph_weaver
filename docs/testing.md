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
the fetch each `execute` made (subgraph, query, variables) — the same line goes
to `GraphWeaver.logger` at `:debug`.

**It is not a router.** It plans exactly one shape: an operation whose every
field resolves in a **single subgraph**, handed to that subgraph verbatim.
Anything crossing a boundary raises `GraphWeaver::Testing::Unplannable` (a
`GraphWeaver::Error`), at plan time, before any subgraph runs. Apollo's planner
is ~20k lines and the interesting part is the stitching; a double that
approximated it would let a test pass on an answer production disagrees with,
which is the most expensive thing this library can produce. So it refuses:

```
User.reviews is resolved by reviews, and this operation runs in accounts — the
local router hands one query to one subgraph verbatim and doesn't stitch across
a boundary. Run this one against a real router.
```

What it *does* plan past the obvious: a `@provides` copy (the router reads that
copy too, so nothing leaves the subgraph), unions and fragments whose types are
all in one subgraph, mutations, and introspection — answered from the composed
API schema, never from a subgraph, which would reply with its own slice.

Two things it refuses at construction, before a single query: a supergraph
carrying a `@join__*` construct the routing table hasn't been taught (an
incomplete table makes every answer a guess), and a `subgraphs:` hash that
doesn't name every subgraph in the supergraph.

### Is it worth wiring up? Measure.

The router's value is one number — the fraction of *your* queries it can plan —
and that depends on the shape of your graph and of your queries, so measure it
rather than guess:

```
$ rake graph_weaver:federation:coverage SUPERGRAPH=supergraph.graphql
10/17 queries plannable locally (59%)
  accounts 4, reviews 4, products 2

refused (7)

  crosses a subgraph boundary (5)
    dashboard.graphql        User.reviews is resolved by reviews, and this operation runs in accounts
    ...

  @requires needs a fetch chain (1)
    shipping.graphql         Product.shippingEstimate runs in reviews and @requires "price weight", ...

  root fields span subgraphs (1)
    home.graphql             this operation's root fields span subgraphs: Query.me (accounts), Query.topProducts (products)
```

`QUERIES=` picks the directory (default `GraphWeaver.queries_path`). Planning
needs the supergraph and nothing else, so this runs in CI with the SDL alone —
no subgraph has to be loadable. The reasons group by category so one glance
says whether the gap is one construct or many; the run above is against the
demo graph in `spec/support/federation`, not a real app's mix.
