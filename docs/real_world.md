# Against a real API

Everything composes for a remote endpoint — introspect the schema
straight off the wire, then query with typed results. GitHub's API,
end to end:

```ruby
require "graph_weaver"

# transport + auth, wired in as the default executor (see docs/transports.md
# for retries and advanced setup)
executor = GraphWeaver.connect("https://api.github.com/graphql", auth: `gh auth token`.strip)

# introspecting a big API takes seconds — cache: stores the introspection
# JSON in a file and reuses it for ttl: seconds. For Rails.cache/redis,
# cache introspect(executor).to_json and SchemaLoader.load it back.
schema = GraphWeaver::SchemaLoader.introspect(
  executor,
  cache: "tmp/github-schema.json",
  ttl: 24 * 60 * 60,
)

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

