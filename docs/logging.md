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
| `info` | one line per operation in Rails (see Instrumentation), schema introspection (with timing) and cache hits/misses, the transport a client built, generated files written and any unregistered scalars, query modules loaded, a retry's wait and attempt number — and in development, what's being watched and what a save regenerated |
| `warn` | every GraphWeaver error raised — `TransportError`, `ServerError`, `QueryError`, `QueryValidationError`, `CastError` — registrations the schema being generated against can't match, a retry skipped because the operation was a mutation, and every fetch the test router answered with fabricated data |
| `error` | development only: a `.graphql` edit that won't compile, with its file and position — the modules already loaded keep serving |

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
already scrub — including Rails' own default list, which has `:email` on it, so
an ordinary field named `email` reads `[FILTERED]` in `#value` and in the
message the day you add the gem.

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

The same list scrubs error messages, which reach the log at `warn` rather
than `debug`: a variable, input field, or entity key whose name is filtered
is rejected with `[FILTERED]` in place of the value, and a value a message
*quotes* is scrubbed at every depth, so a filtered key one level in reads
`got {"token" => "[FILTERED]"}`. Everything else keeps quoting the value,
since `expected an Int, got "lots"` is the whole diagnosis.

**It reaches what GraphWeaver composes, and nothing else.** That is
`InputError#message` and `#value` on both halves — a server's sentence
included, once it has been read back into an `InputError` — plus the variables
line at debug. A `GraphQLError#message` is the server's or a resolver's own
words and is **passed through untouched**, in `response.errors`, in
`QueryError`'s summary, and in the `warn` line that summary writes. A server
that quotes a rejected password in its message has to be fixed at the server.

## Instrumentation

A logger tells a human what happened; an APM needs to time it and count
it. `GraphWeaver.instrumenter` is one callable wrapping every request —
over the wire *and* in-process, one seam for both paths. It's a no-op until you
set one — and **in Rails you set nothing**: the railtie installs the adapter
below and attaches `GraphWeaver::LogSubscriber` on top of it, so the snippet is
what the framework already did. Everywhere else, it is the line to write:

```ruby
GraphWeaver.instrumenter = lambda do |event, payload, &block|
  ActiveSupport::Notifications.instrument(event, payload, &block)
end
```

An instrumenter you set yourself is never replaced — including
`GraphWeaver.instrumenter = nil` in an initializer, which opts out the
way `GraphWeaver.logger = nil` does. Yours **must** call the block and
return its value; a failure propagates through it, so the hook sees the
exception and can record it.

The one event is `GraphWeaver::EXECUTE_EVENT` (`"execute.graph_weaver"`)
— one request, start to parsed response, whichever client slot served
it, so a single subscriber covers both sides of the seam:

```ruby
ActiveSupport::Notifications.subscribe(GraphWeaver::EXECUTE_EVENT) do |*, payload|
  StatsD.timing("graphql.#{payload[:operation] || "anonymous"}", payload[:duration_ms],
    tags: ["status:#{payload[:status]}", "code:#{payload[:code]}"])
end
```

**A subscriber that raises takes the request down with it** — the response was
computed and is then thrown away. That is `ActiveSupport::Notifications`' own
semantics, the same on `sql.active_record`, so rescue inside the block. A
`GraphWeaver::LogSubscriber` subclass is the exception: it already rescues, and
reports the failure instead of raising it.

### The payload

| Key | When | |
|-----|------|--|
| `:operation` | always | the operation name sent with the request, nil for an anonymous document — what a trace keys on (a generated module always has one) |
| `:client` | always | the class that ran it: `GraphWeaver::Transport::HTTP`, `GraphWeaver::InProcess`, your own |
| `:status` | always | `:ok`, `:errors` (a response carrying GraphQL errors), or `:failed` (it raised) |
| `:duration_ms` | always | start to parsed response, for **this attempt** — under a [`Retry`](transports.md#retries) the backoff sleep between attempts is in none of them, so no event reports the wall clock the caller waited |
| `:url` | over the wire | the endpoint; nil in-process |
| `:http_status` | over the wire | what the server answered with, success or not; nil in-process |
| `:schema` | in-process | the schema class's name, as a String, so a payload logs as it stands |
| `:code` | on `:errors`, and on a `ServerError` | the machine-readable reason — the first `code` *any* of the errors carries, not the first error's, or a `ServerError`'s status. A code that exists beats the absence of one at position 0, which is what an alert groups by. Present and `nil` when the errors carry none |
| `:error` | on `:failed` | the exception's class name |
| `:retries` | under a `Retry` | how many retries this attempt follows. Each attempt is its own event, so one retried call is three events reading 0, 1, 2 — present at 0 rather than absent, so its absence means nothing was retrying |
| `:graph` | always | the [graph](getting_started.md#more-than-one-schema) the generated module was declared under, as a Symbol — `nil` for a module that names none, and for a client called directly. Never inferred from the client: a wrong graph on a request is worse than no graph |

Every key is filled in before your callable's block returns, so a
subscriber reads a complete payload. `ActiveSupport::Notifications` adds
`:exception` and `:exception_object` of its own when the block raises.

**`:graph` labels one request.** A generated module's `execute` labels the
request *it* makes — each of them, when a federated operation fans out to
several subgraphs. It never labels what a *server* does while answering
one: an in-process resolver that calls out produces an event of its own,
carrying its own graph or `nil`. So `:graph` always reads "this request
went to that graph", which is the only claim a dashboard can group by.

One edge: the label is fiber-local, so a dispatch that crosses a `Fiber` —
graphql-ruby's `Dataloader` does — arrives with `:graph` unset. No label
rather than a wrong one, which is the same trade as the paragraph above.

**Never the query text or the variables.** `filter_parameters` scrubs
what reaches the log, which GraphWeaver writes itself; the payload fans
out to subscribers that know none of those rules, so here the rule isn't
"scrub it", it's that it was never there. Queries and variables stay at
debug on the logger, where the level gates them.

`:url` is the one thing on the payload that *is* scrubbed, because a url can
itself be a credential: its userinfo, and any query parameter
`filter_parameters` filters, are folded to `[FILTERED]` — the same list, the
same spelling — before the payload, a log line or a `TransportError` says it.

### One line per operation

In Rails the railtie also attaches `GraphWeaver::LogSubscriber`, which
turns each event into one line — the shape ActiveRecord uses for a query:

```
GraphWeaver PersonQuery (12.3ms) ok
GraphWeaver PersonQuery (8.1ms) errors [THROTTLED]
GraphWeaver PersonQuery (31.2ms) failed GraphWeaver::TransportError
GraphWeaver PersonQuery (5.0ms) ok (retry 2)
GraphWeaver billing/InvoicesQuery (12.3ms) ok
```

The operation is prefixed by its graph when the request carried one, so an
app with several graphs sorts its own log and an app with one never sees
the prefix.

**One rule: the summary is info, the wire is debug.** This is the only
GraphWeaver line at info, so a production log gets one per operation and
nothing that can carry PII; turning the logger up to debug adds the
query, the variables and the response *beneath* it rather than repeating
it. It writes through `GraphWeaver.logger`, so `GraphWeaver.logger = nil`
silences this along with everything else.

Outside Rails there's no railtie to attach it, so the same line is an
instrumenter of your own — read the payload in an `ensure`, since it is only
complete once the block has returned:

```ruby
log = Logger.new("log/graphql.log")

GraphWeaver.instrumenter = lambda do |_event, payload, &block|
  block.call
ensure
  log.info { "#{payload[:operation] || "anonymous"} (#{payload[:duration_ms]}ms) #{payload[:status]}" }
end
```

```
I, [2026-09-12T18:40:33.032236 #97490]  INFO -- : PersonQuery (19.57ms) ok
I, [2026-09-12T18:40:33.037186 #97490]  INFO -- : DraftsQuery (4.67ms) errors
```

### OpenTelemetry

```ruby
tracer = OpenTelemetry.tracer_provider.tracer("graph_weaver")

GraphWeaver.instrumenter = lambda do |_event, payload, &block|
  tracer.in_span("graphql #{payload[:operation] || "query"}") do |span|
    block.call
  ensure
    span.add_attributes(payload.compact.transform_keys { "graphql.#{_1}" }.transform_values(&:to_s))
  end
end
```

`ensure` rather than after the call: the payload is only complete once
the block has returned, and a failed span needs the attributes most.
`in_span` records the exception and sets the span status itself.

### Datadog

```ruby
GraphWeaver.instrumenter = lambda do |event, payload, &block|
  Datadog::Tracing.trace(event, resource: payload[:operation], service: "graphql") do |span|
    block.call
  ensure
    payload.compact.each { |key, value| span.set_tag("graphql.#{key}", value.to_s) }
  end
end
```

Datadog's Net::HTTP and Faraday contribs already trace the transport
layer, so with them on you have a span for the POST. This adds the span
*above* it, named for the operation — the one that means anything, since
every GraphQL call is a POST to the same url.
