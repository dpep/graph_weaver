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
| `debug` | the wire: query + variables per call (long queries truncated), response status/bytes/content type, request timing, connection open/drop, dynamically parsed modules |
| `info` | one line per operation in Rails (see Instrumentation), schema introspection (with timing) and cache hits/misses, the transport a client built, generated files written and any unregistered scalars, query modules loaded, a retry's wait and attempt number — and in development, what's being watched and what a save regenerated |
| `warn` | every GraphWeaver error raised — `TransportError`, `ServerError`, `QueryError`, `QueryValidationError`, `CastError` — registrations the schema being generated against can't match, a retry skipped because the operation was a mutation, and every fetch the test router answered with fabricated data |
| `error` | development only: a `.graphql` edit that won't compile, with its file and position — the modules already loaded keep serving |

Every line carries `graph_weaver` as the progname, so formatter-based
filtering works out of the box. Wire lines are tagged
`[req 4123-3 FilteredPokemon]` — the pid, that process's own request count,
and the operation name — so a request's lines stay paired when threads
interleave, and stay distinct when a Puma cluster's workers write to one log.

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
and `[]` turns filtering off — for variables and messages. A credential in the
*url* is scrubbed either way (see [the payload](#the-payload)). Anything answering `#filter(hash)` is used
as-is, which is how the railtie hands over an
`ActiveSupport::ParameterFilter`.

The same list scrubs error messages, which reach the log at `warn` rather
than `debug`: a variable, input field, or entity key whose name is filtered
is rejected with `[FILTERED]` in place of the value, and a value a message
*quotes* is scrubbed at every depth, so a filtered key one level in reads
`got {"token" => "[FILTERED]"}`. Everything else keeps quoting the value,
since `expected an Int, got "lots"` is the whole diagnosis.

## The channels that carry text we didn't author

A log line, an exception and an APM tag all outlive the request, and each one
can carry text somebody else wrote — a value you sent, a page a proxy served, a
code a server chose. Every such channel has a policy, and there are no others:

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
| `GraphQLError#message` | the server's own words, **passed through untouched** |
| `extensions.code` → the info line, the APM `:code` | control characters stripped, capped — a tag can't forge a line |
| the endpoint, everywhere it is said | userinfo and credential query parameters folded to `[FILTERED]` |
| `#inspect` on any public object | its class and its safe url; never a header, a context or a body |

**A message never carries a body.** `Error#initialize` writes every message to
the log at `warn`, which is the level production runs at — and the commonest
non-2xx body in the world is a framework error page that echoes the request,
Authorization header included. So the bytes stay on `#body` for whoever rescues
the error, and the log says the status, the size and the content type.

**A `GraphQLError#message` is the one thing passed through untouched** — in
`response.errors`, in `QueryError`'s summary, and in the `warn` line that
summary writes. It is the server's or a resolver's own words, and a server that
quotes a rejected password in its message has to be fixed at the server.

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
    tags: ["status:#{payload[:status]}", "kind:#{payload[:kind]}", "code:#{payload[:code]}"])
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
| `:kind` | always | `:query`, `:mutation` or `:subscription` — what the document runs, so a write failure rate is a payload question rather than a guess at the operation's name. The shorthand `{ ... }` document is a `:query`. The same reading decides whether [`Retry`](transports.md#retries) may repeat the request |
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
A url credential is scrubbed **whatever your logging appetite**: the default
names apply to a url's query parameters even when you have emptied or narrowed
`filter_parameters`, which is a knob about how much the log says, not about
whether a token in an endpoint is a token. Your list widens this; it can't
narrow it.

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

## What is process-global, and who owns it

Three things outlive a single request, and each of them meets more than one
writer in a shipped configuration — a Puma cluster, a multi-graph app, a
`parallel_tests` run. Each has one owner now, so none of them needs a
convention on your side:

| Resource | Several writers arrive from | Who keeps them apart |
|----------|-----------------------------|----------------------|
| the `[req …]` counter | a Puma cluster: forked workers inherit it | the tag carries the pid, and the count restarts in a new process |
| the schema cache file | two clients both saying `cache: true` | a dump records its source url; a client that didn't write it caches under a name of its own ([getting started](getting_started.md)) |
| a cassette | `parallel_tests`, one cassette, several processes | a recorder re-reads and rewrites under a `flock` ([testing](testing.md)) |

The two things that are *not* process-global and shouldn't be made so: a
client's GraphQL context (per client, guarded by the client — see
`GraphWeaver::ContextSeam`), and a connection pool (per process, rebuilt after
a fork).
