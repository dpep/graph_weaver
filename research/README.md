# Research

Synthetic user research from the 0.7.0/0.7.1 hardening push: roughly forty
agent passes — bug hunts, a junior developer meeting the gem for the first
time fifteen separate ways, a senior engineer stress-testing it from twenty
separate professional vantage points, a public-schema corpus sweep, a mutation
run, and a security audit — each working from a throwaway app, writing findings
to `/tmp/claude/graph_weaver/*.md`. Everything they found is fixed, documented,
or tracked in `PLAN.md`'s backlog; these logs are memorialized here because the
reasoning, the verbatim repros, the measurements and the matrices don't survive
in `/tmp`. **The logs are point-in-time and describe the gem's behavior AS
FOUND, since fixed** — for current behavior, trust the docs and CHANGELOG.md,
not these files.

## Index

One row per pass, in the order the passes ran. "Top finding" is that pass's
highest-severity or first-ranked item, in its own words, condensed.

| Pass | Viewpoint | Top finding |
|---|---|---|
| Hunt 1 | Adversarial bug hunt across the whole gem, ranked by user harm | `Transport::HTTP`'s connection pool isn't fork-safe: a socket warmed before fork is shared by all child workers, so responses cross between processes silently. |
| Hunt 2 | Follow-up hunt over surfaces added since hunt 1, security-focused | A typo'd `filter_parameters` key (e.g. `"passwrod"`) misses its redaction rule entirely, so the secret leaks in cleartext via `#value` and `#to_h` into logs/Sentry. |
| Hunt 3 | Final pre-publish hunt, six parallel hunters on the new v0.7.0 surfaces | A bare graphql-ruby `Schema` class in the documented multi-graph client slot emits zero instrumentation or logging, despite docs promising every request is covered. |
| Junior 1 | Rails app consuming a countries API, full README → getting_started → testing path | `graphql_fake`'s pin key must be the schema type name (`"Country"`), not the generated struct class name (`Countries`) — never stated. |
| Junior 2 | Rails Pokemon search page, input-error handling and i18n | `response.input_errors` silently returns empty against third-party non-graphql-ruby/Apollo servers (Hasura's `"validation-failed"` isn't in the known code list), quietly breaking the "one rescue point" promise. |
| Junior 3 | No-Rails, no-rake, console-only CLI | `graphql: :wire` mode raises requiring the `rack` gem, a prerequisite buried in testing.md's `:wire` section instead of called out upfront. |
| Junior 4 | In-process client against the app's own Rails/graphql-ruby schema, custom scalars/validators | `InputError#field` casing is inconsistent (snake_case client-side, camelCase server-side) — would silently misfile an error under the wrong form field. |
| Junior 5 | PokeAPI advanced filter page, deep read of errors.md/i18n.md kind vocabulary | One query against Hasura's schema generated 1183 files, because `bool_exp`/`order_by` inputs are transitively self-referential — contradicting the docs' "query-driven, not whole-schema" claim for inputs. |
| Junior 6 | Federation setup across two subgraphs, router/wire testing modes | federation.md never explains how to produce a supergraph SDL in the first place (e.g. `rover supergraph compose`) — ~40 minutes of improvisation. |
| Junior 7 | PokeAPI app translating errors/values into en/fr/ja | `Testing::Failure.graphql`'s documented bare-string form silently ignores an `extensions:`/`code:` kwarg; the working hash form is discoverable only by trial and error. |
| Junior 8 | Upgrading the gem 0.6.1 → 0.7.0 via upgrading.md and CHANGELOG | Clean run — the one failure (removed `graphql: false` mode) was exactly predicted by the upgrade guide's Renames table. |
| Junior 9 | Rails app, in-process schema, four schema changes across maintenance tasks | A cassette recorded before a breaking field rename still passed after the change — actively certifying a query the real resolver now rejects. |
| Junior 10 | Rails app testing 6 GraphQL failure modes plus wire-mode retry injection | `retry_mutations: true`, replayed against a real in-process resolver, created two separate orders for one click — no idempotency dedup at all. |
| Junior 11 | Two-graph Rails app: a countries API plus Hasura PokeAPI | `graphql_fake`'s `schema:` kwarg gave no working value for a dump-only graph (no owned schema class) — four failed attempts before finding the working shape. |
| Junior 12 | Console/IRB and script-based exploration of dynamic mode and CSV export | No doc explains how to browse a live endpoint's fields from the console; fell back to graphql-ruby's own schema/type API by trial and error. |
| Junior 13 | Fan-out background job, 8-thread pool, real Puma/forking | Docs never mention forking or `preload_app!` at all — no guidance on whether an eagerly-warmed pre-fork client/socket is safe to share across forked workers. |
| Junior 14 | Rails dev deliberately avoiding Sorbet and tapioca entirely | `T.nilable` in generated structs only validates shape at construction; nothing stops calling a method on a nil field, so `country.capital.upcase` still crashes with a plain `NoMethodError`. |
| Junior 15 | Cold start straight from the published 0.7.0 RubyGems package, no checkout | The gemspec deliberately excludes `examples/` from the packaged gem, so the README's prominently-linked example files don't exist for anyone who didn't clone the repo. |
| Senior A | Senior Ruby engineer maintaining a graphql-ruby API, focused on scalar registration doors | Registering `Money` as a bare decimal string silently drops currency on the wire — a EUR payment round-trips back as the server's default USD, no error. |
| Senior B | Senior Ruby engineer auditing server-side input errors, i18n, and logging in Rails | Client-side `@oneOf` enforcement is silently inert for any schema learned via introspection — the primary install path — because `GraphQL::Introspection.query` defaults to omitting `isOneOf`. |
| Senior C | Senior engineer running a real composed federation supergraph through the router | `@interfaceObject` poisons its interface's *other* implementers' subgraph attribution, breaking router construction entirely. |
| Senior D | Senior Ruby engineer, second scalars pass, focused on seams across mutations/modes/serialization | `ResultStruct` defines no `#to_json`; outside Rails, calling `.to_json` on a result silently returns just the object's `inspect` string, dropping every field with no warning. |
| Senior E | Senior engineer testing server-side validation, errors, i18n and logging end to end | A Rails JSON controller must deep-underscore camelCase params before calling generated `.execute`, or every field — even correctly typed ones — returns `kind: :unknown`, undocumented. |
| Senior F | Senior federation engineer probing cassettes, `@override`, and context over time | A cassette recorded against a working router keeps replaying successfully even after the supergraph changes so the same router build would now refuse to construct. |
| Senior G | Senior Ruby engineer, third scalars pass, multi-graph registry and `srb tc` | Block-form `extend_type` inside a `GraphWeaver.graph` block mints an unstable module name via a global counter — `verify` passes clean on a tree that cannot boot. |
| Senior H | Senior federation engineer testing `@link`, keys, `@override`, `@context` | When a `@fromContext` field's whole subtree resolves in one subgraph, the router silently sends `nil` instead of the ancestor's context value — a wrong but plausible answer. |
| Senior I | Senior federation engineer diffing the local router against real Apollo Router/gateway | The local router never tags a bubbled subgraph error with which subgraph failed, while both real Apollo gateway and Apollo Router always add that origin metadata. |
| Senior J | Performance engineer, budget-first, measuring scalar and federation costs | `FakeClient`'s `list_size` setting multiplies across every nested unbounded list field rather than sharing a budget — one setting becomes O(n²) fabricated data. |
| Senior K | Apollo Router operator validating a real production router config | The router's own `global_rate_limit` returns HTTP 503 with a GraphQL errors body, so `Retry` makes only one attempt and `QueryError#throttled?` reports false despite configured retries. |
| Senior L | Supergraph/platform owner validating rover-shaped composition and evolution | A scalar's breaking type change (`String` → a custom scalar) is correctly flagged by `schema:diff`, but if the new scalar still serializes as a JSON string, sorbet-runtime accepts it silently — zero exception, corrupted data downstream. |
| Senior M | Skeptical Rails engineer migrating fifteen hand-cast custom scalars off graphql-client | An unregistered `File`/Upload variable is silently `Object#to_json`'d into a garbage string carrying a live memory address and posted as ordinary JSON — no exception anywhere in the stack. |
| Senior N | Security reviewer auditing the channels that carry text the library didn't author | **F1 (HIGH):** a non-2xx response body echoing the query, variables, and `Authorization` header is spliced whole into `ServerError#message` and logged at WARN — contradicting logging.md's stated redaction guarantees. (Source lane for the "Security" row below.) |
| Senior O | Corpus rerun across 22 real-world schemas against the published 0.7.0 gem | A real double-extension query filename (`*.query.graphql`, GitLab's own convention, used by all 120 of its real queries) derives a broken Ruby constant name and aborts `rake graph_weaver:generate` entirely — losing every file in the batch. |
| Senior P | Concurrency reviewer stress-testing thread, fork, and process safety under real load | `Testing::Endpoint`'s identity-propagation lock is scoped to the instance rather than the request — 6 of 8 threads crossed identities in an end-to-end harness spec. |
| Senior Q | *(no log file — report only, in the session transcript)* | *(no log file — report only, in the session transcript)* |
| Senior R | Checkout/mutations engineer probing exactly-once and retry semantics on the write path | **HIGH:** `Retry-After` is silently discarded on the "envelope" failure path (5xx/4xx plus a GraphQL errors body — the real Apollo Router rate-limit shape), so retries fall back to exponential backoff instead of the server's requested delay. |
| Senior S | Observability engineer instrumenting OTel, Datadog, and the log-line/APM payload contract | Log records only setup and raw evidence scripts; the file itself defers its ranked findings to "the final chat message" — no top finding stated in the log. A second, colliding instance (`senior-log-S-2nd-instance.md`) ran the same brief independently via scripts rather than rspec and also states no graph_weaver-specific top finding, only an upstream gap (`opentelemetry-instrumentation-rails`'s own Railtie never auto-requiring). |
| Senior T | Subgraph author testing the dual role of federation member *and* graph_weaver client caller | "The biggest finding of the pass": a subgraph resolver calling `GraphWeaver.client` passes under every test mode (`:router`, `:wire`, `:in_process`) because each conveniently intercepts the call, then 500s under a real gateway since the hardcoded test hostname has no real DNS. |
| Senior U | graphql-ruby server author who also consumes their own API as a graph_weaver client | **HIGH:** a server-only `coerce_result` change (string → JSON number) is invisible to `verify`/`schema:diff`/`generate!` alike, surfacing at runtime as silent `BigDecimal` precision loss with no exception raised. |
| Corpus 1 | Public-schema sweep, initial pass: 23 real-world schemas, 3 seeds each | A schema's `input Result` collides with the library's own `MODULE_RESERVED` constant and emits `class Result < T::Struct` **twice** — a silent wrong answer where one struct answers for both a variable and a response. |
| Corpus 2 | Same lane, wider follow-up: seeds 301/401/501 plus a hostile pass on the 12 largest schemas | 36 of 250 published Linear SDK operations select `__typename` correctly (once per union member) but are refused with advice pointing at only one of the six members — a refusal that misleads. |
| Mutation | Mutation testing: do injected bugs actually get caught | `Hints.shape_drift`'s null-drift guard can never fire, because `drifted_shape` strips the prop's nilable-ness before calling it — a cast failure blames an unrelated nullable field instead. |
| Security | The fix lane spawned from Senior N's audit (same log, `senior-log-N.md` — no separate discovery log of its own) | Fixed F1 (HIGH, see Senior N above) alongside F2 (`Testing::Endpoint` context leaking across concurrent requests), F3 (log-line/APM injection via `extensions.code`), F4 (`filter_parameters = []` also disabling URL credential scrubbing), and F5 (a TLS error message bypassing redaction). All five are in CHANGELOG.md. |
| Migration experiment | A staff engineer migrates a graphql-client Rails app and a hand-rolled Net::HTTP service onto the gem (`migration-experiment.md`) | A shared fragment on an object type generated two unrelated structs, so nothing could name "a pet"; the `abstract!` mixin workaround broke `srb tc` two tools away. |
| Naming memo | A rubyist explores shorter result type names, user-tested against the two migrated apps (`naming-options.md`) | No codegen change: the gem owns 8 of a 116-character sig; an app-side constant alias takes it to 72 and makes the sig chain affordable. |
| Junior (published gem) | Follows `docs/migrating.md` step by step against graph_weaver 0.7.5 from RubyGems | `schema:refresh` rewrote a dump graphql-client still reads from 2,000 pretty lines to one compact line; parsed by luck. |
| Junior (fragments, enums) | Builds an in-process Pet API from the docs alone across hoisted fragments, `fallback: true`, and the three testing tags | A `:wire` refusal fires in the tag's before-hook, so it can't be asserted inside the example. 16 minutes to green, never opened `lib/`. |
| Hunt 7 | The skeptic over everything 0.7.5 and Unreleased changed; `object_node` byte-identity checked over 4,057 generated files | `schema:refresh` gutted a composed supergraph and exited 0 — the overwrite guard was a `@join__` substring test a gateway's declared directives satisfy. |

A few notes on the shape of this table:

- **Corpus 1/2** are two phases documented in the single `corpus-report.md` archived here, not two separate report files — the lane's own wider seed pass (301–501, plus a hostile pass on the twelve largest schemas) is what actually found its fourth bug, so it earns its own row.
- **Security** reuses Senior N's log rather than a log of its own: `brief-security.md` (in `briefs/`) commissions a lane to fix exactly what senior N found, and that fix lane produced no separate research artifact — its output is the CHANGELOG entries and specs, already merged.
- **Senior Q** has no log file among the archived material; per the source brief, treat it as reported only in that session's transcript.
- `transport-hunt-report.md`, `mutant-report.md`'s sibling `inputs-memo.md`, `followups-post-070.md`, and the four `scribe-queue-*.md` files are archived in `logs/` too (see below) but don't get their own index row — they're a focused sub-hunt, a standing memo, a post-release backlog, and docs handoff notes respectively, not a ranked-findings pass in this sequence.

## What's here

- `logs/` — every senior and junior session log, the three hunt reports, the corpus and mutation reports, the transport hunt, and a handful of standing memos and scribe handoff queues.
- `briefs/` — every brief (`brief-*.md`) handed to an agent to start a pass. Read one to see exactly what an agent was asked to do and why.
- `corpus/` — the scripts that ran the corpus sweep (fetchers, probes, the reserved-name/enum-collision census, the sweep drivers). The schema dumps themselves (`*.json`/`*.graphql`, ~20 MB) aren't kept here — they're cheap to re-fetch and the sources are in `corpus-report.md`.

## How to run one again

Pick a brief from `briefs/` matching the pass you want to repeat (e.g.
`brief-corpus.md` for the schema sweep, `brief-hunt3.md` for the last
pre-publish hunt, `brief-senior-N.md` for the security audit) and hand it to a
fresh agent — each is self-contained: toolchain, baseline sha, scope, and gate.
Expect the baseline sha and any surface counts to be stale; the brief's own
"read first" pointers (docs, CHANGELOG `## Unreleased`) are what to trust
instead.

For the corpus sweep specifically: the fetch/probe/sweep scripts in `corpus/`
still work standalone — `fetch.rb`/`fetch2.rb`/`fetch3.rb` pull schemas,
`sweep.sh`/`sweep2.sh` drive `bin/round-trip` over them, and
`census.rb`/`collisions.rb`/`reserved.rb` tally the reserved-name and
enum-case-collision hit rates reported in `corpus-report.md`. Cache dumps
under a scratch directory, never in the repo.
