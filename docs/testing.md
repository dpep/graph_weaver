# Testing

How to run a spec that executes a GraphQL query without a server — against
fabricated data, against your own resolvers, across a federated graph, or
through your own transport with any of those behind it.

One line in your spec helper:

```ruby
# spec/support/graph_weaver.rb — or rails_helper.rb itself
require "graph_weaver/rspec"
```

Then **one tag says what an example runs against** — on the example, or on the
group it belongs to, since rspec metadata inherits:

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
| [`:wire`](#over-the-wire--graphql-wire) | the test is about your own transport — headers, middleware, deserialization | needs webmock and rack, and an http client |
| `:live` | the app's own client is the point, or this one example wants out of `config.default_mode` | whatever your client does — this is the default |
| [cassettes](cassettes.md) | pinning a real server's exact response | must be re-recorded when the query changes |

There is nothing else to set up: each mode works out what to run against per
graph, and [refuses rather than guessing](#nothing-to-configure). The tag
installs a stand-in per graph, and every generated module of that graph runs
against it — including one whose graph names a `client` of its own, since that
is exactly what the tag means to replace. `rspec --tag graphql:router`
runs one mode's examples.

**Every example has exactly one mode.** An untagged one takes
`config.default_mode`, which is `:live` — your own client, exactly as it is —
unless the suite sets another; and **`graphql: :live` is how one example steps
back out** of a default the suite did set.

`GraphWeaver.client` is **snapshotted before every example and restored after**,
whatever the example did to it, so building your own client is a plain
assignment: `before { GraphWeaver.client = GraphWeaver::Testing::Failure.throttled }`.
Do both at once and **the tag wins**: the assignment reads back while the modules
keep using the mode. Two things do step out of a tag — a per-call `client:`, and
a module [parsed](generated_modules.md#dynamic-mode) from a client of its own,
which runs against that client
([client resolution](transports.md#client-resolution) has the full order).

**The half `:fake` can't reach** is refusal. It fabricates a shape-correct
*success*, so your server's `validates:` rules and custom validators never run —
a `:fake`-only suite has zero coverage of server-side rejection. Cover it with
[`Failure.graphql(code:, extensions:)`](#simulating-failures) for the rejection
you expect, or with `:in_process`, where the real validators do run. (A bad
*variable* never gets as far as a mode: `execute` coerces before it asks any
client for anything, so a
[client-side `InputError`](errors.md#what-an-inputerror-says-without-reading-english)
raises the same way under every tag and under none.)

A fake also can't reach a **custom scalar's** rules, for the same reason: it
fabricates from your own [registration](scalars.md), so the round trip agrees
with itself whatever the server thinks. Where the server is a schema class,
`GraphWeaver::Testing.check_scalars!(Catalog::Schema)` runs both halves against
each other and names every scalar that disagrees
([how](scalars.md#checking-the-half-no-schema-carries)).

Everything here is a *client* — the one interface queries run through (the
contract is in [transports](transports.md)) — so fakes, the router, failures and
cassettes work outside rspec too (`require "graph_weaver/testing"`, never from
production code). There's no `GraphWeaver.client` to lean on there, so parse from
the fake or the router itself: anything holding a schema parses, and the module
runs on what parsed it.

```ruby
router = GraphWeaver::Testing::Router.new(supergraph: "app/graphql/supergraph.graphql")
DashboardQuery = router.parse("query Dashboard { me { username } }")
```

Every mode, tagged and running end to end, is
[`spec/rspec_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/rspec_spec.rb) (and
[`spec/wire_mode_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/wire_mode_spec.rb) for `:wire`) — the
reference for anything this page leaves out.

## Fabricated data — `graphql: :fake`

`FakeClient` fabricates schema-correct responses for whatever query arrives:
real enum values, valid `__typename` members, and — for a custom scalar — a
value the Ruby type you registered it as can hold, so every fake casts cleanly
through your generated structs. `@skip`/`@include` are evaluated against the
variables you passed (defaults included), so a field the server would leave out
is left out. `rspec --seed 1234` reproduces the values along with test order.

```ruby
it "shows the profile", graphql: :fake do
  person = PersonQuery.execute!(id: "1").person

  person.name       # a plausible name, when faker is loaded
  person.birthday   # a real Date
end
```

Values are semantic when the [faker](https://github.com/faker-ruby/faker) gem is
loaded — `name` gets a name, `email` an email — and plain and type-derived
(`"name-1"`, seeded numbers) when it isn't. Say `values: :literal` on a fake that
reads better without the prose, or `values: :faker` to insist on the semantic
ones and get told if the gem is missing.

Outside a tagged example, build one yourself:
`GraphWeaver::Testing::FakeClient.new` (its `schema:` falls back to
`Testing.config`), then pass it as `client:`.

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
and spellchecked: `"Person.nmae"` raises rather than quietly pinning nothing and
leaving the example green against random data. **Schema vocabulary, not Ruby:** a
`countries` field generates a `Countries` struct, but the pin is `"Country"`,
spelled the way *that* schema spells it, so a Hasura table type is
`"pokemon_v2_pokemon"` and not a Ruby-cased guess at it.

A pin **merges**, and pins a **subtree** as readily as a leaf: name the fields
the example is about and everything else in the selection is still fabricated. A
pinned list is exactly as long as you write it — `{}` means "another one, all
fabricated".

```ruby
graphql_fake("Reader.name" => "Ada",
             "Reader.orders" => [{ "status" => "PAID" }, {}])
```

Inside a subtree the keys are *response* keys, as they come back on the wire
(`priceCents`, or an alias you selected); one the query doesn't select is refused
and spellchecked, same as a typo'd coordinate. At a union or interface, name the
member with `"__typename"`.

An **object pin** is anything answering the field names — a FactoryBot build, a
model, a `Struct`, an `OpenStruct`. For each selected field the fake calls the
snake_cased reader, puts the value on the wire the way its
[scalar registration](scalars.md) serializes it (a `Time` as its iso8601 string,
a `T::Enum` as its value), recurses into nested objects and arrays of them, and
**fabricates any field the object doesn't answer**. Readers are field names, not
aliases; `__typename` comes from the key, so at a union or interface pin the
concrete type — `"Person"` or `"Person.name"`, never `"Named"` or
`"Named.name"`, and both spellings of the abstract one are refused. A FactoryBot sequence advances on
its own counter, which is the one thing `--seed` can't reproduce.

A **scalar type pin** is the one thing a scalar registered as *your own class*
needs — only `Money.parse` knows what wire value it accepts — so without one
fabrication refuses at the path it reached (`at reader.orders.0.total`) and names
the pin to add, rather than feeding your cast a placeholder that fails deep
inside `from_h`. A scalar registered as `BigDecimal`, `Time`, `Date`, `Integer`,
`Float`, `String` or `T::Boolean` needs nothing. The key is the **schema's scalar
name**, not the Ruby class it maps to, so two scalars that both deserialize into
`Money` want a pin each. What you pin there is **what the wire carries** —
`"12.00"`, not `Money.parse("12.00")` — though the object is accepted wherever
the registration can serialize one. (A `serialize:` **Proc** builds source rather
than converting a value, so a registration spelled that way has nothing to run:
pin the wire value, and the fake says so if you don't.) Suite-wide, the same hash
is `config.overrides`, and the [cassette anonymizer](cassettes.md) reads it too.

Pins lead and options follow — `graphql_fake("Money" => "12.00", values:
:literal)`. They are the same keywords, told apart by a lookup: a key the fake
takes is an option, a key **your schema** knows is a pin, and a key that is
neither is refused naming both. `overrides:` takes the same hash by keyword, and
the leading pins win where both name a key — write it as that leading hash when a
schema's own vocabulary collides with an option name. The refusal is the same at
every door: `FakeClient.new`, `graphql_fake`, `Router.new(fake:)` and
`graphql_router(fake:)`.

**A pin answers every call the same way**, which is how a paging loop fed by a
fake runs forever — page two is as full as page one.
`GraphWeaver::Testing::Sequence.new(page, empty)` chains clients and repeats the
last, so a fake whose pin is `[]` on the second one is what ends the loop.

`graphql_fake` returns the client, which records what it was asked:

```ruby
fake = graphql_fake
2.times { Dashboard.load }
expect(fake.requests.size).to eq 1                      # memoized
expect(fake.requests.first[:variables]).to eq({ "id" => "1" })
```

It works in a `before` block, an example body, or a shared context — and with no
tag at all, since it installs the client itself. The tag is `graphql_fake` with
no options. One thing to know: **two identical queries fabricate different
data**, so assert a memoization with `requests.size`, not by comparing two
responses.

## Real resolvers — `graphql: :in_process`

Your actual resolvers, your actual `context`, in the same process — no socket,
no serialization, and a resolver's real backtrace when it raises.

```ruby
it "hides other people's drafts", graphql: :in_process do
  graphql_context(current_user: alice)
  expect(DraftsQuery.execute!.drafts.map(&:owner)).to all(eq alice.name)
end
```

The live schema *class* is found for you (a schema dump has no resolvers, so it
won't do). If two loaded classes match, or none does, it says so and asks for
`config.schema = MySchema` — and in Rails, remember that an autoloaded schema
isn't loaded until something references it.

A federated app has no one live class, so the example says which subgraph it
means: `graphql_in_process(Reviews::Schema)`. Testing one subgraph's resolvers
directly is a different question from `graphql: :router`, which plans across the
whole graph and stitches; both are worth asking, and a suite asks them of
different subgraphs. Like `graphql_fake`, `graphql_in_process` needs no tag,
works in a `before` block, and is restored after the example.

### The context your resolvers see

`graphql_context` is available in every example, and is the *only* way to set a
context from inside one — `config.context` is the suite baseline, read when an
example's clients are built, before any `before` hook runs, so setting it there
is refused rather than silently dropped. It **merges** onto that baseline,
reaches every stand-in the example runs through (all your graphs', and the ones
`:wire` serves behind its endpoints), and is **reset before the next example**,
so one example running as somebody else can't leak into the one after it.

Context is setup, so it usually belongs in a `before` block — a group of examples
sharing one identity says who they are once:

```ruby
describe "as the owner", graphql: :in_process do
  before { graphql_context(current_user: alice) }
end
```

The reset runs ahead of any group hook, so each example re-applies that `before`
from the same baseline rather than stacking onto the last one's context. Pass a
block to scope it for the example that needs two identities —
`graphql_context(admin: true) { … }` — and call it with nothing to read the
context back. Under `graphql: :fake` it refuses: there are no resolvers to
receive a context, and silently ignoring one would leave an example asserting on
data nothing scoped. Pin the data itself instead.

## A federated graph — `graphql: :router`

Same thing across a federated graph: the tag builds a
[`Testing::Router`](federation.md#the-local-router), which plans the query across
your subgraphs and runs it against those **real resolvers** — no gateway, no
node, no sockets.

```ruby
describe "the dashboard", graphql: :router do
  it "stitches a user's reviews" do
    graphql_context(current_user: user)
    expect(DashboardQuery.execute!.me.reviews.size).to eq 2
  end
end
```

A router is built once per supergraph (parsing one per example would be real
time) and stands in for that graph's modules; its context is reset from
`config.context` every time.

`graphql_router` is the tag with options, the way `graphql_fake` is — one option,
`fake:`, saying how the subgraphs the router
[fakes](federation.md#a-supergraph-only-partly-local) fabricate: the pins and
options `graphql_fake` takes, in one hash.

```ruby
graphql_router(fake: { "Shipment.carrier" => "UPS", list_size: 2 })
```

It names no schema, so with more than one graph it refuses: the tag alone already
routes each module through its own graph's supergraph, and `config.router = {
fake: … }` says how the faked subgraphs fabricate for the suite.

What it plans, what it **refuses** and why, how subgraphs are matched to your
schema classes, and what to do about a supergraph only partly local:
**[federation → the local router](federation.md#the-local-router)**.

### Production redacts what this router hands you

A subgraph's error reaches you here in full — its message, and
`extensions: {"service" => "<subgraph>"}` saying which subgraph produced it. So
does a dev router configured with `include_subgraph_errors.all: true`. A
production Apollo Router, with that setting **omitted** — the default — replaces
the message and empties the extensions:

```
here, and a dev router
  {"message" => "carrier unavailable for this weight",
   "path" => ["product", "shippingEstimate"], "extensions" => {"service" => "reviews"}}
a production router
  {"message" => "Subgraph errors redacted", "path" => ["product", "shippingEstimate"]}
```

`path` survives; nothing else about the subgraph does — including the
`extensions.code` your own subgraph set, since it is a subgraph like any other.
So assert on `path` and on what your app does with the failure, not on a message,
a code, or the `service` stamp. An example that needs the redacted shape gets it
from [`Failure`](#simulating-failures), which reproduces it exactly:

```ruby
GraphWeaver::Testing::Failure.graphql(
  "Subgraph errors redacted", path: ["product", "shippingEstimate"],
)
```

## Over the wire — `graphql: :wire`

Your schema, served at the endpoint your own client posts to — with
**`GraphWeaver.client` left exactly where it is**. So the request really is
serialized, posted through your middleware, answered at the far end, and read
back by `from_h` over the server's own bytes. That is the half the other three
tags skip: they sit *in* the client slot, so the transport your app ships — APM
tracing, a caller tag, mTLS — never runs.

```ruby
it "sends the caller tag", graphql: :wire do
  DashboardQuery.execute!

  expect(WebMock).to have_requested(:post, "https://api.example.com/graphql")
    .with(headers: { "X-Caller" => "web" })
end
```

**It needs [webmock](https://github.com/bblimke/webmock) and
[rack](https://github.com/rack/rack)** in the Gemfile (`group :test`), and
webmock has to be *enabled* — `require "webmock/rspec"` in the spec helper, in
either order with `graph_weaver/rspec`. Having it in the Gemfile is not enough:
`Bundler.require` loads webmock without installing its adapters, so `:wire`
checks and refuses *before* the first request rather than letting it leave the
suite. The tag adds one stub per endpoint and takes each back after the example —
it never disables net connections on your behalf, and never resets stubs it
didn't make.

**Every endpoint an example can reach is served**, one per graph: the `client`
each [declared graph](getting_started.md#more-than-one-schema) names, or
`GraphWeaver.client` for a graph naming none — so a billing module posts to
billing's url and is answered by billing's schema. What
sits behind each is **what that graph is**, in descending faithfulness: that
graph's [router](#a-federated-graph--graphql-router) when it is in a composed
supergraph, its [live schema class](#real-resolvers--graphql-in_process) when it
has one, else a [fake](#fabricated-data--graphql-fake) of its schema. So an app
that is a pure *client* of someone else's API gets a schema-correct server
without writing one. A graph with no schema at all is refused, **by `:wire`'s own
name** — the one fallback the other tags have and this one can't use is your
client's own schema, since reading it means introspecting the endpoint `:wire`
has just stubbed. Commit a dump, or set `config.schema`. That refusal waits until
one of *that graph's* modules runs, so a graph the example never touches never
refuses it.

**A graph whose `client` posts nowhere runs above the wire** — there is no
endpoint to stub, so it is served in the client slot, exactly as
`graphql: :in_process` would serve it. That is how an app that owns resolvers
*and* calls someone else's API tests the remote half over the wire: its
in-process graph runs in-process, and every graph posting to a url is still
served at that url. An example where *no* graph posts anywhere is refused — a
`:wire` that serves nothing tests no transport.

**It says which, on the logger** — the choice is the one thing this tag makes for
you, and it is invisible from inside the example. One line per endpoint, at
`info` (a Rails app already has a logger; elsewhere set `GraphWeaver.logger`):

```
graph_weaver: :wire serving Shop::Schema (in-process) at https://api.example.com/graphql
```

When a **fake** stands in while the process has a `GraphQL::Schema` class that
nothing named, that line is a `warn` instead and names the class, telling you to
set `GraphWeaver::Testing.config.schema` — the case worth catching, because an
app that owns real resolvers otherwise goes green against fabricated data with
nothing said. A warning rather than a refusal, because a loaded class isn't proof
you meant it *here* — a federated suite loads every subgraph's — and a fake
behind the wire is a thing to want. A graph that ran above the wire gets a line
of its own, since the transport the example asked for never ran for it:

```
graph_weaver: :wire has no endpoint for graph :orders — its client posts to none, so its modules run above the wire, as graphql: :in_process would
```

**A helper says what goes behind the wire.** Under the other tags a `graphql_*`
helper takes the client slot; under `:wire` it is served instead — the client
slot has to keep your own client for the transport to run at all — so
`graphql_fake("Reader.orders" => [{ "status" => "PAID" }, {}])` reads exactly as
it does under `:fake`, and the helper returns the client it serves, so
`fake.requests` is what the *endpoint* was asked.

**Identity comes from the request.** A `context:` **proc** is called per request
with the headers as sent, which is the seam nothing above the wire can test:

```ruby
GraphWeaver::Testing.configure do |config|
  config.context = ->(headers) { { current_user: User.find_by(token: headers["Authorization"]) } }
end
```

A hash still works, and is still the baseline `graphql_context` merges onto; a
proc replaces it, and `graphql_context` then says so rather than merging onto
something that isn't there. (Rack drops a header's capitalization, so `X-CALLER`
arrives as `X-Caller`.) Like every suite setting, it goes in `Testing.configure`
or an `around` — [never a plain `before`](#nothing-to-configure), `:wire` least
of all, since the tag stubs this example's endpoints in a `before` hook of its
own.

**The wire adds a hop, not a capability.** Behind a router, everything
[it refuses](federation.md#what-it-refuses) is still refused, before any resolver
runs. Behind a fake, what you are testing is your *transport* — the request your
middleware wrote, the headers it sent, the retry it does on a 500, and that
`from_h` reads real JSON off a socket. What it can't tell you is whether your
`cast:` agrees with the real server: the fabricated bytes are written to match
your own [scalar registrations](scalars.md), so the round trip agrees with
itself. Put the live schema class behind the wire for that —
[`check_scalars!`](scalars.md#checking-the-half-no-schema-carries) asks the same
question of one directly — or pin a real response with a
[cassette](cassettes.md).

`GraphWeaver::Testing::Endpoint` is an ordinary Rack app wrapping anything that
satisfies the [client contract](transports.md), so mount it yourself
(`run GraphWeaver::Testing::Endpoint.new(router)`) if you'd rather have a real
socket. A client answering a `context:` **proc** is served **one request at a
time** — answering one means setting the client's context for the length of that
dispatch, so the identity a request asked for is the identity it gets, whatever
else is in flight. The lock is the client's own, so it holds however the endpoint
is mounted. A `context:` hash is served **concurrently**: nothing writes it, so
there is nothing to serialize. Either way a query reads its context once, so
every subgraph it hops through runs as the identity it started with, even if
the router's context is reassigned while it is in flight.

### Making the served endpoint fail

The tag adds **one stub per endpoint**, and webmock answers with the *last* stub
declared for a url — so an example that wants the server to misbehave declares
its own, and it wins for that example:

```ruby
it "surfaces a 503, after the retries it's allowed", graphql: :wire do
  stub_request(:post, "https://api.example.com/graphql")
    .to_return(status: 503, headers: { "Retry-After" => "0" }, body: "down for maintenance")

  expect { PlaceOrderMutation.execute!(input:) }.to raise_error(GraphWeaver::ServerError) { |e|
    expect(e.status).to eq 503
    expect(e.retry_after).to eq 0    # the header your backoff read
  }
end

# .to_timeout instead, and the call raises GraphWeaver::TransportError
```

That is a **served** failure: your transport reads the status and the headers off
a real response, and your `retries:` budget really spends itself against it —
including [the one attempt a mutation gets](transports.md#retries). That is the
half a [`Failure` client](#simulating-failures) can't reach, since those sit *in*
the client slot and raise above the wire. Use `Failure.server` /
`Failure.timeout` when the example is about your `rescue`; a stub when it is
about the transport.

`to_timeout` raises instantly, so it tests what your app *does* with a timeout —
not that a `read_timeout:` of yours is short enough. Sleeping inside
`to_return { |req| … }` doesn't either: webmock stands in for the socket, so
there is nothing to time out and the call simply takes that long and succeeds. A
timeout *value* can only be proven against a genuinely slow server — the
`Endpoint` above on a real port, or a `TCPServer` that dawdles before it replies.

## Simulating failures

Every failure mode is just a client, so error-handling paths are testable without
a server that misbehaves on cue:

```ruby
Failure = GraphWeaver::Testing::Failure

PersonQuery.execute(client: Failure.transport, id: "1")            # raises TransportError
PersonQuery.execute(client: Failure.timeout, id: "1")               # raises TransportError, cause Net::ReadTimeout
PersonQuery.execute(client: Failure.server(status: 502), id: "1")  # raises ServerError
PersonQuery.execute(client: Failure.throttled, id: "1")            # errors.first.code => "THROTTLED"
PersonQuery.execute(client: Failure.stale_schema, id: "1")         # schema_stale? => true
PersonQuery.execute(client: Failure.graphql("boom"), id: "1")      # errors, and no data

# a throttling server, with the header a backoff reads
PersonQuery.execute(client: Failure.server(status: 429, headers: { "retry-after" => "2" }), id: "1")

# testing a retry — clients run in sequence, the last one repeating: two
# transport failures and then a FakeClient serving good responses
fake = GraphWeaver::Testing::FakeClient.new(schema:)
GraphWeaver::Testing::Sequence.new(Failure.transport, Failure.transport, fake)

# type mismatch: corrupt: derives a wrong-typed wire value for the field —
# casting raises GraphWeaver::CastError (overrides remain the manual escape hatch)
GraphWeaver::Testing::FakeClient.new(schema:, corrupt: "Person.birthday")

# field-level partial failure with real GraphQL null propagation: the error
# lands with its concrete path and nulls bubble to the nearest nullable spot.
# The path is response keys joined by dots, and a list index is a segment of
# its own — state only the indices you mean, the rest match any position
GraphWeaver::Testing::FakeClient.new(schema:, fail_at: { path: "person.email", code: "PRIVATE" })
GraphWeaver::Testing::FakeClient.new(schema:, fail_at: "people.2.pets.name")
```

`Failure.graphql` is the **whole response** failing — `data` is null unless you
pass `data:`, which is what makes it a partial one. Shape the error by naming its
wire fields beside the message (`code:`, `extensions:`, `path:`, `locations:` —
anything else is refused rather than swallowed), so a rejection that follows the
[`extensions.input` convention](errors.md#what-your-server-can-send) is one call:

```ruby
# a plain code, the coarse bucket every server states
Failure.graphql("that input was bad", code: "BAD_USER_INPUT")

# the convention: response.input_errors reads this back as one InputError,
# kind :out_of_range, details { min: 1 }, on path ["input", "min"]
Failure.graphql(
  "min must be at least 1",
  code: "BAD_USER_INPUT",
  extensions: { "input" => { "kind" => "out_of_range", "path" => ["input", "min"],
                             "coordinate" => "RangeInput.min", "value" => 0, "min" => 1 } },
)

# several errors, and partial data: each carries its own hash
Failure.graphql({ message: "boom", path: ["person"] }, "and again", data: { "person" => nil })
```

**A server's own rejection lands in `#errors` unless it marked it.** A
graphql-ruby `validates:` failure carries no `extensions` at all, so it is an
ordinary error in `response.errors` — `#input_errors` is empty, because "the
value was out of range" and "the database is down" are the same bytes. Assert on
`errors` for that, and reach for `#input_errors` only once your server
[says the error is about the input](errors.md#when-the-server-rejects-the-input).

## Capture and replay

`GraphWeaver::Testing.cassette("github", client: live)` returns a client that
records real API responses and replays them offline, above the transport (no HTTP
interception). Re-record with `GRAPHWEAVER_RECORD=1`, and set
`config.anonymize = true` so the response is scrubbed on its way to disk. The
full workflow guide is **[cassettes](cassettes.md)**.

## Nothing to configure

Each mode works out what to run against **per graph** — with more than one, the
honest answer varies per module — and **refuses, naming what it looked for,
rather than guessing**:

- **the schema** is `config.schema` if you set one, else the one that
  [graph](getting_started.md#more-than-one-schema) names, else the committed dump
  at `GraphWeaver.schema_path`, else the schema `GraphWeaver.client` talks to. A
  fake reads the scalar registrations of the graph it is answering, so it invents
  the wire value that graph's generated cast expects. (Pins and `overrides:` stay
  suite-wide, keyed by scalar name — one `"Money"` override for the run.)
- **`:in_process`** needs the live schema *class*, since only that has resolvers:
  the one that graph names, else the one your client already runs in-process,
  else the loaded class that defines everything the schema declares — the same
  derive-verify-refuse rule that
  [maps subgraphs](federation.md#which-schema-serves-which-subgraph).
- **`:router`** plans against the composed supergraph **that graph** names, else
  `config.router = { supergraph: … }`, else the committed dump when *that*
  carries `@join__*` markers, else the dump your own client was built from
  (`GraphWeaver.new("supergraph.graphql")`) — which for a federated app is
  usually no config at all. A graph that is in no supergraph is refused **by
  name**, rather than planned against another graph's. A client's *schema* can't
  stand in for one — it is the API schema the router serves, with the `@join__*`
  routing table stripped out — but the file it was read from carries the table.
  Subgraphs are derived either way.

So configure only to override a derivation, or to tune fabricated values — in the
same file as the require, since support files load in sorted order and one naming
`GraphWeaver::Testing` before it dies on `NameError`:

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

**The rule: a helper sets the stand-in for the graph it names; the tag sets the
mode for every graph no helper named.** `graphql_fake`, `graphql_in_process` and
`graphql_router` stand in for the modules of the graph their schema names — your
only graph when they name none — and with more than one, `graph:` says which:
`graphql_fake(graph: :poke, "pokemon_v2_pokemon.name" => "pikachu")`. A schema
class names its graph and its schema in one word
(`graphql_in_process(Reviews::Schema)`), but only for a graph that runs that
class in-process; `graph:` is the handle every graph has. Naming none they could
reach is refused, naming your graphs.

So one example can run two graphs in two modes — the federated one through its
router, the plain one faked — and neither helper disturbs the other's graph:

```ruby
it "renders the dashboard", graphql: :router do
  graphql_fake(graph: :countries, "Country.name" => "Canada")
  # :storefront routes through its supergraph (the tag); :countries is faked
end
```

A helper that speaks for the whole example *is* refused, though: with one graph,
or with no `graph:`/schema to narrow it, `graphql: :fake` plus
`graphql_in_process` is two answers to one question, and the later one winning
silently would hide which was the mistake.

Anything whose honest answer differs per example belongs on the fake instead —
`graphql_fake(null_chance: 1.0)` for the example that's about an empty state,
`graphql_fake(values: :literal)` for the one that reads better without faker's
prose. A suite-wide `null_chance` would sprinkle nils through every *other*
example, one run in ten, on a seed the failure doesn't name.

**Configure at load, or in an `around` — never in a plain `before`.** The tag
builds this example's clients in a `before` hook of its own, and rspec runs that
one ahead of yours, so a `before` setting `config.schema`, `config.router` or
`config.context` arrives after the decision it meant to change. It is
**refused**, not ignored — a green example running against the wrong stand-in is
the expensive outcome.

That hook is also why **a refusal the tag itself raises can't be asserted with
`expect { }.to raise_error`**: it happens before the example body, and rspec
records it as the example's failure rather than letting anything catch it — an
`around` hook included, since `example.run` returns normally there. To assert
one, call the helper in an **untagged** example, where the same refusal is
raised in the body: `expect { graphql_in_process }.to raise_error(...)`, and the
same for `graphql_fake` and `graphql_router`. `:wire` has no helper, so its
whole-example refusal can only be read off the failure — the per-graph one it
raises when a module runs is in the body, and assertable.

### Fabricated list lengths and nulls

`list_size` is how long an **unbounded** list is — an Integer exactly that many,
a Range randomized within it, or a Hash saying it per list. A list with a
`first:`/`last:`/`limit:` argument is that long instead, whatever this says.

**Every list the fabricator reaches reads the same setting, so nested lists
multiply.** A query selecting `rows { owner { … } tags }` with `tags` uncapped
fabricates `list_size` rows and `list_size` tags *in each of them* — at 1600 that
is 2.5M tags, and three nested lists cube it. Say it per list instead, keyed the
way a pin is (a `"Type.field"` coordinate or a bare field name), with `default:`
for the rest — `config.list_size = { "Row.tags" => 3, default: 1000 }` holds the
inner list at 3 however large the outer one grows. Or cap it in the query
(`tags(first: 3)`), where the query is yours to change.

`null_chance` takes the same two shapes, and the same keys: a number from 0 to 1
for every nullable field, or a Hash saying it per field with `default:` for the
rest. So the example about one missing value says only that —
`graphql_fake(null_chance: { "Person.nickname" => 1.0 })` — instead of nilling
everything else alongside it. A misspelled key is refused and spellchecked, the
way a pin's is.

**Both are keyed by field, and the key has to be one the option can reach**: a
type name (`"Person"`) is refused rather than read as the nearest field, a
`null_chance` key naming a non-null field is refused (nothing there ever comes
back null), and a `list_size` key naming a field that isn't a list likewise —
all three are keys that would validate clean, fabricate nothing and leave the
example green. `"default"` is always the fallback, never a field, so a schema
field actually called `default` is reachable only as `"Type.default"`. And a
[pin](#pins) on the same field beats both: a pinned value is used as written,
so it is neither nulled nor resized.

**A list field whose name ends in `errors` fabricates empty** — `userErrors`,
`errors`, `mutationErrors`. The Relay/Shopify payload
(`placeOrder { order userErrors }`) is the ecosystem's mutation shape, and a
fabricated order beside a fabricated failure is a response no server can send;
[pin it](#pins) to write the failure path
(`{ "userErrors" => [{ "message" => "Out of stock" }] }`).

Need the schema itself inside an example — to sample a field, or build a query on
the fly? The client in play exposes it as `GraphWeaver.client.schema`, and
`GraphWeaver::Testing.config.schema` reads back what `config.schema =` set,
falling back to the committed dump.

A query built that way is worth an assertion of its own:

```ruby
expect(GraphWeaver.client.check_query(source)).to be_empty
```

[`check_query`](getting_started.md#5-verify-in-ci) answers with the
errors rather than a boolean, so a failure prints what is wrong and where; a
predicate would only say the query isn't valid.

## Test-only generated modules

They don't have to live in `app/` — `generated_paths` is an appendable list, so a
support file can register a spec-local set:

```ruby
# spec/support/graph_weaver.rb
GraphWeaver.generated_paths << "spec/graphql/generated"
GraphWeaver.load_generated!   # the appended path needs this call
```

Both lines matter. In Rails the Railtie loads generated modules during boot,
which is finished before `spec/support/*.rb` runs — so a path appended here is
never loaded unless you load it. And keep the directory *outside*
`spec/support/`: rspec-rails requires every `spec/support/**/*.rb` itself, in
sorted order, so a generated module gets required before the shared `types.rb` it
needs and dies on `LoadError`.
