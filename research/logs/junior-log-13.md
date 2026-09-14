# Junior dev log — graph_weaver fan-out task

2026-09-13T03:16Z — Starting. Never used this gem. Read README.md top to bottom first.
  - README points me at docs/getting_started.md for the production Rails setup, docs/transports.md
    for pooling/thread-safety (my job #1 question), docs/logging.md for `GraphWeaver.logger`.
  - Noted: `rails g graph_weaver:install <url>` writes initializer + app/graphql layout.
  - Noted: `GraphWeaver.new(url)` + `.parse` is the console/no-codegen path — mentioned as relevant
    to task's initializer example `GraphWeaver.new(url, cache: true).schema`.
  - Testing tags mentioned: `graphql: :fake`, `:in_process`, `:router`, `:wire` — I'll need `:wire`
    for the slow-server timeout spec. Details deferred to docs/testing.md.

2026-09-13T03:25Z — Read docs/getting_started.md fully (production Rails path), docs/transports.md
  fully (mine — pooling/thread-safety/timeouts), docs/logging.md fully (mine — instrumenter),
  docs/testing.md fully (fakes/in_process/router/wire/Failure), and generated_modules.md sections
  Anatomy/Naming/Variables/Clients/Dynamic mode. Also real_world.md's `cache: true` snippet.

Key findings for task #1 (pool):
  - transports.md: "Transport::HTTP opens up to pool_size: sockets lazily and reuses the warmest
    one; requests beyond that queue for a free slot rather than opening unbounded connections."
  - "pool_size: defaults to RAILS_MAX_THREADS (else 5) — the same variable Rails sizes its own
    connection pool from, because it is the same question: how many requests this process can
    have in flight at once."
  - "Saturation is not silent: the first request that has to queue logs a warning naming how long
    it waited and what to raise." -> exact wording TBD, will observe at runtime.
  - Thread-safety is implied by "One transport is normally the whole app's transport ... so it has
    to serve every thread" plus the fiber-scheduler paragraph (SizedQueue/Mutex) — the doc never
    says the word "thread-safe" outright about Transport::HTTP directly, it's implied by the whole
    section's framing. Recording as a possible confusion point.
  - Decision: job uses a thread pool of 8, so pool_size should be >= 8 (== 8) so no thread has to
    queue for a socket, per the "requests beyond that queue" line, since I want a clean p95 read
    on the *network* time, not on internal socket-queueing.

Key findings for task #4 (wire timeout spec):
  - testing.md's :wire section shows `stub_request(...).to_timeout` for a simulated timeout
    (webmock raises whatever Net::HTTP raises for a broken socket) — this does NOT exercise our
    own configured read_timeout: value, it just makes webmock's fake socket blow up immediately.
  - Searched testing.md for real injected latency (a slow response that takes N seconds so our
    own read_timeout: fires) — NOTHING. Exact terms tried: "latency", "delay", "sleep" — no hits
    describing a slow-response helper.
  - The one lead: ":wire" section says "GraphWeaver::Testing::Endpoint is an ordinary Rack app
    wrapping anything that satisfies the client contract — so mount it yourself if you'd rather
    have a real socket" (docs/testing.md line ~524-529) — i.e., run a real Puma/WEBrick socket
    instead of the webmock stub. Plan: use that suggestion literally — mount a slow custom Rack
    app on a real socket in a background thread, sleeping longer than our read_timeout:, and point
    a Transport::HTTP directly at it. This is a plain Ruby/rack technique, not something the docs
    spell out step by step for latency-injection specifically — noting this as a doc gap.

2026-09-13T03:55Z — First real error (verbatim), running rspec after writing the :wire spec:

GraphWeaver::Error:
  graphql: :wire stubs your endpoints with webmock, which is loaded but not enabled — nothing is hooked, so this example's requests would leave the suite for the real endpoint. `require "webmock/rspec"` in your spec helper (Bundler.require only loads it), or WebMock.enable! for the suite.

  This is exactly what testing.md says near the bottom of the :wire section ("Bundler.require
  loads webmock without installing its adapters") — I just hadn't added the require yet because
  I read that paragraph before writing the spec and forgot to act on it. Not a doc gap, a
  me gap. Fixing: add `require "webmock/rspec"` to spec/rails_helper.rb.

2026-09-13T04:05Z — All 4 specs green (job x2, wire x1, real-timeout x1). Ran the job spec 13
  times total (3 seeds + 10 plain runs) to shake out thread races in FakeClient under 8 threads —
  zero failures, zero flakiness. FakeClient behaved fine under concurrent load in this test; I did
  not find anything in testing.md that promises this in writing, so this is empirical, not a doc
  claim (recording as confusion/gap #_).
  - Pin used: `graphql_fake("pokemon_v2_pokemon.name" => "pinned-pokemon")` — had to remember pins
    are schema vocabulary (the Hasura type "pokemon_v2_pokemon"), not our query's "pokemon" alias
    or Ruby's PascalCase. Got this right first try because testing.md's pin section says so
    explicitly ("a Hasura table type is `pokemon_v2_pokemon` and not a Ruby-cased guess at it") —
    that sentence saved me a debugging cycle.
  - real read_timeout spec: had to add `WebMock.disable_net_connect!(allow_localhost: true)`
    around the one example that wants a genuine localhost socket, since webmock/rspec disables
    net connections suite-wide by default. Not covered by testing.md at all (that page assumes
    :wire's own webmock stubbing, not a hand-rolled real socket) — pieced together from general
    webmock knowledge, not from graph_weaver's docs. Recording as confusion #_ (real latency
    injection not covered).

2026-09-13T04:20Z — Booted Puma for real (config/puma.rb: workers 2, preload_app!, threads 8/8,
  RAILS_MAX_THREADS=8). Both workers booted clean, eager `client.schema` ran once in the master
  before fork (one log line at boot). Hit GET /fanout (40 Pokemon over an 8-thread pool, same
  code as the job) repeatedly, both sequentially and 4-at-once concurrently, against both worker
  PIDs, plus a fresh restart for a clean single measurement:
    - 15+ full fan-outs (600+ individual PokeAPI calls) across both worker PIDs, zero mismatches
      against the hardcoded ground-truth Pokemon names (see FanoutController::EXPECTED_NAMES).
    - No cross-talk found: nothing suggests the eagerly-warmed pre-fork client/socket caused one
      worker to read another's response.
  This is an empirical result, not something the docs promised — docs/transports.md and the rest
  never mention Puma, preload_app!, or forking at all (grep for "fork" across docs/ + README: zero
  hits). I went in expecting a real risk here (a Net::HTTP/TLS keep-alive socket opened by the
  eager `.schema` call in the initializer, before preload_app! forks, would be a duplicated live
  fd in both child processes — the same class of bug ActiveRecord's own "reconnect after fork"
  guidance exists for) and could not reproduce it under this load. Doesn't mean it's absent under
  different timing/load; it means the docs give a Rails developer no way to know whether to worry,
  and no `on_worker_boot` guidance the way ActiveRecord docs give you.
  - /stats confirms GraphqlStats is per-worker-process (as plain Ruby module state always would be
    post-fork — not a graph_weaver-specific thing, just worth remembering when reading fanned-out
    stats): worker A's count/percentiles only reflect requests *that process* served.

  Clean single 40-call fan-out (fresh worker, first request after restart):
    wall clock: 1.067s for all 40 (8-way concurrency, ~5 waves)
    p50: 118.84ms   p95: 455.21ms   retries: 0
  (a second, busier run on a warm process: p50 307.75ms / p95 668.73ms on a worker that had
  already served 240 calls — numbers move around, PokeAPI's own latency is the dominant variable
  here, not anything on our side)

2026-09-13T04:30Z — Verified (console) that `GraphWeaver.new(url, pool_size: 8)` is NOT accepted:

  /Users/dpepper/code/lib/ruby/graph_weaver/lib/graph_weaver/client.rb:47:in 'initialize': unknown keyword: :pool_size (ArgumentError)

  This confirms transports.md's silence on the one-shot `GraphWeaver.new` accepting `pool_size:`
  is accurate, not just an omission — it really does refuse. RAILS_MAX_THREADS is genuinely the
  only documented lever for the one-shot client's pool size. (This is the one moment I dipped
  toward "poking beyond the docs" rather than reading — justified because I was about to write
  a confusion in this log that turned out to be wrong, and one rails runner line settled it
  faster than staying uncertain. No lib/ file was opened, just the error message lib/ raised.)

2026-09-13T04:35Z — Doc search misses, exact terms, scoped to docs/ (recorded as they happened,
  consolidated here):
  - "latency"        — 0 hits anywhere in docs/
  - "slow server"     — 0 hits
  - "simulate latency" — 0 hits
  - "delay" in testing.md — 0 hits (only appears in transports.md, and only about retry backoff:
    base_delay/max_delay/Retry-After — nothing about a slow *response*)
  - "sleep" in testing.md — 0 hits (transports.md has one, about Kernel#sleep being
    scheduler-aware under a fiber scheduler — unrelated to injecting latency)
  - "fork" / "Fork" / "forking" — 0 hits across docs/ and README.md

2026-09-13T04:40Z — Wrapping up. Final specs run: 4 examples, 0 failures (job x2 under
  graphql: :fake, wire timeout x1 under graphql: :wire, real-socket timeout x1 untagged/plain).
  Puma killed. Writing final report now.

Note on timestamps in this log: the sandbox's `date` output jumped backward by about an hour
partway through the session (checked twice, got an earlier time than a prior entry) — so treat
the HH:MM values above as roughly ordered, not as a reliable wall-clock duration source. Minutes-
per-step in the final report are effort-based estimates, not measured from these timestamps.
