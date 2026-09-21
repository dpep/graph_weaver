# Hunt 7 — the surfaces 0.7.5 and Unreleased changed

Repo: /Users/dpepper/code/lib/ruby/graph_weaver, main at 89ded3e (READ-ONLY for you — modify nothing under it). Toolchain: ~/.rvm/wrappers/ruby-3.4.9/bundle exec … (PATH ruby is 2.6). Build under /tmp/claude/graph_weaver/round7/<your-app-name> (unique to you). Every claim in your report has a runnable repro; every message is quoted verbatim; every "the docs say X" is checked against what happened. Time-box dead ends at ~15 minutes; log and move on. Report; don't fix. Every repro states the exact scope it ran under. Earlier passes: research/logs/ and research/migration-experiment.md in the repo — skim the two nearest yours. Everything they found is fixed or listed in /tmp/claude/graph_weaver/round7/follow-ups.md; don't re-report those. Keep a timestamped log at /tmp/claude/graph_weaver/round7/<your-name>-log.md and put your full report there too (say so at the top of your final message if a write policy blocks it). Final message: a matrix of what you drove × outcome; ranked findings (severity on the ladder publish-blocker / silent wrong answer / quiet where it should speak / paper cut; repro; message verbatim; what a fix would look like; the files it would touch); a design critique from your viewpoint; the times you read source and why; minutes per step; one paragraph on whether you would ship on this.

You are the skeptic who assumes the last two rounds created as many bugs as they
fixed, and proves it. Read-only; commit nothing; use the CHECKOUT at 89ded3e via
`path:` in a scratch Gemfile (Rails app, `rails new`), plus the gem's own tools
(`bin/round-trip` widened past the suite's bounds; `bin/round-trip <sdl> -q <dir>`
with real queries) and every fenced sample in docs/generated_modules.md,
docs/scalars.md (enums), docs/testing.md, docs/migrating.md, docs/getting_started.md §5.

Surfaces that changed most recently (see CHANGELOG.md: v0.7.5 and Unreleased):
- object-fragment hoisting: `{ ...SharedFrag }` → `GraphQLTypes::Frag`; the
  not-hoisted shapes; the abstract-mixin refusal; `alias:` meeting a hoisted struct;
  multi-graph namespaces; the `used_fragment_names` rename
- generated-enum `fallback: true`: `Other`/`Other2`; combined with `alias:`;
  inputs refusing `Other`; the debug line; a schema with OTHER/Other/other
- `register_enum(name, alias:)` and the mapped-enum TO_WIRE fix (0.7.4)
- schema tasks: `Graph#source` rule across refresh/diff/queries:check; a graph
  with client but no url; a hand-maintained SDL; a supergraph; an inherited dump;
  what each prints and exits
- `:wire` per graph; `null_chance:` per field; pin refusals
- `Router` reading context once; `client.check_query` vs `parse`;
  `QueryModule#query_string`/`#operation_name`; the installer's .gitattributes
- `Codegen#object_node`'s restructure (emitted bytes claimed identical — check
  the claim with a schema the fixtures don't have: unions inside interfaces
  inside lists, an interface fragment on an object field, aliases on the abstract arm)

Rank by harm: silent wrong answer, crash, refusal that misdirects, paper cut. A
finding without a runnable repro goes in a separate hunch list, never the ranking.
For each finding name the files a fix would touch.
