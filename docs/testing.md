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
it "sends the caller tag",    graphql: :wire do … end
```

| mode | reach for it when | what it costs |
|---|---|---|
| [`:fake`](#fabricated-data--graphql-fake) | most unit tests — you need *a* well-shaped response | no resolver code runs |
| [`:in_process`](#real-resolvers--graphql-in_process) | the point of the test is that your resolver logic works | slower; needs a live schema class |
| [`:router`](#a-federated-graph--graphql-router) | the same, across a federated graph | needs a composed supergraph; [refuses](federation.md#what-it-refuses) shapes it can't plan faithfully |
| [`:wire`](#over-the-wire--graphql-wire) | the test is about your own transport — headers, middleware, deserialization | needs webmock and an http client |
| `:live` | the app's own client is the point, or this one example wants out of `config.default_mode` | whatever your client does — this is the default |
| [cassettes](cassettes.md) | pinning a real server's exact response | must be re-recorded when the query changes |

The tag installs its client as `GraphWeaver.client` for that example, so
generated modules run against it with zero per-test setup. (Generate them
*without* a baked `client:` — a module that has one never consults
`GraphWeaver.client`.) `rspec --tag graphql:router` runs one mode's
examples.

**Every example has exactly one mode.** An untagged one takes
`config.default_mode`, which is `:live` — your own client, exactly as it is —
unless the suite sets another; and **`graphql: :live` is how one example steps
back out** of a default the suite did set.

`GraphWeaver.client` is **snapshotted before every example and restored
after** — whatever its mode, and whatever the example did to it. So building
your own client is a plain assignment, cleaned up like a tagged one:

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

Every mode, tagged and running end to end, is
[`spec/rspec_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/rspec_spec.rb) (and
[`spec/wire_mode_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/wire_mode_spec.rb) for `:wire`) — the
reference for anything this page leaves out.

## Nothing to configure

Each mode works out what to run against, and **refuses — naming what it
looked for — rather than guessing**:

- **the schema** is `config.schema` if you set one, else the one your single
  [graph](getting_started.md#more-than-one-schema) names, else the committed
  dump at `GraphWeaver.schema_path`, else the schema `GraphWeaver.client` talks
  to. An app with **more than one graph** is refused rather than guessed at:
  which schema an example fakes against varies, so name it —
  `graphql_fake(schema: Accounts::Schema)` or
  `graphql_in_process(Accounts::Schema)`. A fake built that way also reads the
  scalar registrations of the graph that owns that schema, so it invents the
  wire value the generated module's cast expects. (Pins and `overrides:`
  stay suite-wide, keyed by scalar name — one `"Money"` override for the run.)
- **`:in_process`** needs the live schema *class*, since only that has
  resolvers: the one your client already runs in-process, else the loaded
  class that defines everything the schema declares — the same
  derive-verify-refuse rule that
  [maps subgraphs](federation.md#which-schema-serves-which-subgraph).
- **`:router`** plans against the composed supergraph, found where you have
  already said it is: `config.router = { supergraph: … }` if you named one
  there, else the schema a [graph](getting_started.md#more-than-one-schema)
  declares when that schema carries `@join__*` markers, else the committed dump
  when *that* does — which for a federated app is usually no config at all. Two
  graphs naming *different* composed supergraphs is refused, not picked
  between. A client can't stand in for one: a client's schema is the API schema
  the router serves, with the `@join__*` routing table stripped out. Subgraphs
  are derived either way.

So configure only to override a derivation, or to tune fabricated values:

```ruby
GraphWeaver::Testing.configure do |config|
  # config.schema = MySchema         # the live class, rather than the dump
  # config.router = { supergraph: Rails.root.join("supergraph.graphql") }
  # config.router = { subgraphs: { "reviews" => :fake } }   # either key alone
  # config.context = { tenant: }     # baseline context every example starts from
  # config.default_mode = :fake      # what an UNtagged example runs against;
  #                                  # :live (the default) leaves your client
  #                                  # alone, and graphql: :live opts one out
  # config.seed = 4242               # defaults to rspec's own --seed
  # config.overrides = { "Money" => "12.00", "Person.name" => "Daniel" }
  # config.list_size = 1..3
end
```

Anything whose honest answer differs per example belongs on the fake instead
— `graphql_fake(null_chance: 1.0)` for the example that's about an empty
state, `graphql_fake(values: :literal)` for the one that reads better without
faker's prose. A suite-wide `null_chance` would sprinkle nils through every
*other* example, one run in ten, on a seed the failure doesn't name.

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
values along with test order.

```ruby
fake = GraphWeaver::Testing::FakeClient.new   # schema: falls back to Testing.config

person = PersonQuery.execute!(client: fake, id: "1").person
person.name       # a plausible name, when faker is loaded
person.birthday   # a real Date
```

Values are semantic when the [faker](https://github.com/faker-ruby/faker) gem
is loaded — `name` gets a name, `email` an email — and plain and type-derived
(`"name-1"`, seeded numbers) when it isn't. Say `values: :literal` on a fake
that reads better without the prose, or `values: :faker` to insist on the
semantic ones and get told if the gem is missing:

```ruby
graphql_fake(values: :literal)
GraphWeaver::Testing::FakeClient.new(values: :literal)
```

### Pins

**A pin says what the fake uses instead of inventing a value** — keyed by a
scalar type, an object type, or a field; worth a wire value, an object the fake
reads the selected fields off, or a proc handed the seeded `Random`:

```ruby
graphql_fake("Money" => "12.00",            # every Money field, however deep
             "Person" => build(:person),    # the selected fields, read off the object
             "Order.total" => "999.00")     # this one field — and it beats the type's pin
```

Keys are schema vocabulary, so they survive query refactors — a type name, or
`"Type.field"` (a bare `"field"` pins it on every type) — and they are checked
and spellchecked: `"Person.nmae"` raises rather than quietly pinning nothing
and leaving the example green against random data.

An **object pin** is anything answering the field names — a FactoryBot build, a
model, a `Struct`, an `OpenStruct`. For each selected field the fake calls the
snake_cased reader, puts a Ruby value on the wire the way its
[scalar registration](scalars.md) serializes it (a `Time` as its iso8601 string,
a `T::Enum` as its value), recurses into nested objects and arrays of them, and
**fabricates any field the object doesn't answer**. Readers are field names, not
aliases; `__typename` comes from the key, so at a union or interface pin the
concrete type (`"Person"`, never `"Named"`). One thing rspec's seed can't reach:
a FactoryBot sequence advances on its own counter, so an object built from one
isn't reproduced by `--seed`.

A **scalar type pin** is the one thing a scalar registered as *your own class*
needs — only `Money.parse` knows what wire value it accepts — so without one
fabrication refuses at the path it reached (`at reader.orders.0.total`) and
names the pin to add, rather than feeding your cast a placeholder that fails
deep inside `from_h`. A scalar registered as `BigDecimal`, `Time`, `Date`,
`Integer`, `Float`, `String` or `T::Boolean` needs nothing. Suite-wide, the same hash is
`config.overrides`, and the [cassette anonymizer](cassettes.md) reads it too.

Pins lead and options follow — `graphql_fake("Money" => "12.00", values:
:literal)`. Options are lowercase words, so a key with a dot or a leading
capital is a pin wherever it is written; `overrides:` takes the same hash by
keyword, and the leading pins win where both name a key. A fake refuses an
option it doesn't take, lists the ones it does, and guesses at what you meant —
at every door: `FakeClient.new`, `graphql_fake`, `Router.new(fake:)` and
`graphql_router(fake:)`.

### The example that's *about* the data

Fabricated data answers "does this render", not "does it render Ada's two
orders". `graphql_fake` is the tag with options — same client, built where
the example can say what it needs:

```ruby
it "shows the two paid orders", graphql: :fake do
  graphql_fake("Reader.name" => "Ada",
               "Reader.orders" => [{ "status" => "PAID" }, {}])

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
itself instead — `graphql_fake("Person.name" => "Ada")`, above.

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

`graphql_router` is the tag with options, the way `graphql_fake` is — one
option, `fake:`, saying how the subgraphs the router
[fakes](federation.md#a-supergraph-only-partly-local) fabricate: the pins and
options `graphql_fake` takes, in one hash:

```ruby
graphql_router(fake: { "Shipment.carrier" => "UPS", list_size: 2 })
```

What it plans, what it **refuses** and why, how subgraphs are matched to your
schema classes, and what to do about a supergraph only partly local:
**[federation → the local router](federation.md#the-local-router)**.

## Over the wire — `graphql: :wire`

Your resolvers, served at the endpoint your own client posts to — with
**`GraphWeaver.client` left exactly where it is**. So the request really is
serialized, posted through your middleware, planned and answered by real
resolvers, and read back by `from_h` over the server's own bytes. That is the
half the other three tags skip: they sit *in* the client slot, so the transport
your app ships — APM tracing, a caller tag, mTLS — never runs.

```ruby
it "sends the caller tag", graphql: :wire do
  DashboardQuery.execute!

  expect(WebMock).to have_requested(:post, "https://api.example.com/graphql")
    .with(headers: { "X-Caller" => "web" })
end
```

What sits behind the wire is decided the way the other tags already decide it:
the [router](#a-federated-graph--graphql-router) when there's a composed
supergraph, the [live schema class](#real-resolvers--graphql-in_process)
otherwise. The tag takes no options and has no helper: what a faked subgraph
behind the wire fabricates is `config.router = { fake: … }`, suite-wide.

**Identity comes from the request.** A `context:` **proc** is called per
request with the headers as sent, which is the seam nothing above the wire can
test:

```ruby
GraphWeaver::Testing.configure do |config|
  config.context = ->(headers) { { current_user: User.find_by(token: headers["Authorization"]) } }
end
```

A hash still works, and is still the baseline `graphql_context` merges onto; a
proc replaces it, and `graphql_context` then says so rather than merging onto
something that isn't there. (Rack drops a header's capitalization, so `X-CALLER`
arrives as `X-Caller`.)

**It needs [webmock](https://github.com/bblimke/webmock)** — `require
"webmock/rspec"` in the spec helper, in either order with `graph_weaver/rspec`.
That is what makes this a *transport* test rather than a mock of one: webmock hooks
Net::HTTP, Faraday and HTTPX underneath, so every transport
[documented here](transports.md) runs unchanged, pooling and all. The tag adds
one stub for the endpoint and takes it back after the example — it never
disables net connections on your behalf, and never resets stubs it didn't make.

The ceiling is the router's: the wire adds a hop, not a capability, so
everything [it refuses](federation.md#what-it-refuses) is still refused, before
any resolver runs. Fall back to a [cassette](cassettes.md) or a live gateway for
a shape it can't plan.

`GraphWeaver::Testing::Endpoint` is an ordinary Rack app wrapping anything that
satisfies the [client contract](transports.md) — so mount it yourself if you'd
rather have a real socket:

```ruby
run GraphWeaver::Testing::Endpoint.new(router)   # config.ru, or a Puma in a thread
```

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

# testing a retry — clients run in sequence, the last one repeating: two
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
