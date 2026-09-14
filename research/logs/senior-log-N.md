# Senior N — the security reviewer (graph_weaver 0.7.0, published gem)

15:33 — start. Read brief-senior-N.md + brief-round5-common.md + followups-post-070.md.
       Read senior-log-B/E/K (the three that touched redaction) so I don't re-report:
       E owns "filter_parameters only covers messages the library composes;
       GraphQLError#message passes through" and the Rails-default-:email
       over-redaction. K owns header propagation via proc headers. Nothing prior
       audits the surface as one thing.
15:35 — Supply chain. Downloaded https://rubygems.org/downloads/graph_weaver-0.7.0.gem
       directly; sha256 cae9051988eebc88a039d0f15beefb90e92034f3f8d6a46ce3e1bf2b4a1551bb
       == the sha RubyGems records for 0.7.0. `gem unpack`: 78 files, no spec/,
       no examples/, no .env, no fixtures, no dumps. gemspec `files` is an
       explicit git-ls-files exclusion list (spec, sorbet, bin, examples,
       CLAUDE/PLAN/REVIEW/NOTES/DECISIONS.md, Makefile, design). Regex sweep for
       embedded credentials across the package: zero hits. 2 runtime deps
       (graphql >= 2.6.7, sorbet-runtime); the whole install closure is 7 gems.
       No executables, no extensions, no cert_chain (unsigned — normal), metadata
       has rubygems_mfa_required=true. Only bloat: CHANGELOG.md is 259 KB, ~16%
       of the package.
15:36 — Built two harnesses, both on the PUBLISHED gem (Gemfile `gem "graph_weaver",
       "0.7.0"`, never path:): probe/ (bare bundle) and rails/secapp (real
       `rails new --minimal`, Rails 8.1.3.1, real railtie, real
       config/initializers/filter_parameter_logging.rb).
15:38 — probe/p1_transport.rb. file://, ftp://, gopher://, javascript: all refused
       ("expected an http(s) url, got ..."). Transport#inspect/#to_s scrub
       userinfo AND ?access_token. Client#inspect and Retry#inspect are default
       Ruby inspect but the only secret-bearing ivar (@headers) lives inside the
       transport, which has its own inspect — both clean. CRLF in a proc header
       is refused by net/http itself (ArgumentError "header X-Tenant has field
       value ..., this cannot include CR/LF"). ONE LEAK: transport/http.rb:72
       raises "TLS options need an https url — got #{url}" with the RAW url.
15:41 — probe/p3_echo.rb then rails/secapp/drive.rb. THE FINDING. A 500 whose body
       echoes the request (Rails dev page, many proxies) puts the whole request
       — query, variables incl. password, and the Authorization header we sent —
       into ServerError#message, which Error#initialize writes to the logger at
       WARN, and which ServerError#to_h republishes as "message". The url beside
       it IS scrubbed (?access_token=[FILTERED]), which is what makes this a gap
       in the audit rather than an absence of one.
15:43 — drive2.rb: :fake clean, Failure clean, APM payload clean, debug variables
       line clean. Cassette holds password+email verbatim on disk (documented —
       variables are the replay key) and CREDENTIAL_SHAPES correctly warns on a
       JWT/Bearer value. filter_parameters=[] : url query-parameter redaction
       turns off with it (userinfo redaction does not).
15:45 — probe/p5_names2.rb. Codegen name handling is solid: schema types named
       Object/Kernel/Struct/Data generate classes A..E (response key, not type
       name); fields named class/send/freeze become class_/send_/freeze_; a NUL
       byte is refused by GraphQL::ParseError in SDL and by
       QueryValidationError in a query alias; a schema argument default value
       does NOT land in generated source. `cast:` Procs do splice Ruby source
       into generated files, but the expression they receive is a variable name
       the emitter built, never a schema name or a server value.
15:46 — probe/p6_endpoint.rb. Testing::Endpoint#with_context assigns
       @client.context per request. 8 concurrent requests: 7 of 8 served another
       request's identity. The method's own comment says "one request's identity
       must not leak into the next."
15:47 — probe/p7_ssrf.rb: 302 is refused, not followed, and the Location is
       reported in the hint — a real SSRF control. No host allowlist (correct:
       the app owns the url). p8_loginject.rb: a server-controlled
       extensions.code containing a newline forges a complete second INFO line
       in the Rails log through LogSubscriber.

## Findings (ranked)

### F1 — a non-2xx response body is spliced into ServerError#message, which is logged at WARN (HIGH)
`transport.rb:157` passes the whole body to `ServerError.new(body:)`; `errors.rb:136`
builds `"HTTP #{status}: #{body.to_s[0, 500]}"`; `errors.rb:28` (`Error#initialize`)
writes every raised error to the logger at **warn**. No Redact, no cap by
`VALUE_LIMIT`, 500 characters of whatever the server sent. `to_h` republishes
it under `"message"` — the same `to_h` whose own comment says "the raw headers
stay off the machine side — Set-Cookie and friends don't belong in a log line".

Repro: `rails/secapp/drive.rb` (WEBrick 500 that echoes the request body and the
Authorization header, the Rails-dev-error-page shape). The warn line, verbatim:

    W, [2026-09-13T15:42:59.640645 #98312]  WARN -- graph_weaver: GraphWeaver::ServerError: HTTP 500: <h1>500</h1><pre>{"query":"mutation Login($credentials: CredentialsInput!) {\n  login(credentials: $credentials) { id token note }\n}\n","variables":{"credentials":{"email":"victim@example.com","otp":123456,"password":"hunter2-PASSWORD-LEAK"}},"operationName":"Login"}
    Authorization: Bearer tok_AUTHHEADER_LEAK</pre> — POST http://127.0.0.1:50471/graphql?access_token=[FILTERED]

Note the url in the same sentence IS scrubbed. Three documented claims fail on
this one line:
- docs/logging.md:28 — "Auth headers never log at any level."
- logging.rb:22 — "Queries, variables, and responses appear at debug ONLY."
- docs/logging.md:26 — "queries, variables, and response sizes appear at debug only".

Fix: the body snippet is server text the library didn't author — exactly what
`Redact.cap` exists for. Run it through `Redact.cap` (VALUE_LIMIT, not 500),
and through `Log.filter_variables` when it parses as JSON; or keep the body on
`#body` and leave `#message` as `"HTTP 500 — POST <url>"` plus the hint, the way
`#to_h` already keeps headers off. Whatever the choice, docs/logging.md's
"reaches what GraphWeaver composes, and nothing else" needs a third named
channel beside `InputError` and `GraphQLError`.

### F2 — Testing::Endpoint serves one request's identity to another under concurrency (MEDIUM)
`testing/endpoint.rb:75` `with_context` does `@client.context = context.call(headers)`
on shared state and restores it in an `ensure`. Eight concurrent requests
through one Endpoint, each with its own Authorization header: **7 of 8 were
served another request's identity** (`probe/p6_endpoint.rb`).

    user-0 -> "user-0"
    user-1 -> "user-0" <-- CROSSOVER
    ... (7 of 8)

The method's own comment: "one request's identity must not leak into the next."
This is the seam the class exists for — its docstring calls `context:` "the
identity-propagation seam, the one thing an in-process client can't test" —
and both documented deployments (a Puma in a thread, `graphql: :wire` under a
parallel spec run) are concurrent. A spec asserting that user A cannot read
user B's data passes for the wrong reason.

Fix: don't mutate shared state — resolve the context and pass it to `execute`
where the client accepts one, or hold it in a `Thread.current`/`Fiber` slot the
client reads, or (cheapest) wrap the dispatch in a Mutex and accept the
serialization for a test harness.

### F3 — a server-controlled `extensions.code` forges log lines at INFO (LOW-MEDIUM)
`log_subscriber.rb:62` interpolates `payload[:code]` — set in `logging.rb:190`
from `GraphQLError.from_h(e).code`, i.e. a string the upstream server chose —
into the one line the gem writes at info in production. A newline in it produces
a complete, well-formed second line (`probe/p8_loginject.rb`):

    I, [2026-09-13T15:47:11.421672 #5518]  INFO -- graph_weaver: GraphWeaver PersonQuery (1.6ms) errors [OK
    I, [2026-01-01T00:00:00]  INFO -- graph_weaver: GraphWeaver AdminQuery (1.0ms) ok]

Only the trailing `]` gives it away. The same string also becomes an APM tag.
Exploitable by any subgraph or upstream that puts user-influenced text in
`extensions.code`. Fix: render `code` (and `error`) with `.inspect`, or strip
control characters where the payload is built.

### F4 — `filter_parameters = []` silently turns off url credential redaction too (LOW-MEDIUM)
`Internal::Endpoint.scrub_query` asks `Redact.filtered?`, which asks
`GraphWeaver.filter_parameters`. Empty the list — documented as "`[]` turns
filtering off", in a section titled **Filtered variables** — and a query-string
credential stops being scrubbed everywhere `safe_url` is said: every debug line,
every TransportError/ServerError message, the `url` key in the APM payload, and
`Transport#inspect` (`drive2.rb`, NOFILTER arm):

    #<GraphWeaver::Transport::HTTP url="http://[FILTERED]@127.0.0.1:1/graphql?access_token=qs_ACCESSTOKEN_LEAK">

Userinfo stays redacted unconditionally, which is the inconsistency: one knob
means two things, and only one of them is what the docs say it means. Fix:
either scrub query credentials against `DEFAULT_FILTER_PARAMETERS` regardless of
what the caller set (a url credential is a credential whatever your variable
policy is — the same argument `CREDENTIAL_SHAPES` already makes for cassettes),
or say in docs/logging.md that `[]` reaches urls too.

### F5 — one raw-url message survives the url-redaction pass (LOW)
`transport/http.rb:72`: `raise ArgumentError, "TLS options need an https url — got #{url}"`.
Every other url-bearing message in the gem goes through `Endpoint.safe`; this
one doesn't, and it's raised from `Transport::HTTP#initialize`, i.e. at boot,
from an initializer, into whatever collects boot errors:

    ArgumentError: TLS options need an https url — got http://alice:s3cr3t@example.com/graphql
    ArgumentError: TLS options need an https url — got http://example.com/graphql?access_token=TOKENLEAK1

(The neighbouring scheme check two lines up uses `url.inspect`, also raw, but it
fires on a url that isn't a url.) Fix: `Endpoint.safe(url)` — it's already
required in that file's parent.

## Clean (drove it, found nothing)
- Supply chain: package contents, sha256 vs RubyGems, gemspec `files` glob,
  2 runtime deps / 7-gem closure, no embedded credentials.
- `Transport#inspect` / `#to_s`, `Client#inspect`, `Retry#inspect`,
  `Testing::Endpoint#inspect`, `InProcess#inspect`.
- Debug variables line, `InputError#message` / `#value` / `#to_h`,
  the `execute.graph_weaver` payload, the LogSubscriber info line's own fields.
- Codegen against hostile names: Object/Kernel/Struct/Data/Comparable type
  names, class/send/freeze field names, NUL bytes in SDL and in a query alias,
  schema argument default values.
- Scheme refusal (file/ftp/gopher/javascript), redirects not followed,
  CRLF header injection refused by net/http.
- Cassette credential-shape warning fires on a JWT/Bearer value.
