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
and `Transport::Faraday` (opt-in) — subclass `GraphWeaver::Transport`,
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
- `retries:` — off by default; `true` for a `Retry` with defaults,
  or a Hash of its options
- `open_timeout:` / `read_timeout:` — seconds, defaulting to 10 and 30 on
  either transport
- `cache:` / `ttl:` — schema introspection caching (see
  [real world](real_world.md)); url clients only — a schema source never
  introspects, so passing them raises
- a block customizes the Faraday connection (Faraday only — raises without it)

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
ones it leaves unset are filled in.

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

`pool_size:` defaults to `RAILS_MAX_THREADS` (else 5) — the same variable
Rails sizes its own connection pool from, because it is the same question:
how many requests this process can have in flight at once. Lower it for a
server that counts connections.

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
3. baked constant: `Codegen.generate(..., client: MyApi::CLIENT)`
4. the app default: `GraphWeaver.client=`

Nothing set anywhere raises, naming the two you'd usually reach for:
`no client configured — set GraphWeaver.client= or pass a client`.

## Retries

`Retry` wraps any client/transport:

```ruby
GraphWeaver::Retry.new(
  inner_transport,
  tries: 5,                        # total attempts, first included
  backoff: :exponential,           # or :linear, or ->(attempt) { seconds }
  base: 0.5, max: 30,              # seconds; delays clamp at max:
  jitter: true,                    # randomize each delay by 50-100%
  on: [GraphWeaver::TransportError, GraphWeaver::ServerError],
  retry_if: ->(error) { ... },     # fine-grain within on:
  retry_codes: ["THROTTLED"],      # also retry GraphQL errors by code
)
```

Defaults: transport failures always retry (the request never arrived);
`ServerError` on 5xx plus **408 and 429** — the rest of 4xx is a bug in
the request, retrying won't fix it. `retry_codes:` re-inspects response
envelopes so GraphQL-level throttling can retry too (off by default —
pass the codes your API uses). Exhausting `tries:` re-raises the last
error (or returns the last code-matched response).

**`Retry-After` wins over the backoff.** When the server names a delay
(seconds or an HTTP-date), that's the wait — the server is the only
party that knows when its window reopens. It's clamped to `max:` so a
"come back in an hour" can't park a thread for an hour, and not
jittered, since it's an instruction rather than a guess.

`ServerError` carries the response `#headers` (names downcased), so the
rate-limit budget and request id are in hand without monkey-patching a
transport:

```ruby
rescue GraphWeaver::ServerError => e
  e.throttled?                          # 429, or 503 + Retry-After
  e.retry_after                         # seconds, or nil
  e.headers["x-ratelimit-remaining"]
end
```

Or via the client: `GraphWeaver.new(url, retries: { tries: 5, retry_codes: ["THROTTLED"] })`.

What classifies as a transport failure is an extensible set — see
[errors](errors.md#extending-transporterror) (`GraphWeaver.register_transport_error`).
