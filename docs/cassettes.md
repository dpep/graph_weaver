# Cassettes: capture and replay

Cassettes record real API responses and replay them in tests — above the
transport (a client wrapping a client), so there's no HTTP interception and
they work identically over HTTP, Faraday, or in-process execution. A cassette
is a YAML list of `{query, variables, operationName, response}` entries,
matched on everything but the response — the request's identity as the server
sees it.

`Testing.cassette(name, client:)` returns a client that replays
`spec/cassettes/<name>.yml`, recording it through `client:` first if the file
doesn't exist yet.

```ruby
client = GraphWeaver::Testing.cassette("github", client: live)
result = RepoQuery.execute!(client:, owner: "dpep", name: "graph_weaver")
```

That first run writes `spec/cassettes/github.yml` (`Testing.config.cassette_dir`
resolves bare names). Commit it — with anonymization on (below), since
recordings hold real data — and the suite runs offline from then on. Re-record
when the API's real behavior changes:

```sh
GRAPHWEAVER_RECORD=1 bundle exec rspec   # every Testing.cassette records afresh
```

(`Testing.config.record = true` is the programmatic equivalent.) A call with no
`client:` raises there, rather than quietly replaying the recording it was told
to refresh. A *request* with no recording raises
`GraphWeaver::Testing::MissingRecording`, naming the variables it was called
with and the ones recorded for that same query — what usually differs.

## Anonymization

Cassettes hold real responses, so scrub them as they're recorded: real data
never reaches disk, and the caller sees the anonymized response too, so
assertions written during the recording run still hold on replay.

```ruby
GraphWeaver::Testing.configure do |config|
  config.schema = MySchema
  config.anonymize = true
end
```

Values are rewritten through the same engine [FakeClient](testing.md) uses,
preserving everything that makes the recording faithful:

| preserved | replaced |
|-----------|----------|
| shape: keys, list lengths, null positions | strings (semantically: emails look like emails) |
| enums, booleans, `__typename` | numbers, dates |
| id *relationships* (same original id → same fake id) | the id values themselves |

It needs the schema — it walks each recorded query's selections to know which
values are enums, dates, ids. Variables are NOT anonymized: they're the replay
matching key, so don't record with secret variables.

For cassettes recorded before the flag was on:

```sh
rake graph_weaver:cassettes:anonymize   # every cassette in cassette_dir, in place
```

## Cassette or FakeClient?

[FakeClient](testing.md) needs no recording and is the better default for unit
tests. Reach for a cassette when the *shape* of a real API's answers is the
point — pagination quirks, which union member came back, where that server puts
its nulls — and for pinning a regression.
