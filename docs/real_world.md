# Against a real API

The exploratory tour: point a client at a live endpoint and go, no build
step — ideal for consoles, spikes, and getting a feel for an API. What
ships is the checked-in codegen path in the [quickstart](quickstart.md);
this page is how you get there (the `parse` below becomes a `.graphql`
file plus `rake graph_weaver:generate`, everything else stays).

Everything hangs off a client — transport, schema, and scalars for one
server. GitHub's API, end to end:

```ruby
require "graph_weaver"

# transport + auth in one object (see docs/transports.md for retries and
# advanced setup). cache: true dumps the schema at GraphWeaver.schema_path
# on first introspection — the same file rake graph_weaver:generate reads —
# and any fresh dump already present is reused regardless of format. The
# extension picks the format: .json verbatim, .graphql SDL (reviewable
# diffs) — or say cache: :graphql. Introspected dumps record their source
# url in a header, so a stale dump says where it came from.
github = GraphWeaver.new("https://api.github.com/graphql", auth: `gh auth token`.strip, cache: true)

# map GitHub's DateTime scalar onto Time (cast inferred from Time.parse) —
# scoped to this client; GraphWeaver.register_scalar sets the global default
github.register_scalar("DateTime", Time, serialize: :iso8601, requires: "time")

RepoQuery = github.parse(<<~GRAPHQL)
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      nameWithOwner
      createdAt
      stargazerCount
    }
  }
GRAPHQL

repo = RepoQuery.execute!(owner: "dpep", name: "graph_weaver").repository
repo&.name_with_owner   # => "dpep/graph_weaver"
repo&.created_at        # => 2026-07-07 ... (a real Time)
repo&.stargazer_count   # => Integer
```

Clients are independent — build one per server, each with its own
transport, schema, and scalar mappings. The introspection step (seconds
on a big API) happens lazily on first `schema`/`parse` and caches per
`cache:`/`ttl:`; for finer control the pieces are all public
(`GraphWeaver::SchemaLoader.introspect(executor, cache:, ttl:)`, or cache
`introspect(executor).to_json` in Rails.cache and `SchemaLoader.load` it).

The same flow runs as one-off integration specs against the live GitHub
and Countries APIs — `make integration` (network; GitHub auth via
`gh auth token` or `GITHUB_TOKEN`).
