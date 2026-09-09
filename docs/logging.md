# Logging

Silent by default. Point `GraphWeaver.logger` at anything
stdlib-Logger-compatible and the whole flow narrates itself — in Rails
the railtie wires `Rails.logger` automatically (set
`GraphWeaver.logger = nil` in an initializer to opt out):

```ruby
GraphWeaver.logger = Logger.new($stdout, level: Logger::INFO)
```

What logs at which level — pick the level, get the story:

| Level | What you see |
|-------|--------------|
| `debug` | the wire: query + variables per call (long queries truncated), response status/bytes, request timing, connection open/drop, dynamically parsed modules |
| `info` | schema introspection (with timing) and cache hits/misses, generated files written and any unregistered scalars, query modules loaded |
| `warn` | every GraphWeaver error raised — `TransportError`, `ServerError`, `QueryError`, `ValidationError`, `TypeError` |

Every line carries `graph_weaver` as the progname, so formatter-based
filtering works out of the box. Wire lines are tagged
`[req 3 FilteredPokemon]` — a per-process request id plus the operation
name — so a request's lines stay paired when threads interleave.

**PII note**: queries, variables, and response sizes appear at debug
only — variables can carry user data, so keep production loggers at
info or above. Auth headers never log at any level.

## Filtered variables

Debug gets switched on during an incident, which is exactly when a
`login(password:)` mutation's variables must not land in the log. So the
values of sensitive keys are replaced with `[FILTERED]` before the line is
written — at any depth, including inside input objects.

In Rails you configure nothing: the railtie adopts the app's own
`config.filter_parameters`, so GraphWeaver scrubs whatever the request logs
already scrub.

Everywhere else, one list:

```ruby
GraphWeaver.filter_parameters = [:password, /token/]
```

Strings and Symbols match as case-insensitive substrings — `:token` covers
`apiToken` — and Regexps match themselves. The default is `[:password,
:token, :secret, :authorization]`, which covers the usual names before
anyone configures anything; assigning replaces it rather than adding to it,
and `[]` turns filtering off. Anything answering `#filter(hash)` is used
as-is, which is how the railtie hands over an
`ActiveSupport::ParameterFilter`.

## Instrumentation

A logger tells a human what happened; an APM needs to time it and count
it. `GraphWeaver.instrumenter` is one callable wrapping every request —
over the wire *and* in-process, one seam for both paths. It's a no-op
until you set one, and `ActiveSupport::Notifications` is a two-line
adapter:

```ruby
GraphWeaver.instrumenter = lambda do |event, payload, &block|
  ActiveSupport::Notifications.instrument(event, payload, &block)
end

ActiveSupport::Notifications.subscribe(GraphWeaver::EXECUTE_EVENT) do |*, payload|
  StatsD.timing("graphql.#{payload[:operation] || "anonymous"}", ...)
end
```

The one event is `GraphWeaver::EXECUTE_EVENT`
(`"graph_weaver.execute"`), a single request from start to parsed
response. Its payload carries:

| Key | |
|-----|--|
| `:url` | the endpoint — nil in-process |
| `:schema` | the schema class's name, in-process only — a String, so a payload logs as it stands |
| `:operation` | the operation name sent with the request (a generated module always has one) — what a trace keys on |
| `:status` | the HTTP status, added once the response lands |

Your callable **must** call the block and return its value. A failure
propagates through it, so the hook sees the exception and can record it.
The query text and the variables are deliberately absent: they carry
PII, and belong at debug on the logger where the level gates them.
