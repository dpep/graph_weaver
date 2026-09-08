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

## Has a recording gone stale?

A cassette is the one artifact here recorded from *someone else's* server, and
none of the other checks can see it drift: `verify` asks whether the generated
Ruby is fresh, `queries:check` whether a query still validates, `schema:diff`
whether the server's schema moved. When the recorded *answers* stop fitting the
structs your schema generated — a field that was `Int!` when you recorded and
is `String!` now — nothing notices until a spec dies mid-run on a cast error
naming a struct and nothing else.

```sh
rake graph_weaver:cassettes:check
```

It replays every recording through the generated modules — no network — so it
belongs in the normal PR run beside `verify`, and exits non-zero on drift:

```
spec/cassettes/dashboard.yml: 1 stale (3 checked, 1 not sent by any query module)
  DashboardQuery {"id" => "b1"}
    failed to cast response into DashboardQuery::Result::Me::Reviews::Book: Parameter 'price_cents': Can't set …price_cents to 4200 (instance of Integer) - need a String
```

A recording is matched to the module that sends its query, so one written by
hand is skipped and counted rather than guessed at. Checking **none** of them
fails too: a green run that compared nothing would pass whatever the recordings
said. The fix is a re-record (`GRAPHWEAVER_RECORD=1`, with a live `client:`) —
or `rake graph_weaver:generate`, if it was the schema dump that moved first.

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

`data` is walked against the schema — which is why it needs one, to know which
values are enums, dates, ids. `errors` and `extensions` have none behind them,
so they're walked by shape instead: keys, nesting and structure survive, every
string and number is replaced. `path`, `locations` and an error's
`extensions.code` are kept, because they describe the request rather than the
data — and call sites branch on `code` the way they branch on an enum.

**The query and its variables are not anonymized.** They're the key replay
matches on, so scrubbing them would make the recording unfindable. A mutation's
input is often the sensitive part, so record with placeholder variables, or
don't record that request.

Recording says so when the bytes it wrote look like a credential:

```
graph_weaver: spec/cassettes/github.yml contains a JWT, a GitHub token — a
cassette is committed as written, so review this one first. …
```

It recognizes tokens by shape — a JWT, `AKIA…`, `ghp_…`, `xox…`, `sk_live_…`, a
PEM block, a `Bearer` header — which is every credential that is unmistakable
and nothing else. A password like `hunter2` has no shape, so a quiet run is not
a clean bill of health: **read a cassette before committing it.**

For cassettes recorded before the flag was on:

```sh
rake graph_weaver:cassettes:anonymize   # every cassette in cassette_dir, in place
```

Anonymization preserves shape, so an anonymized cassette still passes
`cassettes:check`.

## Cassette or FakeClient?

[FakeClient](testing.md) needs no recording and is the better default for unit
tests. Reach for a cassette when the *shape* of a real API's answers is the
point — pagination quirks, which union member came back, where that server puts
its nulls — and for pinning a regression.
