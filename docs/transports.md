# Transports

An executor is anything with `execute(query, variables:)` whose result
`to_h`s into `{"data" => ..., "errors" => ...}`. Everything below is an
implementation of that one contract — as is a schema class (in-process
execution), a [FakeExecutor](testing.md), or anything you write.

A *transport* is an executor that speaks GraphQL-over-HTTP. The bundled
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

`GraphWeaver.new` builds a [`Client`](real_world.md): the best transport
with auth applied (exposed as `client.executor`), the schema introspected
lazily, and `parse`/`execute` bound to both.

- `auth:` — a token; "Bearer" is assumed unless the string carries its own
  scheme (`"Basic dXNlcjpwYXNz..."`)
- `headers:` — anything else (API keys, custom headers)
- `retries:` — off by default; `true` for a `RetryExecutor` with defaults,
  or a Hash of its options
- `cache:` / `ttl:` — schema introspection caching (see
  [real world](real_world.md)); url clients only — a schema source never
  introspects, so passing them raises
- a block customizes the Faraday connection (Faraday only — raises without it)

To wire generated modules that don't bake a transport, make it the app's
default client: `GraphWeaver.client = github`. (`GraphWeaver.executor=`
is the low-level knob underneath — assign a bare executor, e.g. a test
fake, and it wins over the default client.)

**Transport pick**: `Transport::Faraday` when the app already loads
faraday (its middleware/proxy/timeout ecosystem comes along), the
zero-dependency `Transport::HTTP` otherwise. Detection is `defined?(Faraday)` —
deliberately *not* a require: faraday rides along transitively in most
bundles (stripe, octokit, ...), and try-requiring would silently switch
transports on apps that never chose it. With faraday under
`require: false`, load it before building the client.

## Building blocks

The client is convenience, not the only door — construct and assign
yourself for full control:

```ruby
# zero-dependency Net::HTTP — persistent (keep-alive) connection,
# mutex-serialized; timeouts raise retriable TransportError
GraphWeaver::Transport::HTTP.new(
  url,
  headers: { ... },
  open_timeout: 10, read_timeout: 30,  # seconds (the defaults)
  keep_alive_timeout: 2,               # idle window before reconnecting
)

# Faraday: a url (+ optional middleware block), or a ready connection
GraphWeaver::Transport::Faraday.new(url) do |conn|
  conn.request :authorization, "Bearer", -> { Tokens.fetch }  # dynamic tokens
  conn.response :logger
end
GraphWeaver::Transport::Faraday.new(MyApp.faraday_connection)

# One Faraday::Connection is reused for the transport's lifetime, but
# socket keep-alive depends on the ADAPTER: Faraday's default net_http
# adapter opens a fresh connection per request. For persistent sockets
# (and real pooling), pick a persistent adapter:
GraphWeaver::Transport::Faraday.new(url) do |conn|
  conn.adapter :net_http_persistent   # gem "net-http-persistent"
end

GraphWeaver.executor = ...   # the global default
```

## Executor resolution

The canonical order — how a generated module finds its transport:

1. per call: `execute(..., executor: something)`
2. per module: `MyQuery.executor = something`
3. baked constant: `Codegen.generate(..., executor: MyApi::Executor)`
4. global override: `GraphWeaver.executor=` (fakes win over the client)
5. the default client: `GraphWeaver.client`

Nothing set anywhere raises with a message saying which knobs exist.

## Retries

`RetryExecutor` wraps any executor:

```ruby
GraphWeaver::RetryExecutor.new(
  inner_executor,
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
`ServerError` only on 5xx — a 4xx is a bug in the request, retrying won't
fix it. `retry_codes:` re-inspects response envelopes so GraphQL-level
throttling can retry too (off by default — pass the codes your API uses).
Exhausting `tries:` re-raises the last error (or returns the last
code-matched response).

Or via the client: `GraphWeaver.new(url, retries: { tries: 5, retry_codes: ["THROTTLED"] })`.

What classifies as a transport failure is an extensible set — see
[errors](errors.md#extending-transporterror) (`GraphWeaver.register_transport_error`).
