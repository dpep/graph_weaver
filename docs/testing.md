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
| `graphql: :router` | the same, across a federated graph | needs a composed supergraph; [refuses](federation.md#what-it-refuses) shapes it can't plan faithfully |
| [cassettes](cassettes.md) | pinning a real server's exact response | must be re-recorded when the query changes |

The tag installs its client as `GraphWeaver.client` for that example and
restores the previous one after, so generated modules run against it with
zero per-test setup. (Generate them *without* a baked `client:` — a module
that has one never consults `GraphWeaver.client`.) `rspec --tag
graphql:router` runs one mode's examples; an untagged example is left
alone unless you set `config.default_mode`. **`graphql: false` (or
`graphql: :none`) opts one example back out** of that default — nothing is
installed, so the example is free to wire its own client.

Everything here is a *client* — the one interface queries run through:
anything with `execute(query, variables:, operation_name:)` returning
`{"data" => ..., "errors" => ...}` (see [transports](transports.md)). Fakes,
the router, failures, and cassettes all slot in wherever a real transport
would, so they work outside rspec too (`require "graph_weaver/testing"` —
never from production code). Outside the tags there's no `GraphWeaver.client`
to lean on, so parse from the fake or the router itself — anything holding a
schema parses against it, and the module runs on what parsed it:

```ruby
router = GraphWeaver::Testing::Router.new(supergraph: "app/graphql/supergraph.graphql")
DashboardQuery = router.parse("query Dashboard { me { username } }")
DashboardQuery.execute!.me.username
```

All three modes, tagged and running end to end, are
[`spec/rspec_spec.rb`](../spec/rspec_spec.rb) — the reference for anything
this page leaves out.

## Nothing to configure

Each mode works out what to run against, and **refuses — naming what it
looked for — rather than guessing**:

- **the schema** is `config.schema` if you set one, else the committed dump
  at `GraphWeaver.schema_path`, else the schema `GraphWeaver.client` talks to.
- **`:in_process`** needs the live schema *class*, since only that has
  resolvers: the one your client already runs in-process, else the loaded
  class that defines everything the schema declares — the same
  derive-verify-refuse rule that
  [maps subgraphs](federation.md#which-schema-serves-which-subgraph).
- **`:router`** plans against the composed supergraph. If your committed dump
  *is* one (it carries `@join__*` markers), that's it — no config at all. A
  client can't stand in for it: a client's schema is the API schema the router
  serves, with the `@join__*` routing table stripped out, so the supergraph has
  to be named. Subgraphs are derived either way.

So configure only to override a derivation, or to tune fabricated values:

```ruby
GraphWeaver::Testing.configure do |config|
  # config.schema = MySchema         # the live class, rather than the dump
  # config.router = { supergraph: Rails.root.join("supergraph.graphql") }
  # config.context = { tenant: }     # baseline context every example starts from
  # config.default_mode = :fake      # what an UNtagged example runs against
  #                                  # (graphql: false opts one back out)
  # config.mode = :faker             # or :literal (plain typed values); nil = auto
  # config.overrides = { "Person.name" => "Daniel" }
  # config.list_size = 1..3
  # config.null_chance = 0.1         # nullable fields go nil sometimes
end
```

## The context your resolvers see

`graphql_context` is available in every example. It **merges** onto
`config.context` — the baseline survives unless you override a key — and is
**reset before the next example**, so one example running as somebody else
can't leak into the one after it.

Context is setup, so it usually belongs in a `before` block — a group of
examples sharing one identity says who they are once:

```ruby
describe "as the owner", graphql: :in_process do
  before { graphql_context(current_user: alice) }

  it "shows the drafts" do
    expect(DraftsQuery.execute!.drafts.size).to eq 2
  end

  it "counts them" do … end
end
```

The reset runs ahead of any group hook, so each example re-applies that
`before` from the same baseline rather than stacking onto the last one's
context. Set it inline for the one-off:

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

person = PersonQuery.execute!(client: fake, id: "1").person
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

Test-only generated modules don't have to live in `app/` — `generated_paths` is
an appendable list, so a support file can register a spec-local set:

```ruby
# spec/support/graph_weaver.rb
GraphWeaver.generated_paths << "spec/graphql/generated"
GraphWeaver.load_generated!   # the appended path needs this call
```

Both lines matter. In Rails the Railtie loads generated modules during boot,
which is finished before `spec/support/*.rb` runs — so a path appended here is
never loaded unless you load it. And keep the directory *outside*
`spec/support/`: rspec-rails requires every `spec/support/**/*.rb` itself, in
sorted order, so a generated module gets required before the shared `types.rb`
it needs and dies on `LoadError`.

## Simulating failures

Every failure mode is just a client, so
error-handling paths are testable without a server that misbehaves on cue:

```ruby
Failure = GraphWeaver::Testing::Failure

PersonQuery.execute(client: Failure.transport, id: "1")             # TransportError (cause preserved)
PersonQuery.execute(Failure.server(status: 502), id: "1")   # ServerError
PersonQuery.execute(client: Failure.throttled, id: "1")             # QueryError, code THROTTLED
PersonQuery.execute(client: Failure.stale_schema, id: "1")          # schema_stale? => true
PersonQuery.execute(client: Failure.graphql("boom", data: {...}), id: "1")  # partial failure

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

## A federated graph — `graphql: :router`

Same thing across a federated graph: the tag builds a
[`Testing::Router`](federation.md#the-local-router), which plans the query
across your subgraphs and runs it against those **real resolvers** — no
gateway, no node, no sockets.

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
as someone else can't leak into the next.

What it plans, what it **refuses** and why, how subgraphs are matched to your
schema classes, and what to do about a supergraph only partly local:
**[federation → the local router](federation.md#the-local-router)**.
