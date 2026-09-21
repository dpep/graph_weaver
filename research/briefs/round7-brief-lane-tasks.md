# Lane T — the schema tasks: refresh, diff, queries:check, Graph#source

Read /tmp/claude/graph_weaver/brief-common.md first, then CLAUDE.md's design section, then
the hunt report at /tmp/claude/graph_weaver/round7/hunt7-log.md — findings F1, F2, F8, F11, F16, F17, F18, F23 (search "F1."
etc.), each with a verbatim repro. Repro fixtures: /tmp/claude/graph_weaver/round7/hunt7-rails
(a real Rails 8.1 app plus `plain/` rake shapes m1–m4, q1–q2, s1, s6b_gateway). Reproduce
F1 and F2 yourself before touching code.

## Stance
You own the invariant: "the three schema tasks read one source rule, refuse rather than
guess, never destroy a checked-in artifact silently, and say which graph they are talking
about." Three of these are regressions from the Unreleased block — the standard is the
sentence a user can state without reading the source. If a fix needs a rule with an
exception, say so and stop; if a fix is worse than the status quo, say so and stop.

## Findings, with the lead's lean
- **F1 (publish-blocker)**: `schema:refresh` overwrites a composed supergraph with the
  gateway's API schema and exits 0, because `federation_sdl?` is a substring test that a
  gateway declaring `directive @join__field` satisfies. Lean: the overwrite guard asks
  `routing_table?` (does the content carry join APPLICATIONS), and `refresh` never routes
  a graph whose dump is composed into `refresh!` at all — it says "recompose" and skips
  (tasks.rb `&& !graph.supergraph` is the seam). Spec: a gateway that declares the join
  directives but applies none; the checked-in file is byte-identical after the task.
- **F2 (silent wrong answer)**: `Graph#source = dump_source || client_url` is nil for a
  graph whose client is a schema class (`client "DemoSchema"`), so `queries:check` says
  "as committed" and `refresh` says "the graph names no client" while `schema:diff` reaches
  the class through `source_transport`. Lean: `source` falls back to the client OBJECT
  (a Module counts as a source; a url'd client too), and `source_transport` derives from
  it — one function, three callers, the refusal text written against the same idea.
- **F8**: `refresh` aborts the loop at the first failing graph; move the rescue inside so
  every graph is attempted, print per graph, exit non-zero at the end if any failed.
- **F11**: `schema:diff` aborts before the loop when no graph has a dump, so a single
  live-class graph is refused naming a path it never mentions, while the same graph passes
  when an unrelated graph has a dump. One rule per graph, no cross-graph dependence.
- **F16**: `diff` aborts (1) on the no-provenance-no-client shape `refresh` skips (0).
  Decide one behaviour for both and say why; lean: both say the same sentence, `diff`
  still exits 1 (it asserts; it can't assert nothing) — but the sentence must be the same.
- **F17**: `client -> { … }` accepted, then a rake backtrace. Refuse at declaration.
- **F18**: `queries:check` on an unreachable server prints only the socket error; name the
  graph and the dump, and go on to the next graph.
- **F23**: a hand-maintained dump whose DESCRIPTIONS differ is permanently "is stale" with
  advice to `refresh` (now destructive for it). Lean: `diff` ignores description-only
  changes the way it ignores ordering — or names them as non-breaking without "stale".
  Judge it; report what you chose.

## Ownership
`lib/graph_weaver/tasks.rb`, `lib/graph_weaver/graph.rb`, `lib/graph_weaver/schema_loader.rb`,
`lib/graph_weaver/schema_diff.rb`, the check_queries region of `lib/graph_weaver.rb`, their
specs, `docs/getting_started.md` §5 and "More than one schema" sentences that state these
rules, and ONE contiguous CHANGELOG block under `## Unreleased` (after the existing
bullets; the Unreleased entry for `queries:check` and `schema:refresh` should be CORRECTED
in place rather than contradicted by a new bullet — those bullets are unpublished). Other
lanes: U (internal/unused.rb, install_generator.rb, gemspec), C (codegen.rb, codegen/*,
input_struct.rb, generation_plan in graph_weaver.rb), F (testing/*, rspec.rb,
internal/test_clients.rb, internal/overrides.rb, client.rb, in_process.rb), and the
running event lane (logging.rb, query_module.rb, emit.rb, railtie.rb, docs/logging.md).
Stay out of all of them. Base off origin/main at 94d1999.

## Report
Per finding: repro before/after verbatim, the rule in one sentence, sha. Skipped items with why.
