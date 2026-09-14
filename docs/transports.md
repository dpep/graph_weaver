# Transports

Where queries actually go: what fills the client slot, how to build and tune the
bundled HTTP transports, and how a generated module decides which one to use.
Read it when the default one-liner isn't enough — custom headers, mTLS, Faraday
middleware, retries, or connection pooling under load.

## A client in one line

Most apps need this:

```ruby
github = GraphWeaver.new("https://api.example.com/graphql", auth: ENV["API_TOKEN"])
```

`GraphWeaver.new` builds a [`Client`](real_world.md): a transport with auth
applied (exposed as `client.transport`), the schema introspected lazily, and
`parse`/`run` bound to both.

- `auth:` — a token, or something answering `#call` that returns one per
  request; "Bearer" is assumed unless it carries its own scheme
  (`"Basic dXNlcjpwYXNz..."`)
- `transport:` — `:http` (the default) or `:faraday`
- `headers:` — anything else (API keys, custom headers)
- `retries:` — off by default; every other [`Retry`](#retries) option sits beside
  it (`backoff:`, `retry_codes:`, ...)
- `open_timeout:` / `read_timeout:` — seconds, defaulting to 10 and 30 on either
  transport
- `pool_size:` — how many sockets the bundled HTTP transport keeps open,
  defaulting to `RAILS_MAX_THREADS` (else 5). Refused with `transport: :faraday`,
  whose adapter owns its own connections — a ceiling here would be a number
  nothing reads
- `cache:` / `ttl:` — schema introspection caching (see
  [real world](real_world.md)); url clients only — a schema source never
  introspects, so passing them raises
- a block customizes the Faraday connection (Faraday only — raises without it)

They combine, so the whole thing is still one call —
`GraphWeaver.new(url, transport: :faraday, retries: 2) { |conn| conn.response :logger }`.
To wire generated modules that don't bake a client, make it the app's default:
`GraphWeaver.client = github`.

## What fills the client slot

A *client* is anything with `execute(query, variables:, operation_name:)` whose
result `to_h`s into `{"data" => ..., "errors" => ...}` — from a full
`GraphWeaver::Client` down to a schema class
([in-process execution](getting_started.md#your-apps-own-schema-in-process) —
typed access to your own app's API, no socket), a [FakeClient](testing.md), or
anything you write. Every slot that takes a client accepts any of them, `Retry`
and a cassette recorder included.

**Anything holding a schema parses against it** — `client.parse(query)`, and the
same on `InProcess`, `FakeClient` and `Testing::Router`, giving a typed module
bound to that schema and running on that object. It sits on top of the contract
rather than in it, so `Retry`, which holds no schema, has no `parse`.
`load_queries!` is the same rule over a directory.

A *transport* is the network end of that contract — GraphQL-over-HTTP. Both
bundled ones subclass `GraphWeaver::Transport`, which owns the shared flow: encode
the request, reclassify network failures as `TransportError`, raise `ServerError`
on non-2xx, parse the body. A subclass only implements
`post(body) => [status, body]` — the whole recipe for bringing your own HTTP
client. Return the response headers as a downcased third element and
`ServerError#headers` carries them; two elements is still a complete answer.

## The two transports

`Transport::HTTP` (net/http, zero dependencies, loaded by default) is the
default. `Transport::Faraday` is opt-in — naming it loads faraday, so an app that
doesn't need it needs no faraday — and is the one to reach for when you already
have a `Faraday::Connection`, or want its middleware.

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
# Timeouts default to the same 10/30 (Faraday's own would be 60/60).
GraphWeaver::Transport::Faraday.new(url, open_timeout: 10, read_timeout: 30)
GraphWeaver::Transport::Faraday.new(url) do |conn|
  conn.request :authorization, "Bearer", -> { Tokens.fetch }  # dynamic tokens
  conn.response :logger
end
GraphWeaver::Transport::Faraday.new(MyApp.faraday_connection)

# In-process: a live graphql-ruby schema class, no socket. The class alone
# works in any client slot; the wrapper adds a request context, the debug
# logging the network transports emit, and errors branded under
# GraphWeaver::Error (a resolver raise becomes a ServerError, status 500).
GraphWeaver::InProcess.new(MySchema, context: { current_user: user })
GraphWeaver.new(MySchema, context: { current_user: user })   # same, via a client

GraphWeaver.client = ...   # the app default (a Client or any of the above)
```

**Faraday's sockets need an adapter to stay alive.** Its default `net_http`
adapter opens a fresh connection per request, TLS handshake and all;
`:net_http_persistent` gets it the reuse and thread-safe pooling
`Transport::HTTP` has by default. graph_weaver depends on neither and never
selects an adapter for you, and the version pairing matters — **Faraday 2.x
requires `faraday-net_http_persistent` 2.x**:

```ruby
gem "net-http-persistent"                      # the HTTP client
gem "faraday-net_http_persistent", "~> 2.0"    # the Faraday adapter for it

GraphWeaver::Transport::Faraday.new(url) { |conn| conn.adapter :net_http_persistent }
```

**Compression and proxies** need no configuration on either transport. `net/http`
— which both use underneath — asks for `gzip`/`deflate` on every request and
decodes what comes back, and it reads `http_proxy` / `HTTPS_PROXY` and `no_proxy`
from the environment. A proxy is never used for a loopback address, which is
Ruby's rule, not ours.

## Headers

Both transports send `Content-Type: application/json`, `Accept:
application/graphql-response+json, application/json;q=0.9` (the media type
[GraphQL-over-HTTP](https://graphql.github.io/graphql-over-http/draft/) requires
a conforming client to accept, with the legacy type as fallback), and
`User-Agent: graph_weaver/<version>`. Anything you pass in `headers:` wins over
these. A prebuilt `Faraday::Connection` owns its own headers; only the ones it
leaves unset are filled in — and Faraday's stock `User-Agent: Faraday v…` counts
as unset.

**Who the graph thinks is calling.** Both also send `apollographql-client-name`
and `apollographql-client-version`, which is what an Apollo Router or GraphOS keys
client attribution on — per-client SLOs and rate limits, and "who still asks for
this deprecated field". The name is your Rails application's (`Storefront`), or
`graph_weaver` outside Rails, since Apollo means the consuming *application*; the
version is the gem's. Both are plain headers, so `headers:` overrides them, which
is how one app names its several clients apart.

**A header that expires.** A header *value* may be anything answering `#call`, on
either transport, resolved per request rather than captured when the transport
was built. A value (or a call) of `nil` sends no such header; anything else is
sent as its `to_s`, so a numeric tenant id needs no ceremony:

```ruby
GraphWeaver::Transport::HTTP.new(url, headers: {
  "Authorization" => -> { "Bearer #{Tokens.fetch}" },   # rotating token
  "X-Tenant" => -> { Current.tenant&.id },              # nil ⇒ header omitted
})
```

`auth:` is that header under a shorter name, so a rotating credential is
`GraphWeaver.new(url, auth: -> { Tokens.fetch })`. A prebuilt
`Faraday::Connection` owns its own headers, so a rotating credential there is
Faraday's middleware (`conn.request :authorization, "Bearer", -> { ... }`).

## The request body

`{"query": ..., "variables": ...}`, plus `"operationName"` when the operation has
a name — the field Apollo Studio, Hasura and most APMs key traces, rate limits
and slow-query reports on. Generated modules always send one: an anonymous
document is named after its module at generation, so the name is declared in the
query too. A raw query string handed straight to a transport falls back to the
name in the document, and a genuinely anonymous one sends no `operationName` key
at all.

**Variables have to be JSON.** Every variable value, at any depth, must be
something JSON carries — a string, a number, a boolean, null, a list, an object —
or a value with an honest string form, which is how a `Date`, a `Time`, a
`BigDecimal` or a `Symbol` travels. A `File`, an `IO`, a `Pathname` or a plain
object is refused before the body is built, naming the variable: JSON would
otherwise render it as its `#to_s`, so `$file` reaches the server as
`"#<File:0x00007f…>"` and is stored as if it meant something. The refusal is the
*call's*, not the transport's, so `graphql: :in_process` and `graphql: :fake`
refuse the same value with the same sentence.

graph_weaver does not implement the [GraphQL multipart request
spec](https://github.com/jaydenseric/graphql-multipart-request-spec), so an
`Upload!` argument needs your own transport or a separate upload endpoint;
registering a scalar can't help, since multipart restructures the whole request.

**No persisted-query id goes with it**, so a gateway safelist configured with
`require_id` refuses every request this client makes; automatic persisted queries
(APQ) are an optimization, so those just never kick in. `post` is the seam if you
need one — it sees the encoded body and can put the hash beside it.

`#url` on a transport is the real endpoint; `#safe_url` — userinfo and secret
query parameters folded to `[FILTERED]` — is what a log line, an exception or an
APM payload gets ([errors](errors.md)).

## Client resolution

The canonical order — how a generated module finds its client (each slot takes a
`Client` or any bare transport/fake):

1. per call: `execute(client: some_client, ...)` — a kwarg like the variables, and
   a name no GraphQL variable is allowed to take
2. per module: `MyQuery.client = something`
3. a test mode's stand-in: under `graphql: :fake` / `:in_process` / `:router`,
   built from the graph this module was generated from
4. baked constant: `Codegen.generate(..., client: "MyApi::CLIENT")` — the
   constant's *name*, not the object, because generated source spells it
5. the app default: `GraphWeaver.client=`

The mode replaces what codegen baked in, not what your example said — 1 and 2
still win. Nothing set anywhere raises, naming the two you'd usually reach for:
`no client configured — set GraphWeaver.client= or pass a client`.

## Retries

A url client retries when you give it a count; the rest of the options sit beside
it:

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

`GraphWeaver::Retry.new(inner_transport, ...)` takes the same options and wraps
any client/transport directly — the client just passes them along. `retries:`
counts the attempts *after* the first, so `retries: 3` makes up to four and
`retries: 0` never retries; `retries: true` takes `Retry`'s own default of 2.
Every misspelling raises rather than quietly doing nothing.

**What retries.** Transport failures always do; a response does when its status is
5xx or **408 or 429** — the rest of 4xx is a bug in the request, and retrying
won't fix it. That is one rule for both shapes a failure arrives in: raised as a
`ServerError`, or returned in the envelope because the server sent GraphQL errors
alongside the status, which is what Apollo Router does for everything it decides
itself (rate limiting is `503` plus a `REQUEST_RATE_LIMITED` body). `retry_codes:`
adds the other signal — error codes, at any status, off by default; pass the codes
your API uses, or `GraphWeaver::GraphQLError::THROTTLE_CODES`. Exhausting the
retries re-raises the last error, or returns the last response.

**Nothing else does.** A `200` is never retried on its status, whatever it
carries: the caller already has an answer, and whether a partial one is worth
repeating is a judgment only the caller can make — a router that gives up on a
slow subgraph answers `200` with partial data and a `GATEWAY_TIMEOUT` error, and
`retry_codes: ["GATEWAY_TIMEOUT"]` is how you say yes to that one. An `InputError`
never retries either: the variables never left the process.

**A mutation gets one attempt.** A failure with no answer — a read timeout, a 502,
a reset socket — does not say whether the server applied it, and a second `charge`
is worse than a failed one. The cap is on **attempts**, not on a kind of failure,
so a `ServerError` isn't retried either, not a 500 and not a 429 that named a
`Retry-After`. `retry_mutations: true` puts mutations back on a query's budget,
for every one of them; the skipped retry says so on the logger.

**Idempotency is the server's.** GraphWeaver never reads an `idempotencyKey`
input, and nothing in the client deduplicates on one, so before turning
`retry_mutations: true` on for a checkout the *server* has to dedupe. And either
way a failed response does not mean nothing happened — the request that timed out
was still delivered, so the order may exist behind the error your controller
rendered. Reconcile; don't assume.

**`Retry-After` wins over the backoff**, however the rate limit arrived, raised or
returned: the server is the only party that knows when its window reopens. It's
clamped to `max_delay:` so a "come back in an hour" can't park a thread for an
hour, and not jittered, since it's an instruction rather than a guess.

`ServerError` carries the response `#headers`, so the rate-limit budget and
request id are in hand without monkey-patching a transport. Look one up in
whatever casing the server used — field names are case-insensitive; iterating them
yields the downcased spelling:

```ruby
rescue GraphWeaver::ServerError => e
  e.throttled?                          # 429, or 503 + Retry-After
  e.retry_after                         # seconds, or nil
  e.headers["Retry-After"]              # == e.headers["retry-after"]
  e.headers["x-ratelimit-remaining"]
end
```

What classifies as a transport failure is an extensible set — see
[errors](errors.md#extending-transporterror)
(`GraphWeaver.register_transport_error`).

## Concurrency

One transport is normally the whole app's (`GraphWeaver.client = api`), so it has
to serve every thread. `Transport::HTTP` opens up to `pool_size:` sockets lazily
and reuses the warmest one; requests beyond that queue for a free slot rather than
opening unbounded connections. A socket that errors is closed and its slot left
empty, so the next call reconnects. Saturation is not silent: the first request
that has to queue logs a warning naming how long it waited and what to raise.

A url client introspects its schema lazily, and the first requests of a cold
process arrive together — so that fetch is done **once**, by whoever asks first,
with the rest waiting on it rather than each making its own round trip and writing
its own copy of the schema cache.

**The pool is fork-safe**, which is what a Puma or Unicorn worker under
`preload_app!` needs, and there is no `after_fork` hook to write. A socket warmed
before the fork would otherwise be inherited by every worker, and two of them
interleaving on one fd hand each other's answers back; a child notices the pid
changed and starts over, **abandoning rather than closing** the inherited sockets
(closing would take down the fd the parent is still using).

Under a fiber scheduler (`async`, Falcon) everything here works unchanged —
`SizedQueue`, `Mutex`, `net/http` and `Kernel#sleep` are all scheduler-aware, so
requests multiplex on one thread at thread-equivalent throughput. But `pool_size:`
is the same hard ceiling there, and nothing sets `RAILS_MAX_THREADS` for you.
