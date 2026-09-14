# Senior S: the observability engineer

Read /tmp/claude/graph_weaver/brief-round6-common.md. App dir `senior-app-S`, log `senior-log-S.md`. docs/logging.md ships two-line OpenTelemetry and Datadog adapters and a documented `execute.graph_weaver` payload contract; nobody has run them against the real SDKs. You wire this into a real Rails app with the real `opentelemetry-sdk` (and `opentelemetry-instrumentation-rails`), export to an in-memory span exporter, and read the spans.

- The documented OTel adapter verbatim: does it produce a span per operation, with the payload keys as attributes, nested under the Rails request span, with the right `status` on a failure; what `duration_ms` vs the span's own timing says; whether an exception inside `execute` marks the span; whether `:graph` reaches the span in a multi-graph app; whether a `Retry` produces one span or N.
- The Datadog adapter (`ddtrace`/`datadog` gem) the same way, to a stubbed agent.
- `LogSubscriber`'s one line vs `ActiveSupport::Notifications` directly: field parity, `:status` symbols, `http_status`, and the tag stripping the security lane added (a hostile `extensions.code`).
- `traceparent` propagation out (proc headers, per the operator's finding), and whether the gem could carry the current span's context automatically (what would it cost).
- Payload contract drift: every key `docs/logging.md` documents, asserted present with the documented type across live, `:fake`, `:in_process`, `:router`, `:wire` and a cassette replay — which modes emit the event at all, and are the keys the same.
- Error taxonomy for alerting: for each error class the gem raises, what `payload[:error]`/`:code`/`:status` look like, and whether an SLO of "5xx-equivalent rate" is computable from the payload alone without parsing messages.
Report the span trees (one per mode) as text, the contract table, and every key that differs by mode or is missing.
