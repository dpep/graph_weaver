# Experiment: a join-only scanner for the routing table — integration and speed

Read research/briefs/brief-common.md first (toolchain, gate), then CLAUDE.md's design
section — "refuse rather than guess" and "no spooky action" decide whether this can
ship at all. This is an EXPERIMENT: nothing merges until the owner has read the
report. Deliverable: a memo and an inspectable branch. Commit to your worktree branch;
do not push, do not touch main.

## The question

`SchemaLoader.routing_table(source)` parses the whole supergraph SDL with
`GraphQL.parse` and reads `@join__*` applications off the AST
(`SchemaLoader::RoutingTable`, lib/graph_weaver/schema_loader.rb ~line 1097 on). At
2000 types that is ~590 ms (pure-Ruby parser) / ~350 ms (C parser), almost all of it
parsing things the table never reads: field types, descriptions, arguments. A reader
that only needs the join applications could skip the AST. Prototype it, prove it
equal, measure it, and say honestly whether it can be made exact.

## Prototype

`SchemaLoader::JoinScanner` (or similar) in your worktree: reads supergraph SDL text
and produces the SAME `RoutingTable` — same `subgraphs`, per-type `declared_in`/`keys`,
per-field `Field` structs (`graphs`, `external`, `requires`, `provides`, `override`,
`contextual`, `override_label`), `unsupported` — without `GraphQL.parse`. Read the
existing `RoutingTable` construction first to see exactly what it consumes, including
what `link_namespaces` contributes (a renamed join spec: `@link(url: ".../join/v0.3",
as: "j")` makes the directives `@j__type`; the scanner must honour that or refuse).

Design choices to make and state:
- A real tokenizer (strings with escapes, block strings `"""…"""` that may contain
  `@join__field(` verbatim, `#` comments, nested parens in argument values, multi-line
  directive applications) — or a line/regex scanner with a stated list of inputs it
  refuses. "Refuse rather than guess": the scanner must DETECT the shapes it can't
  read and fall back to the AST path, never silently mis-read. Say how it detects
  them (e.g. a `"""` or a `"` containing `@` anywhere → fall back).
- Field sets inside `@join__field(requires: "…")` are GraphQL selection strings; the
  existing table stores them verbatim — confirm and match.
- Where it hooks in: `routing_table(source)` tries the scanner, falls back to the AST
  on any refusal, and the two must be equal wherever both run.

## Proof of equality

Run both readers over: the three fixture supergraphs (`spec/support/federation/*`),
`bin/bench-load`'s synthesized graphs at 500/2000/8000, every supergraph the hunt-7
fixtures hold (research/logs/hunt7-report.md names them; some may be gone from /tmp —
say which), and adversarial SDL you write: descriptions containing `@join__field(graph:
X)`, a block string with an unbalanced paren, a renamed join spec, fed-1 `@core`
form, a `@join__field` split across lines, unicode. Compare tables field by field
(write `RoutingTable#to_h` in your branch if none exists — note it for the owner). A
difference or a silent misread is the headline finding.

## Speed

`routing_table` old vs new at 500/2000/8000, interleaved, ≥5 reps, medians, both with
the pure-Ruby parser and with `graphql-c_parser` loaded (a scratch bundle at
/tmp/claude/graph_weaver/cparser/Gemfile has it; or add it to your worktree Gemfile)
— the scanner's win is smaller when the baseline is the C parser, and that number is
the one that decides.

## Integration cost

How many lines; what a maintainer has to know (a second reader of the same artifact
is "two definitions that must agree and nothing reads both" — the other-side-of-the-
seam trap); how a future `@join__` directive (federation 2.x adds them) reaches the
scanner; what the fallback log line says.

## Recommendation

Ship / ship behind the C-parser-absent case only / don't ship — with the numbers.
Memo at research/join-scanner-experiment.md on your branch. Ownership: your worktree
only. Base off origin/main at the current head.
