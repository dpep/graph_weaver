# Senior S — the observability engineer (second concurrent instance, graph_weaver main @ 00038e5)

**Collision notice**: `/tmp/claude/graph_weaver/senior-log-S.md` and
`senior-app-S` already existed with a different session's content when I went to
write mine (same brief, same conclusions, built via scripts instead of rspec) —
two instances of this exact brief ran concurrently over the same scratch paths.
I did not overwrite that session's log; this file and `senior-app-S9f21` are mine,
kept separate so both are readable. Whoever reconciles this round's reports should
treat the two as independent replications of the same brief, not as one session's
work — they corroborate each other on every point both reached.

16:46 — start. Read brief-senior-S.md + brief-round6-common.md. Forked a sub-agent to
skim senior-log-{B,C,E,F,N} and junior-log-{3,4,5,10,12,13} for prior logging/APM
findings (none of the nearby senior federation logs touch docs/logging.md directly;
senior N's security pass found F3 — a hostile `extensions.code` newline forging a
second log line — already fixed on main per docs/logging.md's "control characters
stripped, capped" line and `Redact.tag`; senior K's Apollo Router pass found
traceparent-out via a proc header works end to end against a real router, and that
the payload never carries a trace/request id back).

16:50 — read docs/logging.md in full, then lib/graph_weaver/logging.rb and
lib/graph_weaver/log_subscriber.rb, to get the exact payload contract and the
instrument/with_retries/with_graph primitives before writing anything, rather than
guessing from prose (this pays off later — the payload keys per mode/error class
below all trace to specific lines here).

16:51 — read lib/graph_weaver/errors.rb in full for the error hierarchy (needed for
the error-taxonomy ask): confirmed QueryError/CastError are raised by
`Response#data!`, OUTSIDE the instrumented block (`Transport#execute` /
`InProcess#execute` call `Log.instrument` around `perform`, and `data!` is called by
the generated module's `execute!` after `execute` already returned) — this predicts
the :errors-not-:failed and CastError-invisible findings below, confirmed empirically
later.

16:52 — hit a real environment hazard: built `senior-app-S`, and mid-build found a
`main_schema.rb` file and directory contents I never wrote (a `BillingSchema`, a
`throttled`/`boom` query, a comment about testing `:graph` in a multi-graph app —
uncannily similar to my own plan). This is the collision noted at the top. Time-boxed
at ~10 min: switched to a collision-proof directory name (`senior-app-S9f21`) rather
than chase or coordinate with the other session.

17:00 — real Rails 8.1.3.1 app (`senior-app-S9f21`), `graph_weaver` via `path:`,
`opentelemetry-sdk` + `opentelemetry-instrumentation-rails` (0.42.0) + `datadog`
(2.42.0) + `rspec-rails` + `webmock`, `json < 3` pinned (the same Rails
8.1.3.1/json-3.0.2 `ActiveSupport::JSON.decode` breakage every other senior/junior
session hit). Two in-process graphql-ruby schemas declared as two graph_weaver graphs
(`:store` — Product/Flaky/PlaceOrder — and `:billing` — Invoice), each `client:` the
schema class name string directly (no wrapper needed — a schema class satisfies the
execute contract on its own). `rake graph_weaver:generate`: 7 files, clean first try.

17:03 — FINDING (environment, not graph_weaver): `opentelemetry-instrumentation-rails`
0.42.0's own Railtie (`lib/opentelemetry/instrumentation/rails/railtie.rb`, which is
documented — in its own comment — to call `OpenTelemetry::SDK.configure(&:use_all)`
automatically) is never required by the gem's own `lib/opentelemetry/instrumentation/
rails.rb` — grepped the installed gem for "railtie", one hit, in the dead file itself.
So the "automatic" SDK configuration this gem's own comment implies never fires;
nothing configures the SDK until an app calls `OpenTelemetry::SDK.configure` itself.
Cost ~20 minutes (a `ProxyTracerProvider` `NoMethodError` before finding the dead
`require`). Filed here because it's exactly the kind of gap that would make someone
conclude graph_weaver's OTel example "doesn't nest under the Rails span" when the real
cause is one line upstream never running.

17:04 — `config/initializers/observability.rb`: one explicit `OpenTelemetry::SDK.configure
{ |c| c.add_span_processor(SimpleSpanProcessor.new(InMemorySpanExporter.new)); c.use_all }`
(env vars `OTEL_TRACES_EXPORTER=none` etc set in `config/application.rb`, before
`Bundler.require`, since the exporter default is otherwise `otlp`). Datadog: `Datadog
.configure { |c| c.tracing.enabled = true; c.tracing.instrument :rails; c.tracing.writer
= NullWriter.new if Rails.env.test? }` — the NullWriter (two methods: `write`/`stop`)
replaces the real agent transport in test, chosen after ~15 minutes fighting
`SyncWriter`/webmock races (a background `AsyncTransport` thread's flush can outlive
an example's rspec-mocks scope and crash the whole run; `test_mode.enabled` switches to
a *synchronous* writer but that still does real agent-info HTTP negotiation before
every flush) — time-boxed, and irrelevant to what this brief actually asks (the shape
of the spans the documented adapter snippet builds, not datadog-agent's wire format,
which is datadog's own concern).

17:08 — `spec/requests/otel_spec.rb`, real `opentelemetry-sdk` + real
`opentelemetry-instrumentation-rails`, docs/logging.md's OTel snippet verbatim as
`GraphWeaver.instrumenter`, real `InMemorySpanExporter`. 5/5 green (findings below).

17:10 — `spec/requests/datadog_spec.rb`, docs/logging.md's Datadog snippet verbatim,
real `Datadog::Tracing.trace`/`SpanOperation` objects captured via `and_wrap_original`
on `Datadog::Tracing.trace` (real spans; `Datadog::Tracing.trace` is also called
block-less by Datadog's own Rack middleware, which the spy has to pass through
untouched — first attempt crashed on that). 4/4 green, same shape as OTel.

17:11 — `spec/requests/log_subscriber_spec.rb`: `LogSubscriber` vs a raw
`ActiveSupport::Notifications.subscribe` on the same event, field parity, `:status`
symbol type, `:http_status` presence/absence, and a live re-check of security senior
N's F3 fix (a `\n` in `extensions.code` — confirmed one line, control character
folded to a space, not two lines). 4/4 green.

17:12 — `spec/requests/traceparent_spec.rb`: a real `OpenTelemetry.propagation.inject`
call inside a `headers:` proc on `Transport::HTTP`, driven against a real (webmock-
stubbed) POST, decoding the captured header to confirm it's a genuine per-request W3C
`traceparent` tied to that request's own GraphQL span — not a fixed value baked in
once. 2/2 green.

17:13 — `spec/requests/payload_contract_spec.rb`: drove `:in_process`, `:live`
(bare `Transport::HTTP`), `:fake` (`Testing::FakeClient`), and a cassette
record+replay pair, subscribing to the raw event each time and checking whether it
fires at all and with which keys. Cross-checked against `grep -rn "Log.instrument"
lib/graph_weaver/testing/` (zero hits in fake_client.rb, router.rb, cassette.rb,
fake_subgraph.rb, failure.rb) before writing the spec, then confirmed it empirically.
4/4 green. `:router` (the local federation test double, `testing/router.rb`) is
source-confirmed the same way (no `Log.instrument` call in `Testing::Router#execute`)
but NOT independently driven — building a composed supergraph purely to re-confirm a
one-line source fact already covered by six other sessions' federation passes felt
like the wrong use of the time budget; flagging this as read-not-driven rather than
silently claiming full coverage.

17:14 — `spec/requests/error_taxonomy_spec.rb`: one example per error class
(TransportError/ServerError/QueryError/CastError/client-side InputError), each
subscribing raw and asserting on the exact payload (or its absence) plus the raised
exception. 5/5 green — see the taxonomy table in the final report.

17:15 — Full suite together (`spec/`): 24 examples, 0 failures, stable across default
order and `--order rand:1`/`--order rand:42`. No `srb tc` run for this app — it's a
throwaway observability harness, not a Sorbet consumer, and no other senior/junior
session found that omission material for a plain-Ruby-app-style check.

## Time accounting
- 16:46–16:52 (6m): read briefs, fork the nearest-log skim, read docs/logging.md +
  logging.rb + log_subscriber.rb + errors.rb.
- 16:52–17:00 (8m): app scaffold, the directory-collision detour, Gemfile, two
  schemas, two graphs, codegen.
- 17:00–17:04 (4m): the opentelemetry-instrumentation-rails dead-Railtie diagnosis.
- 17:04–17:08 (4m): Datadog NullWriter/SyncWriter/webmock-race diagnosis.
- 17:08–17:15 (7m): six spec files, all green, plus the source-confirmation for
  `:router`.
- Total: ~29 minutes of actual driven work (wall clock spans longer due to the
  directory collision and two upstream-gem diagnoses eating time without producing
  graph_weaver findings).
