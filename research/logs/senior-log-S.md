# Senior S log — observability engineer

2026-09-13T23:51:01Z
Start. Read brief-senior-S.md + brief-round6-common.md + docs/logging.md + lib/graph_weaver/logging.rb + log_subscriber.rb + errors.rb. main sha:
00038e59d5db308374492d55f80a0a287529f340 Brand the union-dispatch refusal and name its file

## What I built
Real Rails 8.1.3 app at /tmp/claude/graph_weaver/senior-app-S, graph_weaver via
`path:` to the checkout, plus real `opentelemetry-sdk`,
`opentelemetry-instrumentation-rails` (which pulls in action_pack/rack/etc.),
and `datadog` (2.42.0). MainSchema/BillingSchema (in-process), a real WEBrick
GraphQL server on a random port (wire mode + /boom500 + /flaky-then-ok for
Retry), GraphqlController exercising ok/boom/throttled/billing/wire/wire_500/
wire_traceparent/retry, one codegen'd query module (PersonQueryQuery) for the
CastError timing test.

Early hiccup: senior-app-S got reduced to just `app/controllers/` between two
of my own commands (disk was at 94% capacity — some external process almost
certainly reaped it as scratch space cleanup while this round's 14 seniors +
15 juniors all build apps under the same /tmp/claude/graph_weaver). Rebuilt
in one batch and moved fast; no further loss. Not a graph_weaver finding —
noted here only because it cost ~10 minutes.

## Section-by-section findings — see final chat message for the full,
ranked report with severities/repros/messages/fix shapes. Raw evidence:
- script/observe_otel.rb — OTel span trees, all 7 modes, real InMemorySpanExporter
- script/observe_datadog.rb + config/initializers/datadog.rb (writes
  dd_spans.jsonl from before_flush, since ActionDispatch::Integration::Session
  doesn't drain the Rack body the way a real server does, so SyncWriter defers
  flush to process exit)
- script/observe_traceparent.rb — real W3C traceparent, span-id verified to match
- script/contract_drift.rb — fake/in_process/wire/cassette-replay/router event counts
- script/cast_error_timing3.rb — CastError vs already-closed :ok payload
- script/hostile_code.rb — extensions.code control-char stripping under a live attack string
