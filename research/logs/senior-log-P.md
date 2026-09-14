# Senior P — the concurrency reviewer

App: `/tmp/claude/graph_weaver/senior-app-P` (Rails 8.1.3.1, `path:` at the
checkout, main at `00038e5`). Instrumented origin at `script/origin.rb` — real
graphql-ruby behind a hand-rolled HTTP/1.1 keep-alive socket loop, so
*connections* are observable, not just requests.

## 16:40 — setup
Copied junior-app-15, stripped its two remote graphs, pointed one graph
(`:origin`) and a second (`:alt`) at the local instrumented server. Two graphs
so that a crossed `payload[:graph]` is *visible* rather than merely absent.
Per-request identity rides `X-Caller` (a header proc reading a thread-local);
the worker pid rides `X-Worker`. The origin echoes both back inside `data`, so
every response says who the origin thought was asking.

## 17:05 — A. Puma, 2 workers x 8 threads, preload_app!, production
`script/hammer.rb`, 400 requests at concurrency 200.

    ok 400, failures 0
    identity_crossed 0
    worker_header_crossed 0
    distinct_conns 10, conns_serving_two_workers 0
    pids {33717: 206, 33718: 194}

`script/check_events.rb` over the process-global `execute.graph_weaver`
subscriber (an NDJSON append from both workers), 400 events:

    with_identity 400, graph_label_wrong 0
    graphs {origin: 200, alt: 200}, statuses {ok: 400}
    payload keys, every event: [client, duration_ms, graph, http_status, operation, status, url]
    distinct (pid, thread) pairs: 16, duration_ms nil: 0

Nothing crossed. The fork fix (`1ce2ebd`) and the header-proc seam both hold
under a real preloaded cluster.

## 17:20 — B. Client#schema under a hung origin  (FINDING)
`script/cold_schema.rb` — a TCPServer that accepts, reads, and never answers.

    8 threads, read_timeout 2s: total 16054ms, first thread 2013ms, last 16047ms -> 8.0x
    4 threads, read_timeout 2s: total  8025ms, first thread 2011ms, last  8019ms -> 4.0x
    second wave, 4 threads:     8027ms (identical)

`@schema ||=` inside `@schema_lock` memoizes nothing on failure, so the wait is
exactly `threads x read_timeout` and does not improve on the next wave.

## 17:35 — C. Concurrent graph declaration / registration
`script/registry_race.rb`, 500 trials x 8 threads (4000 declarations, 4000
`register_scalar`): 0 duplicate graphs, 0 lost registrations. The unguarded
read-modify-write in `GraphWeaver.graph` is real but not reachable on CRuby 3.4.

## 17:50 — D. Cassette under 4 concurrent recorders  (FINDING)
Four spec files, four processes, one cassette name, 5 distinct entries each.

    run 1: 5 entries survive, ms [10,11,12,13,14]   (process 1 won)
    run 2: 5 entries survive, ms [40,41,42,43,44]   (process 4 won)
    run 3: 5 entries survive, ms [30,31,32,33,34]   (process 3 won)

15 of 20 recordings lost every time, 75%, winner nondeterministic, all four
processes green, no warning on any stream.

## 18:10 — E. Testing::Endpoint  (FINDING x2)
`script/endpoint_lock.rb`, 8 threads, 64 requests, 50ms resolver.

    no context accessor (baseline)                      469ms   crossed —
    one Endpoint, context proc (the fix)               3881ms   crossed 0/64
    one Endpoint, context HASH (nothing to protect)    3803ms   crossed —
    two Endpoints, one client, context proc            1920ms   crossed 32/64
    per-request Endpoint over one client (:wire shape)  469ms   crossed 56/64

`with_context`'s early return tests `@client.respond_to?(:context)`, and both
`InProcess` and `Router` define `attr_reader :context` + `attr_writer :context`
unconditionally — so the Monitor is entered for every one of them, and the
`next yield` for a non-callable context is INSIDE the synchronize.

`rspec.rb:177-180` builds `Endpoint.new(client)` inside the `to_rack` lambda —
per request — while `TestClients.standin` memoizes the client per example
(`test_clients.rb:120`, `@clients[graph&.name] ||=`). So each request gets its
own Monitor over one shared client.

## 18:25 — end to end through the harness  (FINDING)
`spec/wire_identity_spec.rb` — `graphql: :wire`, `graphql_in_process(LocalSchema,
context: ->(headers) { { caller: headers["X-Caller"] } })`, 8 threads:

    WIRE-IDENTITY crossed=6/8   x5 runs, identical

## 18:35 — F. Fork with a socket warm at fork
Initializer executes 3 queries during preload, then Puma forks 2 workers.
Origin log: `conn 1` carried worker `85259` (the master) only, seq 1..3.
Storm of 400 at concurrency 200 after that: 17 connections, 0 serving two
workers, 0 identity crossings. `reset_after_fork` holds under its own trigger.

## 18:40 — G. Retry under concurrent attempts
`script/retry_router_race.rb`: 8 threads through one `Retry`, each told to fail
a different number of times. 36 events, 8 final, `payload[:retries]`
[[0,0],[1,1],[2,2],[3,3],[4,4],[5,5],[6,6],[7,7]] — exact. No crossing.

`TestClients.standin` memo under 8 threads x 100 trials: 0 double-builds.

## 18:45 — H. The `[req N]` tag across fork
`script/reqid_fork.rb` — parent logs 3, then forks twice:

    [req 4 Serve] | [req 5 Serve] | [req 6 Serve]
    [req 4 Serve] | [req 5 Serve] | [req 6 Serve]

## 18:55 — I. The introspection cache file
`script/cache_write_race.rb`: 8 processes x 20 introspections into one path,
41129 concurrent reads — 0 torn, 0 stray tmp files. `atomic_write` is sound.

`script/cache_clobber2.rb` (sequential, two DIFFERENT origins, both
`cache: true`): client b posts to :4600, whose only field is `onlyOnSecond`,
and `b.schema.query.fields` came back `["boom","slow","whoami"]` — origin
one's. `script/cache_clobber.rb` (concurrent), 6 runs: the winner alternated
3/3, so a third client pointed at origin one got origin two's schema half the
time.

## 19:05 — the class-level state table

Every `@@`, `class << self` ivar, `Mutex`, `Monitor`, `Thread.current`,
`Fiber[]` and module-level `||=` in `lib/`. No `@@` anywhere; the gem starts
no threads of its own (the dev watcher is Rails' `file_watcher`, owned by
Rails, joined via `app.reloaders`).

location | holds | written | read | guard | verdict
--- | --- | --- | --- | --- | ---
client.rb:95,139 `@schema_lock`/`@schema` | one client's schema | first `#schema` | dynamic parse, `run` | Mutex, held across the round trip | correct; the round trip inside the lock is F4
transport/http.rb:79-86 `@permits`/`@idle`/`@pid`/`@saturated` | the pool | per request | per request | Mutex + SizedQueue + pid-keyed `reset_after_fork` | correct; verified 400 req x 200 conc, fork with a warm socket
internal.rb:388,409 `REQUEST_MUTEX`/`@request_count` | `[req N]` debug tag | per logged request | same | Mutex | atomic per process, collides across workers (F6)
internal.rb:193 `Util.@composed` | path -> supergraph? | first ask per key | graph resolution, `:wire` | none | benign racy; worst case a duplicate parse
logging.rb:23,35,62 `logger`/`filter_parameters`/`instrumenter` | process config | boot | every request | none | write-once at boot; a runtime reassign is unsynchronized
logging.rb:150-152 `Thread.current[RETRIES/GRAPH]` | dynamic-extent labels | per dispatch | in `instrument` | thread/fiber-local | correct; 8 threads x distinct retry counts exact
codegen/registry.rb:143 `@registry` | default registrations | boot | generation | none (`||=`) | unguarded RMW; 0 losses in 4000
graph_weaver.rb:285-289 `@graphs` | declared graphs | boot, `to_prepare` | generation, `:wire`, tasks | none (index-then-write) | unguarded RMW; 0 duplicates in 4000
graph_weaver.rb:393-395,842 `@changed_files`/`@unmatched_registrations`/`@untyped_scalars_by_graph` | last run's report | `generate!` | after it | none | generation-time only
errors.rb:89 `@transport_errors` | retriable classes | at each transport's require | every retry decision | none | load-time writes only
testing.rb:352 `@config` | test config | boot, `configure` | per example | none | rspec single-threaded
internal/test_clients.rb:56-58,83,120 `@mode`/`@clients`/`@context` | this example's stand-ins | per example, per helper | per dispatch | none | 0 double-builds in 800; a thread inside an example is the exposure
testing/cassette.rb:114-127 `@lock`/`@entries` | one cassette | per record | per lookup | Mutex in-process, nothing across processes | lost update (F2)
testing/endpoint.rb:49 `@dispatch` + the client's `context` | one request's identity | per dispatch | per dispatch | Monitor, scoped to the Endpoint instance | wrong scope (F1), over-broad (F5)
codegen/{type_helpers,enum_type,scalar_type}.rb `@type_registry`/`@enum_registry`/`@scalar_registry`/`@helper_counts` | one Registry's tables | registration | generation | none, but per-Registry instance | generation-time
threads the gem starts | none | — | — | — | clean
