# Testing

`require "graph_weaver/rspec"` from your spec helper (or
`graph_weaver/testing` outside rspec — never in production) for a
zero-setup fake backend. `FakeExecutor` fabricates
schema-correct responses for whatever query arrives: real enum values,
valid `__typename` members, iso8601 date scalars — every fake casts
cleanly through your generated structs.

```ruby
fake = GraphWeaver::Testing::FakeExecutor.new(schema:)

person = PersonQuery.execute!(id: "1", executor: fake).person
person.name       # => "Eliza Kertzmann" (faker-matched on field name, when faker is loaded)
person.birthday   # => a real Date
```

Pin what matters, keyed by GraphQL names (schema vocabulary — keys
survive query refactors); `"Type.field"` beats `"field"`:

```ruby
GraphWeaver::Testing::FakeExecutor.new(schema:, overrides: {
  "Person.name" => "Daniel",
  "email" => -> { "test@example.com" },
})
```

Or configure once, initializer-style (e.g. in `spec/support/graph_weaver.rb`):

```ruby
require "graph_weaver/rspec"   # rspec: seed follows --seed

GraphWeaver::Testing.configure do |config|
  config.schema = MySchema
  config.auto_fake = true              # every example runs against a fresh FakeExecutor
  config.mode = :faker                 # or :literal (plain typed values); nil = auto
  config.overrides = { "Person.name" => "Daniel" }
  config.list_size = 1..3
  config.null_chance = 0.1             # nullable fields go nil sometimes
end
```

With the rspec integration, `rspec --seed 1234` reproduces fake data
along with test order, and `auto_fake` installs a seeded executor per
example (generate modules *without* a baked `executor:` so they consult
`GraphWeaver.executor`). `mode:` picks value fabrication: `:faker`
(semantic, field-name matched — raises if the gem is missing),
`:literal` (plain type-derived), or nil to auto-detect faker.

**Simulating failures** — every failure mode is just an executor, so
error-handling paths are testable without a server that misbehaves on cue:

```ruby
Failure = GraphWeaver::Testing::Failure

PersonQuery.execute(id: "1", executor: Failure.transport)             # TransportError (cause preserved)
PersonQuery.execute(id: "1", executor: Failure.server(status: 502))   # ServerError
PersonQuery.execute(id: "1", executor: Failure.throttled)             # QueryError, code THROTTLED
PersonQuery.execute(id: "1", executor: Failure.stale_schema)          # schema_stale? => true
PersonQuery.execute(id: "1", executor: Failure.graphql("boom", data: {...}))  # partial failure

# retries: executors run in sequence (the last repeats) — here, two
# transport failures and then a FakeExecutor serving good responses
fake = GraphWeaver::Testing::FakeExecutor.new(schema:)
GraphWeaver::Testing::SequenceExecutor.new(Failure.transport, Failure.transport, fake)

# type mismatch: corrupt: derives a wrong-typed wire value for the field —
# casting raises GraphWeaver::TypeError (overrides remain the manual escape hatch)
GraphWeaver::Testing::FakeExecutor.new(schema:, corrupt: "Person.birthday")

# stale schema naming a real (sampled) field
Failure.stale_schema(schema: MySchema)

# field-level partial failure with real GraphQL null propagation: the error
# lands with its concrete path and nulls bubble to the nearest nullable spot
GraphWeaver::Testing::FakeExecutor.new(schema:, fail_at: { path: "person.email", code: "PRIVATE" })
```

**Capture and replay** — cassettes record real API responses and replay
them offline, above the transport (no HTTP interception):

```ruby
# records against the live executor when the file is missing, replays after
executor = GraphWeaver::Testing::Cassette.use("github", executor: live)
```

Re-record with `GRAPHWEAVER_RECORD=1`, anonymize before committing
(`config.anonymize = true` scrubs as recordings happen, or
`rake graph_weaver:cassettes:anonymize` after) — the full workflow guide
is **[cassettes](cassettes.md)**.

