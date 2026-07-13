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
| `info` | schema introspection (with timing) and cache hits/misses, generated files written, query modules loaded |
| `warn` | every GraphWeaver error raised — `TransportError`, `ServerError`, `QueryError`, `ValidationError`, `TypeError` |

Every line carries `graph_weaver` as the progname, so formatter-based
filtering works out of the box. Wire lines are tagged
`[req 3 FilteredPokemon]` — a per-process request id plus the operation
name — so a request's lines stay paired when threads interleave.

Debugging a misbehaving integration is the intended use: crank to
`Logger::DEBUG` and you'll see exactly what went on the wire, what came
back, whether the schema came from cache or a live introspection, and
which connection served it.

**PII note**: queries, variables, and response sizes appear at debug
only — variables can carry user data, so keep production loggers at
info or above (or scrub in your formatter). Auth headers never log at
any level.
