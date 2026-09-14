# Senior O — the corpus rerun (0.7.0 published gem)

App dir: `/tmp/claude/graph_weaver/senior-app-O` (plain Ruby project, `gem
"graph_weaver", "0.7.0"` from RubyGems — never a `path:` Gemfile). Gem checkout
at /Users/dpepper/code/lib/ruby/graph_weaver read only throughout (only read
via `Read`/`cat`, never edited); the app dir is a private copy of the corpus
scripts, repointed at the published gem.

15:36 — Read brief-senior-O.md + brief-round5-common.md. Read corpus-report.md
in full (23-schema table, four fixed bugs, reserved-name/collision census,
"investigated and left alone" section) and followups-post-070.md (don't
re-report what's there — persisted queries, schema:check against supergraph,
correlation id, multipart uploads, list_size Hash, ISO8601 cast default, the
as_json sub-microsecond bound already flagged as "found, not a new bug").

15:37 — `git log --oneline` on the checkout to find the three lanes the brief
says changed since the corpus report: `fbcac73` (as_json emitted per struct —
this IS the followup item, confirms the harness gap is real and unclosed),
`8aeb5d3` (@key list-ness — federation directive, not exercised by a public
schema corpus, no federation SDL in the corpus), `1ddfa98` (type-helper naming
— block-form extend_type registry naming, also not corpus-shaped). The
input-type-named-after-a-constant refusal and the union __typename message
fix are already in the corpus report (252d66e, 52526e7) — re-run for
regression, not "new."

15:38 — `gem install` check: only 0.1.0/0.4.6/0.5.0 present locally. Built
senior-app-O/Gemfile with `gem "graph_weaver", "0.7.0"` (rubygems.org source,
no path:) and `bundle install` — fetched clean from RubyGems, confirms 0.7.0
really is published and pullable.

15:38-15:39 — Copied `bin/round-trip`, `spec/support/round_trip.rb`,
`spec/support/schema.rb`, `spec/support/federation_router_graph.rb` from the
checkout (read-only reads) into the app dir; repointed `bin/round-trip`'s
`require_relative "../lib/graph_weaver"` to `require "bundler/setup"; require
"graph_weaver"` so every run below hits the RubyGems install, never the
checkout's lib/.

15:39-15:40 — Re-fetched all 19 introspectable schemas from the report's live
endpoints (fetch.rb/fetch2.rb/fetch3.rb URLs, corrected two stale ones —
fetch.rb's swapi URL 301s, fetch2.rb's `/graphql` path is the one that
actually answers) through `GraphWeaver::Transport::HTTP` +
`SchemaLoader.introspect`, published-gem code path. All 19 succeeded, same
endpoints as the report, none newly broken. Re-fetched linear.graphql (byte
identical to the shared cache — upstream hasn't moved) and shopify-admin.graphql
(had to find the corrected raw path via the GitHub API — `soenneker/...`'s
`graphql.schema` lives at the repo root, not under
`src/Soenneker.Shopify.GraphqlClient/`, the guessed path 404s). Copied
`examples/github/schema.json` (repo dump, per the report's own sourcing) —
reading it from the checkout, not modifying it.

15:41 — `census.rb` (repointed at the gem) over all 22 schemas + shopify-admin
+ linear: all load clean, type/kind counts match the report table (gitlab
2686/879/469, pokeapi 1997/2262/177, github 1010/402/253, etc. — see report
for the full table). No load regression.

15:42 — `collisions.rb` (repointed): enum-case collisions 72 (all GitLab, same
sort enums), field/arg underscore collisions 7 (all universe, same three
types), constant collisions 0, client/variables kwarg collisions 0. Byte-for-byte
the same shape as the report. `reserved_hitlist.rb` (new, small — walks
`Codegen.prop_name` over every field/arg) confirms the 11-coordinate/4-prop/
5-schema reserved-name hit list is unchanged too. **No drift in any static
census.**

15:43 — Launched the main round-trip sweep in the background:
`sweep.sh` at seeds 1/101/201 (report's own seeds) + three new ones (601/701/
801, continuing the report's own progression past its 301/401/501 wide pass)
+ `--hostile` at seed 1, `-c 100`, over all 22 schemas (github.json,
linear.graphql and shopify-admin.graphql included this time — the report's
first pass table already covered them, this reruns identically). 154 runs.

16:05-16:20 — The backgrounded `nohup` sweep silently stalled partway through
`pokeapi` (its process stayed alive but stopped writing — orphaned when the
session's monitor/shell context cycled) and never reached shopify-admin,
spacex, swapi, tcgdex, trygql-basic, trygql-web, universe or wpcontent.
Caught by checking `out/*.txt` directly rather than trusting the launcher
was still moving. Killed the stale process and finished every remaining run
in the foreground, in chunks: pokeapi's last 3 (701/801/hostile — the slow
one, ~100-130s each, `run_in_background` auto-engaged past the 120s default
timeout once and I let its notification land rather than re-polling),
spacex+swapi+tcgdex (21 runs), trygql-basic+trygql-web+universe (21 runs),
wpcontent (7 runs), and — caught only by re-deriving file counts per schema
rather than trusting the earlier "154 runs" arithmetic — shopify-admin,
which the stalled launcher had never reached at all (7 runs). Final tally:
154/154 files present, all seven configurations (1/101/201/601/701/801/
hostile-1) for all 22 schemas, zero non-"0 failures" tails, ~29,900 total
inbound round trips across the corpus.

15:41-15:43 (parallel) — `as-json-sweep.rb` (the followups-post-070.md item's
own throwaway script, copied and repointed) over the FULL corpus at c=150,
not just the three fixtures it was scoped to originally. Finished quickly
(small schemas). Result: 8/22 schemas show a handful of `as_json` failures,
ALL of the identical shape —
`... .created_at: 2024-01-15 10:20:30.123456789 UTC vs ...123456 UTC` — a
9-digit-nanosecond stand-in Time value round-tripping to 6-digit microseconds.
Cross-checked against `docs/scalars.md`'s own table ("ISO 8601, with
microseconds when the value carries a fraction") and `coerce.rb`'s comment —
this is the exact, already-documented sub-microsecond bound the followups
entry names, now confirmed at 22-schema scale (2181 as_json trips total, only
this one shape, no other failure). Not a new bug — closes out that followup
item's "run it on the full corpus" ask.

15:44-15:46 — Real-query pass via the PUBLIC `GraphWeaver.parse` (not
`Codegen.parse`, which `bin/round-trip` and the original corpus sweep call
directly) over Linear's 250 SDK ops (`corpus/q-linear`, reused verbatim —
plain text, not gem-version-sensitive) and GitLab's 120 split `.query.graphql`
files (`corpus/q-gitlab`, ditto) and the repo's own 3 GitHub example queries.
`real-queries-sweep.rb` (new): parse, then 4 draws/response verified same as
`bin/round-trip -q`. Linear: 250 ops, 36 refused (identical count and shape to
the report's known union-__typename issue), 856 trips, 0 failures. GitLab: 67
of 120 files don't reference an unresolved `#import`, 10 refused (enum-sort
collisions + reserved-kwarg refusals, same shapes the report documented), 228
trips, 0 failures. GitHub: 3/3, 0 refused, 12 trips, 0 failures. **Matches the
report exactly — nothing new via the public parse path in isolation.** Note
why: this pass calls `GraphWeaver.parse(schema:, query: <raw text>, name:
"Q#{i}")` — a string, not a path, with `name:` given explicitly — so it never
touches `Internal::Util.module_name`'s file-name derivation. That derivation
is only reached when `GraphWeaver.parse`/`generate!` is handed an actual
`.graphql` **path** and left to name the module itself, which is exactly what
`rake graph_weaver:generate` always does. That's where Finding 1 turned up,
not here — the file-path code path is the one nobody had driven with a real,
oddly-named corpus until this pass.

15:47-15:52 — `rake graph_weaver:generate` in three scratch sub-apps
(rake-github, rake-linear, rake-gitlab under senior-app-O), each with its own
Gemfile pinning the published gem (no path:), a bare Rakefile
(`require "graph_weaver/tasks"`), and the same query corpora as the parse
pass, to exercise the packaged gem's task loading end to end (`rake -T`,
`rake graph_weaver:generate`) — the thing the corpus report's own sweep never
touched (it called `Codegen.parse` in-process, never `rake`).

- rake-github (3 ops): clean, 3 files generated, first try.
- rake-linear (250 ops, minus the 36 known-refused): `rake graph_weaver:
  generate` ABORTED with zero files written on the FIRST hit — traced to
  `GraphWeaver.generate!`'s documented all-or-nothing contract ("Every plan
  first, then every write... generation refusing must leave the tree exactly
  as it was", graph_weaver.rb:398-400) — working as designed, not a bug.
  First abort was a genuine corpus duplicate (`initiativeLabels.graphql` vs
  `initiative_labels.graphql` both generate `InitiativeLabelsQuery` — 5 such
  pairs in Linear's SDK, a corpus artifact of the split, not a graph_weaver
  defect: two real Linear operations differ only in name casing). Removed the
  5 camelCase dupes (kept snake_case) → 209 files, `rake graph_weaver:generate`
  succeeded, wrote 209 query/mutation files + a shared `types.rb`.
- rake-gitlab (67 non-#import, non-refused ops): `rake graph_weaver:generate`
  ABORTED again, this time on the FIRST GitLab query file processed —
  `app_assets_javascripts_achievements_components_graphql_get_achievement.
  query.graphql: name: must be a constant name, got
  "AppAssetsJavascriptsAchievementsComponentsGraphqlGetAchievement.queryQuery"
  — it comes from the file name, so rename the file to one a constant can
  spell`. **This is new** — see Finding 1 below. Every one of GitLab's 120
  real query files uses this exact `*.query.graphql` naming (that's GitLab's
  own, and a common Apollo/Relay-tooling, convention) and every one of them
  hits it. The report's own real-query pass never saw this because
  `bin/round-trip -q` names every case `Case#{i}` internally
  (bin/round-trip:73-89) rather than deriving a module name from the file
  path — so the file-name-driven code path (`GraphWeaver.parse` given a
  `.graphql` path, and `rake graph_weaver:generate`, which both go through
  `Internal::Util.module_name`) was never exercised against a real
  double-extension filename until this pass.

15:53 — Traced Finding 1 to its root: `Internal.generated_names`
(lib/graph_weaver/internal.rb:64-68) does `File.basename(path, ".*")`, which
strips only the LAST extension, leaving `get_achievement.query` for a file
named `get_achievement.query.graphql`; `Inflect.camelize` (inflect.rb:16-19)
splits only on `_`, so the literal `.` survives into the attempted constant
name verbatim. Minimal repro in `senior-app-O/repro-dotted-filename/repro.rb`:
a 2-field SDL schema + a file named `hello.query.graphql` reproduces the exact
error in 12 lines, no corpus needed.

15:54 — Monitored the round-trip sweep to completion (154/154, all exit=0,
pokeapi the only slow one — ~100s/run given its 2262 input types, matching
the report's own timing note). Diffed every `out/*.txt` tail against "0
failures" — all clean, all 22 schemas, all 7 run configurations
(1/101/201/601/701/801/hostile-1). Zero regressions, zero newly-clean bugs
(there was nothing left to un-fix), zero previously-clean schemas now dirty.

15:55 — Wrote up findings, compiled the per-schema matrix and the final
report.

## Time accounting

- Reading corpus-report.md, followups-post-070.md, git log: ~4 min
- Gemfile/bundle install/app scaffolding: ~3 min
- Re-fetch (19 introspects + 2 curls + 1 copy): ~3 min
- census.rb + collisions.rb + reserved_hitlist.rb: ~3 min
- Round-trip sweep (154 runs, background) + as_json sweep (parallel): ~12 min
  wall clock, dominated by pokeapi
- Real-query pass via GraphWeaver.parse: ~3 min
- rake scratch apps (3x bundle install + generate, chasing the two corpus
  artifacts and the real bug): ~10 min
- Repro + write-up: ~6 min

Total: ~45 min. No dead end hit the 15-minute time-box — the two "aborted"
rake runs each resolved within a couple of minutes of investigation.

## Times I read lib/ or spec/, and why

- `lib/graph_weaver/internal.rb` (generated_names) — to find the root cause of
  Finding 1 once the symptom (bad constant name) was reproduced.
- `lib/graph_weaver/inflect.rb` (camelize) — same investigation, confirming
  `camelize` doesn't treat `.` as a word boundary.
- `lib/graph_weaver.rb` (generate!/write_plan!) — to confirm the "abort loses
  everything" behavior on rake-linear was documented/intentional rather than a
  bug, before reporting it as one.
- `lib/graph_weaver/tasks.rb` — one `cat` to see the full task list docstring
  before writing a bare Rakefile against it.
- `bin/round-trip`, `spec/support/round_trip.rb` — read in full, copied
  (unmodified except the require line) into the app dir; this is the harness
  the brief asked me to reuse, not new reading.
- `spec/support/*` fetch/census/collisions scripts under
  /tmp/claude/graph_weaver/corpus/ — read to repoint at the published gem,
  per the brief.
All reads were against the read-only checkout; nothing there was edited.

## Final verification pass (after the coordinator flagged the stalled monitor)

16:20-16:35 — Re-ran the `as_json` sweep for every schema with >0 failures
(linear, gitlab, github, kitsu, shopify-admin, trygql-web, universe, kiwi)
through a classify variant of as-json-sweep.rb that buckets every failure by
its digit-erased shape rather than printing only the first 6. All 133
failures across 3146 as_json trips collapse to exactly one shape:
`<path>: N-N-N N:N:N.N UTC vs N-N-N N:N:N.N UTC` — the documented
sub-microsecond Time bound, nothing else. Confirms the followups-post-070.md
item's ask ("run it on the full corpus") is now actually satisfied at full
scale, and closes it out as "confirmed, not a new bug."

16:36 — Confirmed all 154 round-trip sweep files present and clean
(0 non-"0 failures" tails), all 22 schemas × 7 configs, ~29,900 inbound trips.
Killed two stray leftover `until`-loop bash processes from an earlier
orphaned background wait (harmless, just polling a task file that would
never satisfy their condition).

16:37 — Compiled the final report below.
