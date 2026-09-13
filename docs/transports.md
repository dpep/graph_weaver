# Transports

Where queries actually go: what fills the client slot, how to build and tune the
bundled HTTP transports, and how a generated module decides which one to use.
Read it when the default one-liner isn't enough — custom headers, mTLS, Faraday
middleware, retries, or connection pooling under load.

A *client* is anything with `execute(query, variables:, operation_name:)` whose result
`to_h`s into `{"data" => ..., "errors" => ...}` — from a full
`GraphWeaver::Client` down to a schema class
([in-process execution](getting_started.md#your-apps-own-schema-in-process) —
typed access to your own app's API, no socket), a [FakeClient](testing.md), or
anything you write. Every slot that takes a client accepts any of them.

**Anything holding a schema parses against it.** `client.parse(query)`, and
the same on `InProcess`, `FakeClient` and `Testing::Router` — a typed module
bound to that schema, running on that object, without naming either. It sits
on top of the contract rather than in it: `Retry` wraps a client and holds no
schema, so it has no `parse`, and a bare schema class fills the client slot
without one. `load_queries!` is the same rule over a directory.

A *transport* is the network end of that contract — GraphQL-over-HTTP. The bundled
two — `Transport::HTTP` (net/http, zero dependencies, loaded by default)
and `Transport::Faraday` (opt-in: naming it loads faraday, so an app that
doesn't needs no faraday) — subclass `GraphWeaver::Transport`,
which owns the shared flow: encode the request, reclassify network
failures as `TransportError`, raise `ServerError` on non-2xx, parse the
body. A subclass only implements `post(body) => [status, body]` — that's
the whole recipe for bringing your own HTTP client.

## One-shot setup: a client

Most apps need one line:

```ruby
github = GraphWeaver.new("https://api.example.com/graphql", auth: ENV["API_TOKEN"])
```

`GraphWeaver.new` builds a [`Client`](real_world.md): a transport with
auth applied (exposed as `client.transport`), the schema introspected
lazily, and `parse`/`run` bound to both. A `Client` answers the client
contract itself, so it goes anywhere a transport does — `Retry.new(client)`,
`subgraphs:`, a cassette recorder.

- `auth:` — a token; "Bearer" is assumed unless the string carries its own
  scheme (`"Basic dXNlcjpwYXNz..."`)
- `transport:` — `:http` (the default) or `:faraday`
- `headers:` — anything else (API keys, custom headers)
- `retries:` — off by default; a count of the attempts *after* the first
  (`retries: 3` makes up to four), or `true` for `Retry`'s own default of 2.
  Every other [`Retry`](#retries) option sits beside it (`backoff:`,
  `retry_codes:`, ...)
- `open_timeout:` / `read_timeout:` — seconds, defaulting to 10 and 30 on
  either transport
- `pool_size:` — how many sockets the bundled HTTP transport keeps open,
  defaulting to `RAILS_MAX_THREADS` (else 5). Refused with
  `transport: :faraday`, whose adapter owns its own connections — a ceiling
  here would be a number nothing reads
- `cache:` / `ttl:` — schema introspection caching (see
  [real world](real_world.md)); url clients only — a schema source never
  introspects, so passing them raises
- a block customizes the Faraday connection (Faraday only — raises without it)

They combine, so the whole thing is still one call:

```ruby
GraphWeaver.new(url, transport: :faraday, retries: 2) do |conn|
  conn.response :logger
end
```

What you pass is what you get; the client logs which transport it built at
`info`.

To wire generated modules that don't bake a client, make it the app's
default: `GraphWeaver.client = github`. Anything satisfying the execute
contract works there — testing's `graphql:` tag swaps in a client per example.

## Building blocks

The client is convenience, not the only door — construct and assign
yourself for full control:

```ruby
# zero-dependency Net::HTTP — a pool of persistent (keep-alive)
# connections; timeouts raise retriable TransportError
GraphWeaver::Transport::HTTP.new(
  url,
  headers: { ... },
  open_timeout: 10, read_timeout: 30,  # seconds (the defaults)
  keep_alive_timeout: 2,               # idle window before reconnecting
  pool_size: 5,                        # concurrent requests in flight
                                       # (default: RAILS_MAX_THREADS, else 5)

  # TLS, forwarded to Net::HTTP.start — a private CA, or mTLS, without
  # reaching for Faraday. Passing any of these to an http:// url raises
  # rather than quietly doing nothing.
  ca_file: "/etc/ssl/private-ca.pem",  # or ca_path: for a directory
  cert: OpenSSL::X509::Certificate.new(File.read("client.crt")),
  key: OpenSSL::PKey::RSA.new(File.read("client.key")),
  verify_mode: OpenSSL::SSL::VERIFY_PEER,  # the default; VERIFY_NONE to skip
)

# Faraday: a url (+ optional middleware block), or a ready connection.
# Timeouts default to the same 10/30 as Transport::HTTP — without them
# Faraday inherits net/http's 60s/60s.
GraphWeaver::Transport::Faraday.new(url, open_timeout: 10, read_timeout: 30)
GraphWeaver::Transport::Faraday.new(url) do |conn|
  conn.request :authorization, "Bearer", -> { Tokens.fetch }  # dynamic tokens
  conn.response :logger
end
GraphWeaver::Transport::Faraday.new(MyApp.faraday_connection)

# One Faraday::Connection is reused for the transport's lifetime, but
# socket keep-alive depends on the ADAPTER (see below) — the transport
# logs the one it ended up with at :info:
GraphWeaver::Transport::Faraday.new(url) do |conn|
  conn.adapter :net_http_persistent
end

# In-process: a live graphql-ruby schema class, no socket — typed access
# to your own app's API. The class alone works in any client slot; the
# wrapper adds a request context, the same debug logging the network
# transports emit, and errors branded under GraphWeaver::Error (a resolver
# raise becomes a ServerError, status 500, with the original as #cause).
GraphWeaver::InProcess.new(MySchema, context: { current_user: user })
GraphWeaver.new(MySchema, context: { current_user: user })   # same, via a client

GraphWeaver.client = ...   # the app default (a Client or any of the above)
```

**Keeping Faraday's sockets alive.** Faraday's default `net_http` adapter
opens a fresh connection per request — 10 TCP connections for 10 requests,
and over HTTPS a TLS handshake each time. `:net_http_persistent` is the
adapter that gets Faraday the connection reuse and thread-safe pooling
`Transport::HTTP` has by default. It needs two gems, and the version
pairing matters — **Faraday 2.x requires `faraday-net_http_persistent`
2.x**; the Faraday-1.x-era 1.2.0 raises `NoMethodError: undefined method
'dependency' for class Faraday::Adapter::NetHttpPersistent` at load:

```ruby
gem "net-http-persistent"                      # the HTTP client
gem "faraday-net_http_persistent", "~> 2.0"    # the Faraday adapter for it
```

graph_weaver depends on neither and never selects an adapter for you.

**Headers.** Both transports send `Content-Type: application/json`,
`Accept: application/graphql-response+json, application/json;q=0.9` (the
media type [GraphQL-over-HTTP](https://graphql.github.io/graphql-over-http/draft/)
requires a conforming client to accept, with the legacy type as
fallback), and `User-Agent: graph_weaver/<version>` so a server operator
can attribute the traffic. Anything you pass in `headers:` wins over
these. A prebuilt `Faraday::Connection` owns its own headers; only the
ones it leaves unset are filled in — and Faraday's stock
`User-Agent: Faraday v…`, which it fills in for every connection whether
you asked or not, counts as unset.

**Who the graph thinks is calling.** Both transports also send
`apollographql-client-name` and `apollographql-client-version`, which is
what an Apollo Router or GraphOS keys client attribution on — per-client
SLOs and rate limits, and "who still asks for this deprecated field". The
name is your Rails application's (`Storefront`), or `graph_weaver` outside
Rails, since Apollo means the consuming *application*; the version is the
gem's, because graph_weaver can't know what your app calls its releases.
Both are plain headers, so `headers:` overrides them — which is how one app
names its several clients apart:

```ruby
GraphWeaver::Transport::HTTP.new(url, headers: {
  "apollographql-client-name" => "storefront-checkout",
  "apollographql-client-version" => ENV.fetch("GIT_SHA"),
})
```

**A header that expires.** On `Transport::HTTP` a header *value* may be
anything answering `#call`, resolved per request rather than captured when the
transport was built — the same way a graph's [`schema`](federation.md) takes a
lambda. A value (or a call) of `nil` sends no such header; anything else is
sent as its `to_s`, so a numeric tenant id needs no ceremony:

```ruby
GraphWeaver::Transport::HTTP.new(url, headers: {
  "Authorization" => -> { "Bearer #{Tokens.fetch}" },   # rotating token
  "X-Tenant" => -> { Current.tenant&.id },              # nil ⇒ header omitted
})
```

On `Transport::Faraday` a callable header raises instead — Faraday resolves
this in middleware (`conn.request :authorization, "Bearer", -> { Tokens.fetch }`),
which is the sample above, and keeping one way per transport beats two.

**Compression and proxies** need no configuration on either transport.
`net/http` — which both use underneath — asks for `gzip`/`deflate` on every
request and decodes what comes back, and it reads `http_proxy` / `HTTPS_PROXY`
and `no_proxy` from the environment. A proxy is never used for a loopback
address, which is Ruby's rule, not ours.

**The endpoint an error names** is the url with its userinfo and any secret
query parameter folded to `[FILTERED]` — see [errors](errors.md). `#url` on a
transport stays the real endpoint; `#safe_url` is the one that goes in a log
line, an exception or an APM payload.

**Request body.** `{"query": ..., "variables": ...}`, plus
`"operationName"` when the operation has a name — the field Apollo Studio,
Hasura and most APMs key traces, rate limits and slow-query reports on.
Generated modules always send one — an anonymous document is named after its
module at generation, so the name is declared in the query too. A raw query
string handed straight to a transport falls back to the name in the document,
and a genuinely anonymous one sends no `operationName` key at all.

**Concurrency.** One transport is normally the whole app's transport
(`GraphWeaver.client = api`), so it has to serve every thread.
`Transport::HTTP` opens up to `pool_size:` sockets lazily and reuses the
warmest one; requests beyond that queue for a free slot rather than
opening unbounded connections. A socket that errors is closed and its slot
left empty, so the next call reconnects.

A url client introspects its schema lazily, and the first requests of a cold
process arrive together — so that fetch is done **once**, by whoever asks
first, with the rest waiting on it rather than each making its own round trip
and writing its own copy of the schema cache.

`pool_size:` defaults to `RAILS_MAX_THREADS` (else 5) — the same variable
Rails sizes its own connection pool from, because it is the same question:
how many requests this process can have in flight at once. Lower it for a
server that counts connections.

**The pool is fork-safe**, which is what a Puma or Unicorn worker under
`preload_app!` needs. A socket warmed before the fork — an initializer that
introspects the schema is enough — is otherwise inherited by every worker, and
nothing in a round trip says which process opened it, so two workers
interleaving on one fd hand each other's answers back. A child notices the pid
changed and starts over: the inherited sockets are **abandoned rather than
closed** (closing would take down the fd the parent is still using) and
reconnect on first use, and the permits are rebuilt, since any held at fork time
went with the threads that held them. There is no `after_fork` hook to write.

Under a fiber scheduler (`async`, Falcon) everything here works unchanged —
`SizedQueue`, `Mutex`, `net/http` and `Kernel#sleep` are all scheduler-aware,
so requests multiplex on one thread at thread-equivalent throughput. But
`pool_size:` is the same hard ceiling there, and nothing sets
`RAILS_MAX_THREADS` for you, so set it to the concurrency you expect.
Saturation is not silent: the first request that has to queue logs a warning
naming how long it waited and what to raise.

## Client resolution

The canonical order — how a generated module finds its client (each slot
takes a `Client` or any bare transport/fake):

1. per call: `execute(client: some_client, ...)` — a kwarg like the
   variables, and a name no GraphQL variable is allowed to take
2. per module: `MyQuery.client = something`
3. a test mode's stand-in: under `graphql: :fake` / `:in_process` /
   `:router`, built from the graph this module was generated from
4. baked constant: `Codegen.generate(..., client: "MyApi::CLIENT")` — the
   constant's *name*, not the object, because generated source spells it
5. the app default: `GraphWeaver.client=`

The mode replaces what codegen baked in, not what your example said — 1 and 2
still win.

Nothing set anywhere raises, naming the two you'd usually reach for:
`no client configured — set GraphWeaver.client= or pass a client`.

## Retries

A url client retries when you give it a count; the rest of the options
sit beside it:

```ruby
GraphWeaver.new(
  url,
  retries: 5,                      # attempts after the first
  backoff: :exponential,           # or :linear, or ->(attempt) { seconds }
  base_delay: 0.5, max_delay: 30,  # seconds; delays clamp at max_delay:
  jitter: true,                    # randomize each delay by 50-100%
  retry_on: [GraphWeaver::TransportError, GraphWeaver::ServerError],
  retry_if: ->(error) { ... },     # fine-grain within retry_on:
  retry_codes: ["THROTTLED"],      # also retry GraphQL errors by code
  retry_mutations: false,          # true if your mutations are idempotent
)
```

`GraphWeaver::Retry.new(inner_transport, ...)` takes the same options and
wraps any client/transport directly — the client just passes them along.

Defaults: transport failures always retry; a response retries when its
status is 5xx or **408 or 429** — the rest of 4xx is a bug in the request,
retrying won't fix it. That's one rule for both shapes a failure arrives
in: raised as a `ServerError`, or returned in the envelope because the
server sent GraphQL errors alongside the status. Apollo Router does the
latter for everything it decides itself — rate limiting is `503` with a
`REQUEST_RATE_LIMITED` body — so a policy that read only the raised half
made exactly one attempt behind a router. `retry_codes:` adds the other
signal: error codes, at any status (off by default — pass the codes your
API uses, or `GraphWeaver::GraphQLError::THROTTLE_CODES`). Exhausting the
retries re-raises the last error (or returns the last response).

A `200` is never retried on its status, whatever it carries. A router that
gives up on a slow subgraph answers `200` with partial data and a
`GATEWAY_TIMEOUT` error: the caller already has an answer, and whether a
partial one is worth repeating is a judgment only the caller can make —
`retry_codes: ["GATEWAY_TIMEOUT"]` is how they say yes.

**Nothing else retries**, which is the half a script author needs: a `200`
the server stands behind, and an `InputError` (the variables never left the
process), are permanent by construction — the identical request gets the
identical answer. Only a failure the server itself marked transient, by
status or by code, is worth repeating.

`retries:` counts the attempts *after* the first, so
`GraphWeaver.new(url, retries: 3)` makes up to four and `retries: 0` never
retries; `retries: true` takes `Retry`'s own default of 2. Every misspelling
raises rather than quietly doing nothing — a retry option passed without a
count says so, and the old Hash form (`retries: { retries: 5 }`) names its
flat replacement.

**A mutation gets one attempt.** A failure with no answer — a read
timeout, a 502, a reset socket — does not say whether the server applied
it, and a second `charge` is worse than a failed one.
`retry_mutations: true` opts an idempotent API back in; the skipped
retry says so on the logger.

The cap is on **attempts**, not on a kind of failure: a mutation gets its one
attempt whatever `retry_on:` says, so a `ServerError` is not retried either —
not a 500, not a 429 that named a `Retry-After`. `retry_mutations: true` puts
the mutation back on the same budget as a query, for every one of them.

**Idempotency is the server's.** GraphWeaver never reads an `idempotencyKey`
input: it is an argument like any other, and nothing in the client
deduplicates on it. So before turning `retry_mutations: true` on for a
checkout, the *server* has to dedupe on that key. And either way a failed
response does not mean nothing happened — the request that timed out was
still delivered, so the order may exist behind the error your controller
rendered. Reconcile; don't assume.

**`Retry-After` wins over the backoff.** When the server names a delay
(seconds or an HTTP-date), that's the wait — the server is the only
party that knows when its window reopens. It's clamped to `max_delay:` so a
"come back in an hour" can't park a thread for an hour, and not
jittered, since it's an instruction rather than a guess.

`ServerError` carries the response `#headers`, so the rate-limit budget and
request id are in hand without monkey-patching a transport. Look one up in
whatever casing the server used — field names are case-insensitive; iterating
them yields the downcased spelling:

```ruby
rescue GraphWeaver::ServerError => e
  e.throttled?                          # 429, or 503 + Retry-After
  e.retry_after                         # seconds, or nil
  e.headers["Retry-After"]              # == e.headers["retry-after"]
  e.headers["x-ratelimit-remaining"]
end
```

What classifies as a transport failure is an extensible set — see
[errors](errors.md#extending-transporterror) (`GraphWeaver.register_transport_error`).
