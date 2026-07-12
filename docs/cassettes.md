# Cassettes: capture and replay

Cassettes record real API responses and replay them in tests — above the
transport (an executor wrapping an executor), so there's no HTTP
interception and they work identically over HTTP, Faraday, or in-process
execution. A cassette is a YAML file of `{query, variables, response}`
entries, matched on the normalized query + variables.

## The workflow

```ruby
# spec: replay when the cassette exists, record against `live` when not
executor = GraphWeaver::Testing::Cassette.use("github", executor: live)
result = RepoQuery.execute!(owner: "dpep", name: "graph_weaver", executor:)
```

1. **Record** — first run hits the live API and writes
   `spec/cassettes/github.yml` (`Testing.config.cassette_dir` resolves bare
   names).
2. **Anonymize** — cassettes hold real data; scrub before committing (below).
3. **Commit** — tests now run offline, fast, deterministic.
4. **Re-record** when the API's real behavior changes:

   ```sh
   GRAPHWEAVER_RECORD=1 bundle exec rspec   # every Cassette.use records afresh
   ```

   (`Testing.config.record = true` is the programmatic equivalent.)

Replaying an unrecorded request raises `MissingRecording` with the query
and the path — no silent fabrication.

## Anonymization

Anonymizing rewrites recorded values through the same engine
[FakeExecutor](testing.md) uses, while preserving everything that makes
the recording faithful:

| preserved | replaced |
|-----------|----------|
| shape: keys, list lengths, null positions | strings (semantically: emails look like emails) |
| enums, booleans, `__typename` | numbers, dates |
| id *relationships* (same original id → same fake id) | the id values themselves |

Three ways to run it:

```ruby
# 1. as recordings happen — assertions you write against the recording
#    run hold on replay, and real data never touches disk
GraphWeaver::Testing.configure do |config|
  config.schema = MySchema
  config.anonymize = true
end

# 2. after the fact, per cassette
GraphWeaver::Testing::Cassette.new("spec/cassettes/github.yml").anonymize!(schema:)
```

```sh
# 3. the whole cassette_dir at once
rake graph_weaver:cassettes:anonymize
```

Anonymization needs the schema (it walks each recorded query's selections
to know which values are enums, dates, ids...). Variables are NOT
anonymized — they're the replay matching key; don't record with secret
variables.

## When to use what

- **FakeExecutor** — no recording needed; schema-correct random data.
  Best default for unit tests.
- **Cassettes** — real response *shapes* from a real API (pagination
  quirks, actual union members, servers' null habits). Best for
  integration-ish tests and regression pinning.
- **Anonymized cassettes** — cassette fidelity, committable without PII.
