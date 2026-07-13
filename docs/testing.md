# Testing

Everything here is a *client* — the one interface queries run
through: anything with `execute(query, variables:)` returning
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
fake = GraphWeaver::Testing::FakeClient.new(schema:)

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

With rspec, the setup is two lines in `spec/support/graph_weaver.rb` —
the require, plus an explicit opt-in to per-example fakes (deliberately
not a default: silently swapping every example onto a fake would be
surprising). The schema auto-locates from the committed dump at
`GraphWeaver.schema_path`:

```ruby
require "graph_weaver/rspec"   # seed follows --seed

GraphWeaver::Testing.configure do |config|
  config.auto_fake = true              # every example runs against a fresh fake
  # config.schema = MySchema           # optional: an in-process class instead of the dump
  # config.mode = :faker               # or :literal (plain typed values); nil = auto
  # config.overrides = { "Person.name" => "Daniel" }
  # config.list_size = 1..3
  # config.null_chance = 0.1           # nullable fields go nil sometimes
end
```

With the rspec integration, `rspec --seed 1234` reproduces fake data
along with test order, and `auto_fake` installs a seeded fake as the
app client per example (generate modules *without* a baked `client:` so
they consult `GraphWeaver.client`). `mode:` picks value fabrication: `:faker`
(semantic, field-name matched — raises if the gem is missing),
`:literal` (plain type-derived), or nil to auto-detect faker.

Test-only queries don't have to live in `app/` — the conventional paths
are appendable lists, so the same support file can register a
spec-local set that `load_generated!` (and the Railtie) pick up:

```ruby
GraphWeaver.generated_paths << "spec/support/graphql/generated"
GraphWeaver.queries_paths << "spec/support/graphql/queries"
```

**Simulating failures** — every failure mode is just a client, so
error-handling paths are testable without a server that misbehaves on cue:

```ruby
Failure = GraphWeaver::Testing::Failure

PersonQuery.execute(id: "1", client: Failure.transport)             # TransportError (cause preserved)
PersonQuery.execute(id: "1", client: Failure.server(status: 502))   # ServerError
PersonQuery.execute(id: "1", client: Failure.throttled)             # QueryError, code THROTTLED
PersonQuery.execute(id: "1", client: Failure.stale_schema)          # schema_stale? => true
PersonQuery.execute(id: "1", client: Failure.graphql("boom", data: {...}))  # partial failure

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
cassette = GraphWeaver::Testing::Cassette.use("github", client: live)
```

Re-record with `GRAPHWEAVER_RECORD=1`, anonymize before committing
(`config.anonymize = true` scrubs as recordings happen, or
`rake graph_weaver:cassettes:anonymize` after) — the full workflow guide
is **[cassettes](cassettes.md)**.

