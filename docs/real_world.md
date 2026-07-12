# Against a real API

Everything composes for a remote endpoint — introspect the schema
straight off the wire, then query with typed results. GitHub's API,
end to end:

```ruby
require "graph_weaver"

# transport + auth, wired in as the default executor (see docs/transports.md
# for retries and advanced setup)
executor = GraphWeaver.connect("https://api.github.com/graphql", auth: `gh auth token`.strip)

# introspecting a big API takes seconds — cache: true dumps the schema
# at GraphWeaver.schema_path (the same file rake graph_weaver:generate
# reads), and any fresh dump already present is reused regardless of
# format. The extension picks the format: .json verbatim, .graphql SDL
# (reviewable diffs) — or say cache: :graphql. Pass a path/ttl: for finer
# control, or cache introspect(executor).to_json in Rails.cache and
# SchemaLoader.load it
schema = GraphWeaver::SchemaLoader.introspect(executor, cache: true)

# map GitHub's DateTime scalar onto Time (cast inferred from Time.parse)
GraphWeaver.register_scalar("DateTime", type: Time, serialize: :iso8601, requires: "time")

RepoQuery = GraphWeaver.parse(schema:, query: <<~GRAPHQL)
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

The same flow runs as one-off integration specs against the live GitHub
and Countries APIs — `make integration` (network; GitHub auth via
`gh auth token` or `GITHUB_TOKEN`).

