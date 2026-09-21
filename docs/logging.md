# Logging

Silent by default. Point `GraphWeaver.logger` at anything
stdlib-Logger-compatible and the whole flow narrates itself — in Rails the
railtie wires `Rails.logger` automatically (set `GraphWeaver.logger = nil` in an
initializer to opt out):

```ruby
GraphWeaver.logger = Logger.new($stdout, level: Logger::INFO)
```

Pick the level, get the story:

| Level | What you see |
|-------|--------------|
| `debug` | the wire: query + variables per call (long queries truncated), response status/bytes/content type, request timing, one line per attempt (its url status and which retry it was), connection open/drop, dynamically parsed modules |
| `info` | one line per call in Rails (see [Instrumentation](#instrumentation)), schema introspection (with timing) and cache hits/misses, the transport a client built, generated files written and any unregistered scalars, query modules loaded, a retry's wait and attempt number — and in development, what's being watched and what a save regenerated |
| `warn` | every GraphWeaver error raised — `TransportError`, `ServerError`, `QueryError`, `QueryValidationError`, `CastError` — registrations the schema being generated against can't match, a retry skipped because the operation was a mutation, and every fetch the test router answered with fabricated data |
| `error` | development only: a `.graphql` edit that won't compile, with its file and position — the modules already loaded keep serving |

Every line carries `graph_weaver` as the progname, so formatter-based filtering
works out of the box. Wire lines are tagged `[req 4123-3 FilteredPokemon]` — pid,
that process's own request count, operation name — so a request's lines stay
paired when threads interleave and distinct when a Puma cluster's workers share a
log.

**PII note**: queries, variables and response sizes appear at debug only, so keep
production loggers at info or above. Auth headers never log at any level.

## Filtered variables

Debug gets switched on during an incident, which is exactly when a
`login(password:)` mutation's variables must not land in the log. So the values of
sensitive keys are replaced with `[FILTERED]` before the line is written, at any
depth, including inside input objects.

In Rails you configure nothing: the railtie adopts the app's own
`config.filter_parameters`, so GraphWeaver scrubs whatever the request logs
already scrub — Rails' own default list has `:email` on it, so an ordinary field
named `email` reads `[FILTERED]` the day you add the gem.

Everywhere else, one list:

```ruby
GraphWeaver.filter_parameters = [:password, /token/]
```

Strings and Symbols match as case-insensitive substrings — `:token` covers
`apiToken` — and Regexps match themselves. The default is `[:password, :token,
:secret, :authorization]`; assigning replaces it rather than adding to it, and
`[]` turns filtering off for variables and messages. A credential in the *url* is
scrubbed either way. Anything answering `#filter(hash)` is used as-is, which is
how the railtie hands over an `ActiveSupport::ParameterFilter`.

The same list scrubs error messages, which reach the log at `warn` rather than
`debug`: a variable, input field or entity key whose name is filtered is rejected
with `[FILTERED]` in place of the value, at every depth — a filtered key one level
in reads `got {"token" => "[FILTERED]"}`. Everything else keeps quoting the
value, since `expected an Int, got "lots"` is the whole diagnosis.

## Instrumentation

A logger tells a human what happened; an APM needs to time it and count it.
`GraphWeaver.instrumenter` is one callable wrapping every call GraphWeaver
makes — over the wire *and* in-process. **In Rails you set nothing**: the
railtie installs the adapter below and attaches `GraphWeaver::LogSubscriber` on
top of it. Everywhere else:

```ruby
GraphWeaver.instrumenter = lambda do |event, payload, &block|
  ActiveSupport::Notifications.instrument(event, payload, &block)
end
```

An instrumenter you set yourself is never replaced — including
`GraphWeaver.instrumenter = nil`, which opts out. Yours **must** call the block
and return its value; a failure propagates through it, so the hook sees the
exception and can record it.

There are two events, and the second happens inside the first:

| Event | One of these is |
|-------|-----------------|
| `GraphWeaver::OPERATION_EVENT` (`"operation.graph_weaver"`) | one call of a generated module's `execute`/`execute!`, start to typed result or raise — the request it made, every retry and backoff beneath it, and the cast into your structs |
| `GraphWeaver::EXECUTE_EVENT` (`"execute.graph_weaver"`) | one request, start to parsed response, whichever client slot served it — so a call a [`Retry`](transports.md#retries) took three goes at is one operation event and three of these |

**Alert on the operation event**: it is the one that says what the *caller*
got. A `CastError` is raised after the response is back, so the request has
already closed `:ok` by the time the app sees a failure. It also fires at the
module seam, which every client slot passes through — a [test mode's](testing.md)
fake, the router and a cassette all report here, so a spec can assert on
instrumentation under any `graphql:` tag.

```ruby
ActiveSupport::Notifications.subscribe(GraphWeaver::OPERATION_EVENT) do |*, payload|
  StatsD.timing("graphql.#{payload[:operation] || "anonymous"}", payload[:duration_ms],
    tags: ["status:#{payload[:status]}", "kind:#{payload[:kind]}", "code:#{payload[:code]}"])
end
```

Two calls don't produce one. `from_response` on its own reports nothing — no
call was made. And a module generated by 0.7.5 or earlier shows this seam
only half of one, so it emits the request event alone until you regenerate:
half a call reported `:ok` is the very thing the event exists to stop.

**A subscriber that raises takes the call down with it** — the response was
computed and is then thrown away. That is `ActiveSupport::Notifications`' own
semantics, the same on `sql.active_record`, so rescue inside the block. A
`GraphWeaver::LogSubscriber` subclass already does.

### The operation payload

| Key | When | |
|-----|------|--|
| `:operation` | always | the operation name sent with the request, nil for an anonymous document — what a trace keys on (a generated module always has one) |
| `:module` | always | the generated module's name, as a String — `nil` for one with no name (a [`GraphWeaver.parse`](getting_started.md)). The fact this seam has and the request doesn't: two graphs can name the same operation, and a trace that is slow wants the file |
| `:graph` | always | the [graph](getting_started.md#more-than-one-schema) the module was declared under, as a Symbol — `nil` for a module that names none. Never inferred from the client |
| `:kind` | always | `:query`, `:mutation` or `:subscription` — what the document runs, so a write failure rate is a payload question rather than a guess at the operation's name. The shorthand `{ ... }` document is a `:query`. The same reading decides whether [`Retry`](transports.md#retries) may repeat the request |
| `:client` | always | the client the module **resolved to**: a test mode's stand-in names itself, a graph's client names itself, and over the wire it is `GraphWeaver::Client` — the request event beneath names the transport that carried it |
| `:status` | always | `:ok` (a typed result), `:errors` (the response carried GraphQL errors — what `execute!` raises `QueryError` for), or `:failed` (the call raised: the transport, a `CastError`, anything) |
| `:duration_ms` | always | the caller's wall clock — dispatch, every retry *and its backoff*, and the cast |
| `:code` | on `:errors` | the machine-readable reason, as on the request event |
| `:error` | on `:failed` | the exception's class name |

Not on it: `:url`, `:http_status`, `:retries`. Those describe one attempt, and
a call that took three goes has no single answer for any of them — read them
off the request events nested inside.

### The request payload

| Key | When | |
|-----|------|--|
| `:operation` | always | the operation name sent with the request, nil for an anonymous document |
| `:client` | always | the class that ran it: `GraphWeaver::Transport::HTTP`, `GraphWeaver::InProcess`, your own |
| `:kind` | always | `:query`, `:mutation` or `:subscription`, read off the document |
| `:status` | always | `:ok`, `:errors` (a response carrying GraphQL errors), or `:failed` (it raised) |
| `:duration_ms` | always | start to parsed response, for **this attempt** — the backoff between attempts belongs to the operation event above, which is where the caller's wall clock lives |
| `:url` | over the wire | the endpoint; nil in-process |
| `:http_status` | over the wire | what the server answered with, success or not; nil in-process |
| `:schema` | in-process | the schema class's name, as a String, so a payload logs as it stands |
| `:code` | on `:errors` | the machine-readable reason, always a String or `nil` — the first `extensions.code` *any* of the errors carries, not the first error's, since a code that exists beats the absence of one at position 0. Present and `nil` when the errors carry none. Never an HTTP status: that is `:http_status` |
| `:error` | on `:failed` | the exception's class name |
| `:retries` | under a `Retry` | how many retries this attempt follows. Each attempt is its own event, so one retried call is three events reading 0, 1, 2 — present at 0 rather than absent, so its absence means nothing was retrying |
| `:graph` | always | the same label the operation above it carries, and `nil` for a request no generated module made — a client called directly. Never inferred from the client: a wrong graph on a request is worse than no graph |

Every key is filled in before your callable's block returns, so a subscriber
reads a complete payload; `ActiveSupport::Notifications` adds `:exception` and
`:exception_object` of its own when the block raises.

**`:graph` labels one request**, never what a *server* does while answering one:
an in-process resolver that calls out produces an event of its own. The label is
fiber-local, so a dispatch that crosses a `Fiber` — graphql-ruby's `Dataloader`
does — arrives with `:graph` unset. No label rather than a wrong one.

**Never the query text or the variables**, on either event: the payload fans out
to subscribers that know none of the filtering rules, so the rule here isn't
"scrub it", it's that it was never there. `:url` is the one thing on either
payload that *is* scrubbed, because a url can itself be a credential — and the
default names apply to its query parameters even when you have emptied or
narrowed `filter_parameters`. Your list widens that; it can't narrow it.

### One line per operation

In Rails the railtie also attaches `GraphWeaver::LogSubscriber`, which turns
each operation event into one line — the shape ActiveRecord uses for a query:

```
GraphWeaver PersonQuery (12.3ms) ok
GraphWeaver PersonQuery (8.1ms) errors [THROTTLED]
GraphWeaver PersonQuery (31.2ms) failed GraphWeaver::TransportError
GraphWeaver PersonQuery (44.0ms) failed GraphWeaver::CastError
GraphWeaver billing/InvoicesQuery (12.3ms) ok
```

The operation is prefixed by its graph when the call carried one, so an app
with several graphs sorts its own log and an app with one never sees the prefix.

**The operation is info, the attempt is debug.** The info line is one *call*, so
it says what the caller got and a production log gets one per call — a retried
call included, whose attempts and their backoff are inside that one duration.
Debug adds a line per attempt in the same shape, carrying the url's status and
which try it was, beneath the query and the variables. It writes through
`GraphWeaver.logger`.

Outside Rails the same line is an instrumenter of your own, writing
`payload[:operation]`, `[:duration_ms]` and `[:status]` from an `ensure` — the
shape the two tracing examples below use.

### OpenTelemetry

A span per operation, with a span per attempt inside it:

```ruby
tracer = OpenTelemetry.tracer_provider.tracer("graph_weaver")

GraphWeaver.instrumenter = lambda do |event, payload, &block|
  name = event == GraphWeaver::OPERATION_EVENT ? "graphql #{payload[:operation] || "query"}" : "graphql request"

  tracer.in_span(name) do |span|
    block.call
  ensure
    span.add_attributes(payload.compact.transform_keys { "graphql.#{_1}" }.transform_values(&:to_s))
    span.status = OpenTelemetry::Trace::Status.error(payload[:code] || "graphql errors") if payload[:status] == :errors
  end
end
```

`ensure` rather than after the call: the payload is only complete once the block
has returned, and a failed span needs the attributes most. `in_span` sets the
span status itself for a *raise* only, which is the last line's reason to exist.

**Span status is not the alerting signal; `payload[:status]` is.** A response
carrying GraphQL errors is a 200 that returned normally, so nothing raises and a
span left to itself is `UNSET` — an SLO built on span status alone misses every
GraphQL-level failure there is. Alert on the operation event's `:status` and
group by `:code`.

**Propagating the trace outward** is a header, and a
[header value may be a callable](transports.md#headers) resolved per request —
inside the span, which is what makes it work:
`headers: { "traceparent" => -> { {}.tap { OpenTelemetry.propagation.inject(_1) }["traceparent"] } }`.

### Datadog

```ruby
GraphWeaver.instrumenter = lambda do |event, payload, &block|
  Datadog::Tracing.trace(event, resource: payload[:operation], service: "graphql") do |span|
    block.call
  ensure
    payload.compact.each { |key, value| span.set_tag("graphql.#{key}", value.to_s) }
    span.set_error([payload[:code], "graphql errors"]) if payload[:status] == :errors
  end
end
```

One hook covers both events, and the event name is the span name — so an
operation and its attempts nest under distinct resources. Datadog's Net::HTTP
and Faraday contribs already trace the transport layer, so with them on you have
a span for the POST as well. This adds the spans *above* it, and the one named
for the operation is the one that means anything, since every GraphQL call is a
POST to the same url.

## Details

### What carries text we didn't author

A log line, an exception and an APM tag all outlive the request, and each can
carry text somebody else wrote. Every such channel has a policy, and there are no
others:

| Channel | Policy |
|---------|--------|
| the variables line | scrubbed through `filter_parameters` at every depth, and written at **debug** only |
| the query text | debug only, truncated |
| `InputError#message`, `#value`, `#to_h` | `[FILTERED]` under a filtered key, at every depth; capped at 1 KB |
| `ServerError#message` | the status, what *we* judged wrong, the hint, the safe url — **never the body** |
| `ServerError#body` | the bytes verbatim. This is the channel that carries them, which is why no other has to |
| `ServerError#to_h` | status, `retry_after`, url — the body and the headers stay off it (read `#headers`) |
| a redirect's `Location` | a url the server chose, folded the way we fold our own |
| `TransportError#message` | the adapter's own sentence, capped, plus the safe url |
| `GraphQLError#message` | the server's own words, **passed through untouched** — a server that quotes a rejected password has to be fixed at the server |
| `extensions.code` → the info line, the APM `:code` | control characters stripped, capped — a tag can't forge a line |
| the endpoint, everywhere it is said | userinfo and credential query parameters folded to `[FILTERED]` |
| `#inspect` on any public object | its class and its safe url; never a header, a context or a body |

The rule behind the `ServerError` rows: every raised error writes its message to
the log at `warn`, and the commonest non-2xx body in the world is a framework
error page echoing the request, `Authorization` header included.

### What is process-global, and who owns it

Three things outlive a single request and meet more than one writer in a shipped
configuration. Each has one owner, so none needs a convention on your side:

| Resource | Several writers arrive from | Who keeps them apart |
|----------|-----------------------------|----------------------|
| the `[req …]` counter | a Puma cluster: forked workers inherit it | the tag carries the pid, and the count restarts in a new process |
| the schema cache file | two clients both saying `cache: true` | a dump records its source url; a client that didn't write it caches under a name of its own ([getting started](getting_started.md)) |
| a cassette | `parallel_tests`, one cassette, several processes | a recorder re-reads and rewrites under a `flock` ([testing](testing.md)) |

Two things are *not* process-global and shouldn't be made so: a client's GraphQL
context (per client, guarded by the client — see `GraphWeaver::ContextSeam`), and
a connection pool (per process, rebuilt after a fork).
