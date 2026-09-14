# Against a real API

Point a client at a live endpoint and go, no build step — the exploratory tour,
for consoles and spikes. What ships is the checked-in codegen path in
[getting started](getting_started.md); the `parse` below becomes a `.graphql`
file plus `rake graph_weaver:generate`, and everything else stays.

Everything hangs off a client — transport and schema for one server. GitHub's
API, end to end:

```ruby
require "graph_weaver"

# transport + auth in one object (docs/transports.md for retries and TLS).
# cache: true writes the schema to GraphWeaver.schema_path on first
# introspection — the same dump rake graph_weaver:generate reads. It records
# its source url, so a second client at a second origin caches under a name of
# its own rather than overwriting this one.
github = GraphWeaver.new("https://api.github.com/graphql", auth: `gh auth token`.strip, cache: true)

# GitHub's DateTime needs no registration (docs/scalars.md). A scalar of your
# own goes here: registrations are global and codegen-time, so one line types
# your console and your checked-in code identically.

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
repo&.created_at        # => a real Time
repo&.stargazer_count   # => Integer
```

Build one client per server; they're independent. That same client is what
`GraphWeaver.generate!(schema: github)` takes when you check the generated code
in, so no dump on disk is needed — and keeping a second server's modules beside
your own is a [graph](getting_started.md#more-than-one-schema).

## Browsing the schema

`client.schema` is an ordinary graphql-ruby `Schema` class, so "what can I even
ask for" is answered in the console with nothing else installed:

```ruby
schema = github.schema

schema.query.fields.keys              # => ["repository", "search", ...]
field = schema.query.fields["repository"]
field.arguments.keys                  # => ["owner", "name", ...]
field.type.to_type_signature          # => "Repository"

repo = field.type.unwrap              # past the ! and [] wrappers
repo.graphql_name                     # => "Repository"
repo.fields.keys.sort                 # => ["createdAt", "description", ...]
```

Reach for `graphql_name`, not `name`: a schema built from introspection or SDL
has no Ruby class behind its types, so `.name` is `nil` there, and where the
schema *is* a class you wrote `.name` gives the Ruby constant.

Introspection (seconds on a big API) happens lazily on first `schema`/`parse`
and caches per `cache:`/`ttl:`; for finer control the pieces are public —
`GraphWeaver::SchemaLoader.introspect(transport, cache:, ttl:)`, or cache
`introspect(transport).to_json` yourself and `SchemaLoader.load` it.

`make integration` runs this flow against the live GitHub and Countries APIs
(network; GitHub auth via `gh auth token` or `GITHUB_TOKEN`).
