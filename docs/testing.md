# Testing

How to run a spec that executes a GraphQL query without a server — against
fabricated data, against your own resolvers, or across a federated graph. Read
this once when you set the suite up; after that the one thing to remember is
the `graphql:` tag.

One line in your spec helper:

```ruby
require "graph_weaver/rspec"
```

(In Rails, put it **above** the `spec/support` glob in `rails_helper.rb` —
rspec-rails requires those partway through, and a support file mentioning
`GraphWeaver::Testing` before this line dies on `NameError`.)

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
| [`:fake`](#fabricated-data--graphql-fake) | most unit tests — you need *a* well-shaped response | no resolver code runs |
| [`:in_process`](#real-resolvers--graphql-in_process) | the point of the test is that your resolver logic works | slower; needs a live schema class |
| [`:router`](#a-federated-graph--graphql-router) | the same, across a federated graph | needs a composed supergraph; [refuses](federation.md#what-it-refuses) shapes it can't plan faithfully |
| [cassettes](cassettes.md) | pinning a real server's exact response | must be re-recorded when the query changes |

The tag installs its client as `GraphWeaver.client` for that example, so
generated modules run against it with zero per-test setup. (Generate them
*without* a baked `client:` — a module that has one never consults
`GraphWeaver.client`.) `rspec --tag graphql:router` runs one mode's
examples; an untagged example is left alone unless you set
`config.default_mode`, and **`graphql: false` opts one back out** of that
default.

`GraphWeaver.client` is **snapshotted before every example and restored
after** — tagged, untagged or opted out, and whatever the example did to
it. So building your own client is a plain assignment, cleaned up like a
tagged one:

```ruby
before { GraphWeaver.client = GraphWeaver::Testing::Failure.throttled }
```

Both at once and the assignment wins: the tag installs its client from a
suite-level `before`, which rspec runs ahead of any group hook. So a tagged
example with a `before` of its own runs against the client the `before`
built — tag the group for the mode, override the one example that needs
something else.

Everything here is a *client* — the one interface queries run through (the
contract is in [transports](transports.md)). Fakes, the router, failures and
cassettes all slot in wherever a real transport would, so they work outside
rspec too (`require "graph_weaver/testing"` — never from production code).
Outside the tags there's no `GraphWeaver.client` to lean on, so parse from
the fake or the router itself — anything holding a schema parses against it,
and the module runs on what parsed it:

```ruby
router = GraphWeaver::Testing::Router.new(supergraph: "app/graphql/supergraph.graphql")
DashboardQuery = router.parse("query Dashboard { me { username } }")
DashboardQuery.execute!.me.username
```

All three modes, tagged and running end to end, are
[`spec/rspec_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/rspec_spec.rb) — the reference for anything
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
  # config.router = { subgraphs: { "reviews" => :fake } }   # either key alone
  # config.context = { tenant: }     # baseline context every example starts from
  # config.default_mode = :fake      # what an UNtagged example runs against
  #                                  # (graphql: false opts one back out)
  # config.mode = :faker             # or :literal (plain typed values); nil = auto
  # config.seed = 4242               # defaults to rspec's own --seed
  # config.overrides = { "Person.name" => "Daniel" }
  # config.list_size = 1..3
  # config.null_chance = 0.1         # nullable fields go nil sometimes
end
```

Need the schema itself inside an example — to sample a field, or build a
query on the fly? The client in play exposes it as
`GraphWeaver.client.schema`, and `GraphWeaver::Testing.config.schema` reads
back what `config.schema =` set, falling back to the committed dump.

## Fabricated data — `graphql: :fake`

`FakeClient` fabricates schema-correct responses for whatever query
arrives: real enum values, valid `__typename` members, and — for a custom
scalar — a value the Ruby type you registered it as can hold, so every fake
casts cleanly through your generated structs. `@skip`/`@include` are
evaluated against the variables you passed (defaults included), so a field
the server would leave out is left out. `rspec --seed 1234` reproduces the
values along with test order. `config.mode` picks how
they're built: `:faker` (semantic, matched on the field name — raises if the
gem is missing), `:literal` (plain type-derived), or nil to auto-detect faker.

```ruby
fake = GraphWeaver::Testing::FakeClient.new   # schema: falls back to Testing.config

person = PersonQuery.execute!(client: fake, id: "1").person
person.name       # a plausible name, when faker is loaded
person.birthday   # a real Date
```

A scalar you registered as **your own class** is the one value nothing here
can invent — only `Money.parse` knows what it accepts — so say it once, where
the rest of that scalar's knowledge already lives:

```ruby
GraphWeaver.register_scalar("Money", Money, fake: "12.00")
GraphWeaver.register_scalar("Money", Money, fake: ->(rng) { format("%.2f", rng.rand(1.0..100.0)) })
```

`fake:` is a **wire** value — what the server would send, before your `cast:`
runs. A proc is handed the seeded `Random`, so `--seed` still reproduces the
run. Without one, fabrication refuses and names the field, rather than feeding
your cast a `"Money-1"` placeholder that fails deep inside `from_h` blaming
the codec. A scalar registered as `Time`, `Date`, `Integer`, `Float`, `String`
or `T::Boolean` needs nothing: those the harness knows how to write.

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

### The example that's *about* the data

Fabricated data answers "does this render", not "does it render Ada's two
orders". `graphql_fake` is the tag with options — same client, built where
the example can say what it needs:

```ruby
it "shows the two paid orders", graphql: :fake do
  graphql_fake(overrides: {
    "Reader.name" => "Ada",
    "Reader.orders" => [{ "status" => "PAID" }, {}],
  })

  expect(DashboardQuery.execute!.reader.orders.size).to eq 2
end
```

An override pins a **subtree** as readily as a leaf, and **merges**: name
the fields the example is about and everything else in the selection is
still fabricated. A pinned list is exactly as long as you write it — `{}`
means "another one, all fabricated". Inside a subtree the keys are
*response* keys, as they come back on the wire (`priceCents`, or an alias
you selected); one the query doesn't select is refused and spellchecked,
same as a typo'd coordinate. At a union or interface, name the member with
`"__typename"`.

`graphql_fake` returns the client, which records what it was asked:

```ruby
fake = graphql_fake
2.times { Dashboard.load }
expect(fake.requests.size).to eq 1                      # memoized
expect(fake.requests.first[:variables]).to eq({ "id" => "1" })
```

It works in a `before` block, an example body, or a shared context — and
with no tag at all, since it installs the client itself. The tag is
`graphql_fake` with no options.

One thing to know: **two identical queries fabricate different data**, so
assert a memoization with `requests.size`, not by comparing two responses.

## Real resolvers — `graphql: :in_process`

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

A federated app has no one live class, so the example says which subgraph it
means. Testing one subgraph's resolvers directly is a different question from
`graphql: :router`, which plans across the whole graph and stitches; both are
worth asking, and a suite asks them of different subgraphs:

```ruby
it "rejects a review from a blocked reader" do
  graphql_in_process(Reviews::Schema)
  …
end
```

Like `graphql_fake`, `graphql_in_process` needs no tag, works in a `before`
block, and is restored after the example.

### The context your resolvers see

`graphql_context` is available in every example. It **merges** onto
`config.context` — the baseline survives unless you override a key — and is
**reset before the next example**, so one example running as somebody else
can't leak into the one after it. (Use it rather than the
`graphql_in_process(context:)` baseline, which is per-suite.)

Context is setup, so it usually belongs in a `before` block — a group of
examples sharing one identity says who they are once:

```ruby
describe "as the owner", graphql: :in_process do
  before { graphql_context(current_user: alice) }

  it "shows the drafts" do
    expect(DraftsQuery.execute!.drafts.size).to eq 2
  end
end
```

The reset runs ahead of any group hook, so each example re-applies that
`before` from the same baseline rather than stacking onto the last one's
context. Set it inline for the one-off, or pass a block to scope it for the
example that needs two identities:

```ruby
graphql_context(admin: true) { expect(SettingsQuery.execute!.settings).to be_present }
```

Called with nothing it reads the context back. Under `graphql: :fake` it
refuses: there are no resolvers to receive a context, and silently ignoring
one would leave an example asserting on data nothing scoped. Pin the data
itself instead — `graphql_fake(overrides: …)`, above.

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
context is reset from `config.context` every time.

What it plans, what it **refuses** and why, how subgraphs are matched to your
schema classes, and what to do about a supergraph only partly local:
**[federation → the local router](federation.md#the-local-router)**.

## Simulating failures

Every failure mode is just a client, so error-handling paths are testable
without a server that misbehaves on cue:

```ruby
Failure = GraphWeaver::Testing::Failure

PersonQuery.execute(client: Failure.transport, id: "1")            # raises TransportError
PersonQuery.execute(client: Failure.server(status: 502), id: "1")  # raises ServerError
PersonQuery.execute(client: Failure.throttled, id: "1")            # errors.first.code => "THROTTLED"
PersonQuery.execute(client: Failure.stale_schema, id: "1")         # schema_stale? => true
PersonQuery.execute(client: Failure.graphql("boom"), id: "1")      # partial failure

# a throttling server, with the header a backoff reads
PersonQuery.execute(client: Failure.server(status: 429, headers: { "retry-after" => "2" }), id: "1")

# retries: clients run in sequence (the last repeats) — here, two
# transport failures and then a FakeClient serving good responses
fake = GraphWeaver::Testing::FakeClient.new(schema:)
GraphWeaver::Testing::Sequence.new(Failure.transport, Failure.transport, fake)

# type mismatch: corrupt: derives a wrong-typed wire value for the field —
# casting raises GraphWeaver::TypeError (overrides remain the manual escape hatch)
GraphWeaver::Testing::FakeClient.new(schema:, corrupt: "Person.birthday")

# field-level partial failure with real GraphQL null propagation: the error
# lands with its concrete path and nulls bubble to the nearest nullable spot
GraphWeaver::Testing::FakeClient.new(schema:, fail_at: { path: "person.email", code: "PRIVATE" })
```

## Capture and replay

Cassettes record real API responses and replay them offline, above the
transport (no HTTP interception):

```ruby
# records against the live client when the file is missing, replays after
client = GraphWeaver::Testing.cassette("github", client: live)
```

Re-record with `GRAPHWEAVER_RECORD=1`, and set `config.anonymize = true` so the
response is scrubbed on its way to disk — the query and its variables are the
replay key and are recorded verbatim, so read a cassette before committing it.
The full workflow guide is **[cassettes](cassettes.md)**.

## Test-only generated modules

They don't have to live in `app/` — `generated_paths` is an appendable list,
so a support file can register a spec-local set:

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
