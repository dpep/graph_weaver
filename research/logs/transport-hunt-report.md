# Transport hunt — report

Baseline: main `4fd16d2` (worktree `worktree-agent-acbc9c86f7e87c78a`, fast-forwarded
to it per brief-common). Suite green at baseline: 1777 examples, 0 failures.

Method: a raw `TCPServer` harness (`/tmp/claude/graph_weaver/transport-probe.rb`) that
writes exact bytes — no WebMock anywhere in the hunt — driven against both bundled
transports. Probe scripts alongside it:
`probe-bodies.rb`, `probe-faraday.rb`, `probe-timing.rb`, `probe-proxy.rb`,
`probe-stale.rb`, `probe-retry.rb`.

Headline: the transport layer is in far better shape than the brief's framing
assumed. 30-odd adversarial cases were driven; **26 already answered correctly and
identically on both transports**. Four real defects came out, all in how a failure
*reads* rather than in what it does — plus one that could crash the retry loop.

---

## Findings

### 1. No transport failure names the endpoint it failed against — MEDIUM

`TransportError` and `ServerError` carry no url, in the message or in `to_h`.
An app talking to two graphs (the library explicitly supports this — `GraphWeaver.graphs`)
gets:

```
GraphWeaver::ServerError: HTTP 502: <html>oops</html>
GraphWeaver::TransportError: Net::OpenTimeout: Failed to open TCP connection to 10.255.255.1:81
```

The second happens to name a host because net/http put it in its own message; the
first names nothing at all, and neither `to_h` has a url key. A page at 3am starts
with "which endpoint".

Repro (`probe-bodies.rb`):

```ruby
srv = RawServer.new { |s, _r, _b| s.write(http_response(500, "<html>oops</html>")); false }
GraphWeaver::Transport::HTTP.new(srv.url).execute("query Q { x }")
# => GraphWeaver::ServerError: HTTP 500: <html>oops</html>
#    to_h: {"error"=>"...ServerError", "message"=>"HTTP 500: <html>oops</html>", "status"=>500}
```

**FIXED** — both errors take an optional `url:`, expose `#url`, name it in the
message and carry it in `to_h`. Which drags in:

### 2. A url carrying a credential is printed verbatim everywhere — MEDIUM

Before any change, the raw url reaches: the `:info` boot line in
`Client#build_transport` and `Transport::Faraday#initialize`, the `:debug`
`POST <url>` line per request, `Transport#inspect`/`#to_s`, and `payload[:url]` on
every `execute.graph_weaver` notification — i.e. the APM. So
`https://svc:hunter2@api.example.com/graphql?access_token=…` is in the log file and
in a third-party trace store.

`Transport#inspect`'s own comment says "never leak auth headers through logs/
exceptions — a transport inspects as its class + endpoint, nothing more", which is
exactly right about headers and silent about the endpoint being a credential too.

Repro:

```ruby
t = GraphWeaver::Transport::HTTP.new("https://svc:hunter2@example.com/graphql?access_token=abc")
t.inspect
# => "#<GraphWeaver::Transport::HTTP url=\"https://svc:hunter2@example.com/graphql?access_token=abc\">"
```

**FIXED** — one helper, `Internal::Endpoint.safe`, folds userinfo to `[FILTERED]`
and scrubs any query parameter `GraphWeaver.filter_parameters` already filters
(`token`, `secret`, `password`, `authorization` by default, substring-matched, and a
Rails app's own `ParameterFilter` if it set one). Every site above uses it, including
the url the new errors from finding 1 carry. `Transport#url` stays the real
endpoint — requests go there, `:wire` stubs on it.

Note on the brief: it names `lib/graph_weaver/internal/redact.rb` as an existing
contract. There is no such file — `Internal::Redact` (value scrubbing) lives inside
`logging.rb`, and it had no url arm. Rather than split that module across two files,
the new helper is its own internal module beside `Internal::Headers`, which is the
existing precedent for a small transport-seam type.

**LEFT, not mine:** `SchemaLoader.introspect` records `transport.url` as provenance
into the cached schema dump (`schema_loader.rb:722, 752`), a file people commit. A
url with an embedded token therefore lands in git. That file belongs to another
lane; the fix is one call to `Internal::Endpoint.safe` at the provenance write, and
the helper is now there for it.

### 3. An empty response body produces a message that says nothing — LOW

A 200 with no body, and a 204 (a proxy or a misrouted path answering a POST), both
give:

```
GraphWeaver::ServerError: HTTP 204: non-GraphQL response:
```

Trailing "`: `" with nothing after it — the reader can't tell whether the body was
empty or the message was truncated.

Repro (`probe-bodies.rb`): serve `"HTTP/1.1 204 No Content\r\n\r\n"`.

**FIXED** — an empty body says so: `HTTP 204: empty response body — POST <url>`.

### 4. A BOM-prefixed JSON body is rejected as "non-GraphQL" — LOW

```ruby
s.write(http_response(200, "\xEF\xBB\xBF" + '{"data":{"x":1}}'))
# => ServerError: HTTP 200: non-GraphQL response: ﻿{"data":{"x":1}}
```

Both transports. Ruby's JSON parser does not skip a UTF-8 BOM; RFC 8259 §8.1 says a
parser MAY ignore one, and .NET/IIS-fronted endpoints emit them. The failure is
maximally confusing because the quoted body looks like perfectly good GraphQL — the
three bytes that broke it are invisible.

**FIXED** — a leading UTF-8 BOM is stripped before parsing.

### 5. A negative retry delay reaches `Kernel#sleep` and kills the retry loop — LOW

```ruby
GraphWeaver::Retry.new(client, retries: 3, base_delay: -5).execute(q)
# => ArgumentError: time interval must not be negative      (from sleep)
```

Same from a custom `backoff:` proc that returns a negative. The original
`ServerError`/`TransportError` is lost entirely, replaced by an `ArgumentError` out
of `Kernel#sleep` — so a typo in one option reports as a bug somewhere else.

Repro (`probe-retry.rb`): `base_delay: -5` produced the delay sequence
`[-5.0, -10.0, -20.0]`.

**FIXED** — `base_delay:`/`max_delay:` are refused at construction if negative (where
the typo is), and the computed delay clamps at 0 so no `backoff:` proc can crash the
loop.

---

## Driven and correct — no change needed

Each of these is a case the brief asked about; each already answers correctly, on
**both** transports unless noted. The ones worth locking down got specs (below).

| Case | Answer |
|---|---|
| malformed JSON, JSON array / string / null, `text/html` 200 | `ServerError`, body quoted, capped at 500 chars |
| non-UTF-8 bytes in a string value | parses; bytes pass through as the server sent them |
| gzip `Content-Encoding` | asked for (`Accept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3`, net/http's own) and decoded, both transports |
| deflate `Content-Encoding` | decoded |
| chunked transfer | decoded |
| 5 MB body | fine |
| 100-continue | fine |
| 4xx/5xx with an HTML body | `ServerError`, status preserved |
| 401 + `WWW-Authenticate` | `ServerError` + the auth hint |
| 3xx | `ServerError`, **not followed**, hint names the `Location` — so no Authorization replay at another host |
| 429 + `Retry-After` seconds *and* HTTP-date | `retry_after` parses both; `Retry` prefers it to its own backoff, clamps to `max_delay:`, doesn't jitter it |
| open timeout vs read timeout | both `TransportError`, `Net::OpenTimeout`/`Net::ReadTimeout` as `#cause` |
| headers sent, then the server stalls | read timeout → `TransportError` |
| garbage status line | `TransportError` on both (`Net::HTTPBadResponse` / `Faraday::ConnectionFailed`) |
| body that isn't the gzip it claims | `TransportError` on both (`Zlib::DataError`) |
| **stale keep-alive socket, mutation** | net/http's pre-flight `eof?` check reconnects *before* writing: the server reads the charge exactly once. When the close races the write instead, it raises `TransportError` rather than replaying — 1 charge read, both ways |
| `http_proxy` / `HTTP_PROXY` | honoured by **both** transports; `no_proxy` switches it back off |
| `Accept` / `Content-Type` / `User-Agent` | graphql-over-http `Accept`, `graph_weaver/<version>` UA, caller overrides win |
| `retry_on` × `retry_codes` × `retry_if`, `retry_mutations` default, jitter 0/1, `max_delay` clamp | all correct (`probe-retry.rb`) |
| `Failure.timeout` vs the real transport | same class, same `#cause` (`Net::ReadTimeout`), same `to_h` keys |

Faraday parity: every case above that has an answer on `Transport::HTTP` gave the
**identical** answer on `Transport::Faraday` — same error class, same message text,
same `to_h`. No documented differences were needed.

---

## Left, with the reason

- **A header proc that raises** propagates its own exception (`RuntimeError: token
  service down`) without naming the header it was resolving. Wrapping it would
  either swallow the class a caller wants to rescue or add a second error type for
  one line of context. Not worth it.
- **A header value containing CR/LF** is refused by net/http with
  `ArgumentError: header X-Tenant has field value "a\r\nX-Evil: 1", this cannot
  include CR/LF` — on both transports, and it names the header. Good enough; note
  that net/http quotes the *value*, so a CRLF in an `Authorization` value would print
  the token. That is net/http's message, not ours, and only reachable by injecting a
  newline into your own token.
- **Non-UTF-8 bytes in a response string** pass through to the generated struct. Any
  fix here is a guess about what the server meant; the server sent those bytes.
- **`ServerError#body` holds the whole body**, uncapped (the *message* caps at 500).
  Deliberate — you may want the proxy's error page — and an exception is short-lived.
- **Fork-after-connect** (Puma preload) — already validated, no new angle found.

---

## Shipped

Three commits on `worktree-agent-acbc9c86f7e87c78a`, off main `4fd16d2`:

| sha | what |
|---|---|
| `902d317` | Name the endpoint every transport failure happened at (findings 1 + 2) |
| `0e5b5a9` | Read a body behind a BOM, and say when there was no body at all (findings 3 + 4), plus the wire specs |
| `520555c` | Stop a retry delay from being the thing that fails (finding 5) |

### Messages, verbatim

Before / after, on the same bytes:

```
HTTP 500: <html>oops</html>
HTTP 500: <html>oops</html> — POST http://127.0.0.1:51553/graphql

HTTP 200: non-GraphQL response:
HTTP 200: empty response body — POST http://127.0.0.1:51553/graphql

HTTP 204: non-GraphQL response:
HTTP 204: empty response body — POST http://127.0.0.1:51556/graphql

HTTP 200: non-GraphQL response: ﻿{"data":{"x":1}}      (a BOM)
{"data"=>{"x"=>1}}

Net::OpenTimeout: Failed to open TCP connection to 10.255.255.1:81 (execution expired)
Net::OpenTimeout: Failed to open TCP connection to 10.255.255.1:81 (execution expired) — POST http://10.255.255.1:81/graphql
```

New:

```
base_delay: must be >= 0, got -5
max_delay: must be >= 0, got -1
```

`#to_h`, the machine side:

```ruby
{"error" => "GraphWeaver::ServerError",
 "message" => "HTTP 204: empty response body — POST http://127.0.0.1:51556/graphql",
 "status" => 204, "url" => "http://127.0.0.1:51556/graphql"}
```

Redaction:

```ruby
GraphWeaver::Transport::HTTP.new("https://svc:hunter2@api.example.com/graphql?access_token=abc&page=2").inspect
# => #<GraphWeaver::Transport::HTTP url="https://[FILTERED]@api.example.com/graphql?access_token=[FILTERED]&page=2">
```

### Specs added

- `spec/transport_endpoint_spec.rb` (12) — the redaction rules, and the url on
  the error, in `#inspect`, in the APM payload and in the log.
- `spec/transport_wire_spec.rb` (13) — bodies, keep-alive, statuses, proxies;
  every case asked of both bundled transports.
- `spec/retry_spec.rb` (+2) — the two delay refusals.
- `spec/support/raw_http_server.rb` — new shared context: exact bytes on the
  wire, one request per connection.

Every behaviour change was watched failing first — the BOM and empty-body specs
against a transport with those two lines removed, the delay specs before the
guard.

### Gate — each its own run, all green on the final tree

```
bundle exec rspec                                 1804 examples, 0 failures
bundle exec rspec --order rand:1                  1804 examples, 0 failures
bundle exec rspec --order rand:4242               1804 examples, 0 failures
bundle exec srb tc                                No errors! Great job.
bundle exec ruby bin/generate                     already up to date
bundle exec ruby bin/federation-diff              matches the schemas here (3 of 3 subgraphs)
INTEGRATION=1 bundle exec rspec spec/integration  16 examples, 0 failures
```

`git status` clean. Public surface relocked at 489 names via
`bin/public-surface --update`: `ServerError#url`, `TransportError#url`,
`Transport#safe_url`.

### Docs

- `docs/errors.md` — `#url` on both transport arms of the error table, and a
  paragraph on which url they name.
- `docs/transports.md` — compression and proxies (both work, on both transports,
  and neither was documented), and `#url` vs `#safe_url`.
- `docs/logging.md` — `:url` is the one payload field that is scrubbed, and why.
- `CHANGELOG.md` — one `<!-- lane: transport2 -->` block under `## Unreleased`.

## DX observations

- `docs/transports.md` said nothing about proxies or compression. Both work, on both
  transports; both are now documented, because "does it honour `http_proxy`" is a
  question you should not have to answer with a packet capture.
- `spec/support/http_server.rb`'s WEBrick context can't express "write these exact
  bytes". The new `spec/support/raw_http_server.rb` can, and is what makes the
  BOM/chunked/stale-socket/proxy specs possible without WebMock.
