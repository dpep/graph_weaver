# Experiment: graphql-c_parser under graph_weaver — function and speed

Read research/briefs/brief-common.md first (toolchain, gate), then CLAUDE.md's design
section. This is an EXPERIMENT: nothing you produce is merged until the owner has read
the report. Deliverable: a memo, plus a branch the owner can inspect. Commit to your
worktree branch freely; do not push, do not touch main.

## Stance

You are the skeptic of a "free" speedup. graphql-ruby's official C parser
(`graphql-c_parser`, Ragel + Bison) sets `GraphQL.default_parser` when required, and
Bundler's auto-require does that from a Gemfile line. A quick bench showed
`GraphQL.parse` 263 → 92 ms and `SchemaLoader.load` 738 → 544 ms on a 2000-type
synthesized supergraph. Your job: find where it is NOT equivalent, and measure the
speed properly.

## Function — the part that matters more

The gem quotes parser output in three places and the suite pins it: parse-error
messages and positions (`check_query`, `QueryValidationError`, the rake tasks'
"unparseable" entries — e.g. `Expected NAME, actual: LCURLY ("{") at [1, 10]`),
AST node positions used by aliases/hoisting refusals, and everything codegen reads
off the AST (descriptions, directives, default values, comments?). With the C parser
loaded:

1. Run the FULL suite (`bundle exec rspec`, plus two random seeds) with the gem in the
   bundle — add `graphql-c_parser` to the repo's Gemfile in your worktree under the
   development group (that alone auto-requires it under `bundle exec`; confirm
   `GraphQL.default_parser` is `GraphQL::CParser` from inside a spec). Every failure is
   a finding: classify each as (a) a message/position difference the C parser produces
   (quote both), (b) a behaviour difference (AST shape), or (c) a spec that pinned the
   Ruby parser's wording. Do NOT change specs to pass — report.
2. Byte-identity of generated code: `bin/generate` with and without the C parser (tree
   clean both ways?), and generate over the corpus dumps / the hunt-7 witness approach
   (research/logs/hunt7-report.md describes it) — diff.
3. `bin/round-trip -c 2000` and `-q spec/support/federation/queries` with it loaded.
4. `check_query` and the `unparseable` rake-task entries on a handful of broken
   queries: message and line/column, both parsers, side by side.
5. Edge inputs both parsers should agree on: block strings with escapes, unicode in
   descriptions, `#` comments between definitions, a 0-byte file, a file with only
   comments, `extend schema`, `@oneOf`, `repeatable` directives, variables with
   directives, a 10 MB SDL (does the C parser have a size/token limit? `max_tokens`?).
6. Memory: peak RSS for a load at 8000 types, both parsers (`/usr/bin/time -l`).
7. Install story: does the gem build on the CI matrix (Ruby 3.3/3.4/4)? Check its
   released versions' compatibility notes; run the suite under Ruby 4 if the wrapper
   exists (`ls ~/.rvm/wrappers/`). A C extension that fails to build is a
   worse-than-nothing recommendation.

## Speed — properly

`bin/bench-load` at 500/2000/8000 with and without, interleaved (alternate arms per
rep, GC.start between), medians of ≥5 reps, on as quiet a box as you can get
(check `uptime` load; say what it was). Report `GraphQL.parse`, `build schema`,
`load`, `routing_table`.

## Recommendation

One of: (a) recommend to apps as a Gemfile opt-in (as the docs now do) — with the
list of message differences a user would see; (b) add it to the gem's own dev bundle
so CI and the bench run with it; (c) make it a runtime dependency; (d) don't
recommend it. Say which findings decide it. If (a) or (b): what the docs sentence must
say about the wording differences, if any.

## Output

Memo at research/cparser-experiment.md on your branch (commit it there; the owner
merges nothing until discussed). Ownership: your worktree only. Base off origin/main
at the current head.
