# A join-only scanner for the routing table — built, proved equal, and not worth shipping

Branch `worktree-agent-aba853339e949225a`, off `origin/main` at `ddad21d`.
Prototype commit `9d67756`. Nothing pushed, nothing merged. Harness under
`research/join-scanner/`; every number below was executed, not inspected.

**One sentence: the scanner is exactly correct and buys 1.05x once
`graphql-c_parser` is installed, which on its own buys 1.52x of today's code
for one Gemfile line — so don't ship it, and memoize `check_query`'s routing
table instead, which is 230 ms a call today for a table nothing has
invalidated.**

---

## Measurement conditions — read this before the numbers

This box ran other lanes' benchmarks throughout (load average 10–64, peaking at
64). Wall clock here measures the scheduler, not the code: one 15-rep run gave
`routing_table` at 500 types a median of 351 ms and a minimum of 51.6 ms, a 7x
spread on one configuration. Everything below is therefore

- **CPU time** (`CLOCK_PROCESS_CPUTIME_ID`), which excludes time we are
  descheduled and still counts our own GC;
- **median of ≥9 interleaved reps**, each from a settled heap (`GC.start`);
- **within one process** wherever a comparison is load-bearing —
  `research/join-scanner/bench_matrix.rb` runs both readers under both parsers
  in one process, swapping `GraphQL.default_parser` between reps.

Cross-process absolutes still drift ±30% here, so they are not used to decide
anything. The ratios hold up: across eleven runs over ninety minutes the
scanner's win landed in **1.81–2.05x** on the pure-Ruby parser and
**0.97–1.31x** on the C parser. That spread is wide, and both conclusions
survive either end of it.

---

## 1. Budget

**Nobody stated one, and that is the answer.**

The repo's own fixture supergraph is 6 KB; `routing_table` on it is under a
millisecond — noise. The 2000- and 8000-type graphs everything below is
measured on are `bin/bench-load`'s synthesizer, not anything a user has
produced. No report, issue, or log in this repo names a supergraph that loads
too slowly.

The one place a real cost is demonstrable is *how often* the table is built,
not how fast — see §6. That one has a budget: it should be paid once.

---

## 2. Where the time goes

`routing_table` at 2000 types (814 KB, pure-Ruby parser), CPU ms:

| stage | ms | share |
|---|---|---|
| `GraphQL.parse` | 220 | ~60% |
| post-parse walk | ~90 | ~25% |
| GC, iteration, allocation not attributed above | ~60 | ~15% |
| **total** | **~390** | |

Inside that ~90 ms walk, measured directly on a parsed document (18,050 fields,
13,380 directive applications, `research/join-scanner/bench_ops.rb`):

| operation | ms |
|---|---|
| directive arguments: 11 linear `find`s per application, as `argument()` does | 40–62 |
| `@key` field sets: `GraphQL.parse` per key — 3,000 keys, **1 distinct string** | 22–29 |
| field type signatures via `Printer#to_query_string` | 6–9 |

**The brief's premise is wrong in three places, and one of them matters.**

1. *"almost all of it parsing things the table never reads: field types,
   descriptions, arguments."* Field types **are** read — `RoutingTable#signature`
   stores `field.type.to_query_string` for every field, and `federation.rb`'s
   drift check consumes it. A scanner must therefore print a canonical type
   reference itself. Descriptions and argument *definitions* are genuinely
   skippable, and that is where the scanner's whole remaining edge lives (§4).
2. *"almost all of it parsing."* Parsing is ~60%, not almost all. The ceiling
   for "remove the parse" is therefore ~2.5x, not ~10x — and with the C parser
   it is ~1.5x.
3. **`link_namespaces` contributes nothing.** `RoutingTable` never calls it. It
   hardcodes the `join__` / `link__` / `core__` prefixes, and a renamed join
   spec (`@link(url: ".../join/v0.3", as: "j")`) lands in `unsupported` with
   "this table doesn't follow". The scanner reproduces that by doing nothing
   special, and the adversarial renamed-spec case reads identically
   (`research/join-scanner/corpus.rb`, "adv: renamed join spec").

### My own instrument was the cost

The first phase profile wrapped the reader's private methods with clock calls
and attributed **44.6 ms** to `to_query_string`. Measured on its own, the same
18,050 calls cost **6–9 ms**. The wrapper was five to seven times the thing it
was measuring, and it is why "replace the Printer" looked like a 11% fix and
turns out to be worth nothing (§7). Recorded because the next person to profile
this will reach for the same wrapper.

---

## 3. The prototype

`GraphWeaver::SchemaLoader::JoinSource` — one record shape, two readers:

- **`JoinSource::Defn`** — a definition's kind, name, `@join__*` applications
  (`Applied(name, args)` with graphql-ruby's value mapping: enum → its name,
  input object → a Hash, list → an Array), its fields as
  `Field(name, signature, directives)`, plus a union's members, an object's
  interfaces, an enum's values.
- **`JoinSource::Ast`** parses and projects onto it.
- **`JoinSource::Scan`** lexes the SDL and skips what the table never looks at:
  descriptions, argument definitions, default values, directive definitions.

`RoutingTable` reads only records. **Everything that decides what a `@join__`
directive means stays in one place** — `read_graphs`, `read_abstracts`,
`read_types`, `read_fields`, `note_unknown` are unchanged in substance and now
take records instead of AST nodes. That answers the brief's "how does a future
`@join__` directive reach the scanner": it doesn't need to. The scanner emits
every `@join__*` application generically, arguments and all; a new federation
directive is taught to `RoutingTable` and both readers carry it.

`RoutingTable#to_h` is new (there was none) — the whole table as plain data, so
two readers can be diffed coordinate by coordinate. `RoutingTable#reader`
reports `:scan` or `:ast`. Both are noted for the owner; on a real ship the
whole `JoinSource` layer belongs under `GraphWeaver::Internal` (it added 53
names to `spec/support/public_surface.txt`, which is the surface spec telling
us so).

### Tokenizer, not a line scanner

A description is a string, and a string may hold `@join__field(` verbatim, so
nothing may look for a marker outside the grammar. `Scan` is a real lexer over
`StringScanner`: comments, simple strings with escapes, block strings including
the `\"""` escape, nested parens inside argument values, multi-line directive
applications, unicode.

It reconstructs type references canonically rather than copying source text, so
`a : [  Thing !  ] !` yields `"[Thing!]!"` — the same string
`to_query_string` prints and the same one `to_type_signature` compares against.

### What it refuses, and why those

"Refuse rather than guess" is the whole safety argument, so the refusal set is
deliberately larger than it strictly needs to be. Each returns nil from
`Scan.read`; the caller parses. Messages asserted verbatim in
`spec/join_scanner_spec.rb`:

| refusal | why |
|---|---|
| `an escape sequence in an argument value at line N` | decoding `\n`/`A` exactly as graphql-ruby does is a second decoder to keep in agreement, for a value (a field set) that never contains one |
| `a block string as an argument value at line N` | block-string dedent semantics, same reason. A block string as a *description* is free — it is skipped, never decoded |
| `a type extension at line N` | `extend type Query` **overwrites** the base type's entry in today's table rather than merging (verified: `declared_fields("Query")` returns only the extension's fields). Reproducing a wart is worse than falling back |
| `a null argument value at line N` | `null` is a `NullValue` node in the AST and no plain Ruby value compares equal to it |
| `a variable in SDL at line N` | not legal in a const value; refuse rather than invent |
| `unknown top-level keyword "…"`, `unterminated …`, `expected …` | anything the grammar walk does not recognise |

**A refusal is invisible and safe** — the parser runs, the answer is identical,
only slower. A wrong *read* is the catastrophic case, and §5 is the search for
one.

The fallback logs at debug:

```
routing table: parsing — the join scanner refuses a type extension at line 6
```

Demanding the scanner (`RoutingTable.new(sdl, reader: :scan)`) raises instead:

```
the join scanner refuses this supergraph: a type extension at line 6
```

---

## 4. Speed — the decisive table

Both readers, both parsers, **interleaved in one process**
(`research/join-scanner/bench_matrix.rb`), CPU ms, median of 9–13 reps:

| graph | parser | `:ast` | `:scan` | scanner wins |
|---|---|---|---|---|
| 500 types (206 KB) | pure Ruby | 115 | 59.6 | **1.92x** |
| 500 types | C | 57.9 | 59.8 | **0.97x** |
| 2000 types (814 KB) | pure Ruby | 391 | 216 | **1.81x** |
| 2000 types | C | 211 | 201 | **1.05x** |
| 8000 types (3.2 MB) | pure Ruby | 1173 | 619 | **1.90x** |
| 8000 types | C | 645 | 608 | **1.06x** |
| 2000 + descriptions (2.4 MB) | pure Ruby | 438 | 210 | **2.09x** |
| 2000 + descriptions | C | 223 | 189 | **1.18x** |

And what the C parser buys on its own, same process, same reps:

| graph | `:ast` ruby→C | unmodified `main` ruby→C |
|---|---|---|
| 500 types | 1.98x | 1.67x |
| 2000 types | 1.85x | 1.52x |
| 8000 types | 1.82x | — |
| 2000 + descriptions | 1.96x | — |

**Read the second and fourth rows of the first table.** On the pure-Ruby parser
the scanner is worth ~1.9x, steady across three sizes. Against a C-parser
baseline — the number the brief correctly said decides this — it is **0.97x to
1.06x on a composed graph, and 1.18x on a description-heavy one.** At 500 types
it is slightly *slower* than the parser it replaces.

Marginal cost, 2000 → 8000 types, C parser: `:ast` 211 → 645 (105 ms per 1000
types added), `:scan` 201 → 608 (102 ms per 1000). The two slopes are the same.
The scanner does not scale better; it starts in the same place and stays there.

Descriptions are the scanner's best case and the reason its edge is not zero:
adding 1.6 MB of prose to the 2000-type graph costs `:scan` 12 ms and `:ast`
12 ms under the C parser — but it is 2.4 MB the scanner skips with one regex
per string. That is the entire 1.05x → 1.18x.

---

## 5. Proof of equality

Three independent nets. **No mismatch in any of them.**

**A. The corpus** — `research/join-scanner/equality.rb`, 35 supergraphs:
the 3 checked-in fixtures (`spec/support/federation/*.graphql`), 17 heredocs
harvested from the suite (`federation_router_graph`, `federation_core_graph`,
`federation_split_graph`, `federation_drift_graph`, and the inline SDL in
`schema_loader_spec`, `federation_spec`, `federation_drift_spec`,
`subgraphs_spec`), `bin/bench-load`'s synthesized graphs at 500 and 2000, and
12 adversarial documents written for this: a description containing
`@join__field(graph: GHOST)`, a block string with an unbalanced paren and a
stray brace, an escaped `\"""` inside a block string, a renamed join spec, the
fed-1 `@core` + `@join__owner` form, a `@join__field` split across five lines,
unicode names and prose and comments, nested parens and a list and an input
object in argument values, `contextArguments`, `@interfaceObject` +
progressive `@override(label:)` + `resolvable: false`, unknown `@join__`
directives on the schema / a type / a field, and empty bodies on every type
kind. Plus 3 written to be refused.

Compared three ways per document: the `Defn` records field by field (sharper
than the table, which folds several records into one answer), the full
`to_h`, and my canonical type printer against `to_query_string` for every
field. **32 read identically; 3 refused, all of them the three written to be.**

**B. The suite** — `GRAPH_WEAVER_VERIFY_SCAN=1 bundle exec rspec` makes every
routing table the suite builds read *both* ways and raise on disagreement.
**2,200 examples, 0 failures.**

**C. A generative fuzzer** — `research/join-scanner/fuzz.rb` emits valid but
hostile supergraph SDL: random whitespace, commas, tabs and comments in every
ignorable position; descriptions (simple and block) carrying directive
applications, unbalanced parens, stray braces, escaped quotes, emoji and CJK;
random type-reference nesting printed with hostile spacing; argument
definitions with default values containing `)`; non-join directives with
nested object and list values; unknown `@join__` directives; and — to prove the
refusals fire rather than the scanner guessing — escaped and block-string field
sets and type extensions.

**20,000 documents over three disjoint seed ranges: 8,524 agreed, 0 mismatched,
11,476 refused, 0 that graphql-ruby itself would not parse.** The refusal
breakdown is an artifact of the generator's rates, not of real SDL: no
supergraph in the corpus, and nothing Apollo composes, puts an escape or a
block string in a field set.

**Confidence bound, stated honestly.** Three nets over ~20,000 documents found
no silent misread, and the suite's 2,200 examples agree. That is strong
evidence, not proof: the fuzzer generates from my own grammar model, so a
construct I misunderstand is one neither the scanner nor the generator would
produce. The refusal set is the mitigation — anything the walk does not
recognise falls back rather than guessing — but a construct the scanner reads
*confidently and differently* is exactly what no test here can rule out.

**The hunt-7 supergraphs are gone.** `/tmp/claude/graph_weaver/round7/` still
holds `hunt7-docs`, `hunt7-fake`, `hunt7-objnode`, `hunt7-rails`,
`junior-fragments-app` and `junior-migrate-app`, and **all six directories are
empty** — zero files under the whole tree. The supergraphs the report names
(`hunt7-rails/plain/s6b_gateway/db/supergraph.graphql`, hunt7-export's
RouterGraph graph) are pruned. The 17 harvested heredocs are the substitute;
they are the same documents those runs exercised.

---

## 6. The finding that outranks the experiment

**`Client#check_query` rebuilds the whole routing table on every call.**

`lib/graph_weaver/parsing.rb:59` calls
`Internal::QueryCheck.routing_table_for(dump)`, which reads the supergraph file
and constructs a `RoutingTable` — with no memoization anywhere on the path.

`research/join-scanner/bench_check_query.rb`, 2000-type supergraph, CPU ms:

| calls | total | per call |
|---|---|---|
| 1 | 228 | 228 |
| 2 | 460 | 230 |
| 4 | 1060 | 265 |

and for scale: `routing_table` alone is 230 ms, `File.read` of the same file is
**0.3 ms**. The marginal cost of the tenth `check_query` is the same as the
first, and essentially all of it is a table derived from a file nothing has
touched.

Memoizing by `(path, mtime, size)` takes every call after the first from 230 ms
to ~0.3 ms. That is a larger win than the scanner delivers even on the
pure-Ruby parser, it is roughly five lines, it adds no second reader, and it is
the answer to a question the brief did not ask: *how often is this paid?*

(`check_queries!` in `lib/graph_weaver.rb:651` already builds one table per
graph and reuses it — that path is fine.)

---

## 7. Rejected, with the numbers

Recorded so none of these is proposed again.

| considered | measured | verdict |
|---|---|---|
| **The scanner**, against a C-parser baseline | 0.97x (500), 1.05x (2000), 1.06x (8000), 1.18x (descriptions) | **Rejected.** 602 lines of library for ≤5% on a composed graph |
| **A 5-line canonical type printer** instead of `Printer#to_query_string` | 0.1 ms saved per 18,050 fields — `to_query_string` costs 6–9 ms total | **Rejected.** My first profile said 45 ms; that was the probe wrapper, not the Printer |
| **Pre-hashing directive arguments** instead of 11 linear `find`s per application | 27–42 ms saved in isolation — but building the Hash for every application costs roughly what the lookups saved, and the whole-table difference never rose above the run-to-run noise on this box | **Rejected.** Real in a microbenchmark, unresolvable in the table |
| **Memoizing `parse_field_set` by text** | 22–29 ms of a ~390 ms table (6–7%); 3,000 `@key`s in the 2000-type graph, **1 distinct string** | **Worth taking**, 2 lines, no second reader — but it is 6%, so only alongside a real complaint |
| **A line/regex scanner** instead of a tokenizer | not built | **Rejected on design.** Descriptions are the majority of a real supergraph's bytes and routinely contain `@`, `(`, `{` and `"""`; the refusal list for a regex scanner would have to include "any description containing an at-sign", which refuses nearly every real graph. The tokenizer costs more code and refuses almost nothing |
| **Making `@signatures` lazy** | not measured separately — `to_query_string` is 6–9 ms of ~390 | **Rejected.** Nothing to win |

---

## 8. Integration cost, if someone overrules this

- **602 lines of library** (469 scanner, 93 AST projection, 40 records), 126
  lines of spec, ~80 lines changed in `schema_loader.rb`, 53 new public names
  that want moving under `Internal`.
- **The good half of the seam.** Federation semantics stay single. A new
  `@join__` directive is a `KNOWN` entry and a branch in `read_fields`; the
  scanner needs no change, because it emits applications generically.
- **The bad half.** A second GraphQL *lexer* that must track graphql-ruby's
  grammar forever. That grammar has moved before — block strings, `repeatable`,
  schema extensions, `@specifiedBy` — and each move is a chance for the two
  readers to disagree. A wrong refusal is invisible and harmless. A wrong read
  misroutes a query, and CLAUDE.md is explicit that a silent wrong answer is
  the most expensive outcome this library can produce.
- **What it taxes.** Not the highest-traffic edit — federation directives land
  in one place. It taxes the rarest and most dangerous one: a grammar change,
  noticed by nobody, in a reader that is only exercised when it happens to be
  right.
- **What the C parser taxes instead.** A native extension in the Gemfile, and
  CI building it on three rubies. In exchange it speeds up `SchemaLoader.load`,
  `strip_federation`, and every query parse. The scanner speeds up
  exactly one function. Measured in one process with the C parser at 2000
  types: `SchemaLoader.load` **430 ms**, `routing_table` **168 ms** — and
  `Testing::Router#initialize` pays both. The scanner can touch at most the
  smaller half, and at most 5% of that.

---

## 9. Verdict

**Don't ship the scanner.** It is correct, it refuses rather than guesses, and
it is 1.05x against the baseline that matters.

If a real supergraph is ever too slow, in this order:

1. **Memoize `routing_table_for` by `(path, mtime, size)`** — 230 ms → 0.3 ms
   on every `check_query` after the first. Five lines. Structural: it stops
   paying a cost rather than paying it faster.
2. **Document `gem "graphql-c_parser"`** — 1.52–1.67x on `routing_table` as it
   stands today, and on everything else that parses, including the
   `SchemaLoader.load` beside it that costs 2.6x more.
3. **Memoize `parse_field_set`** — 6–7%, two lines.

Only if a gap remains after all three does the scanner deserve another look,
and it must clear the bar against a C-parser baseline. Today it does not.

**Inside budget.** There is no graph anyone has shown to be too slow.

---

## Appendix — running the harness

    bundle exec ruby research/join-scanner/equality.rb [extra.graphql ...]
    bundle exec ruby research/join-scanner/fuzz.rb 10000 1
    bundle exec ruby research/join-scanner/bench_matrix.rb 500,2000,8000 13 [--describe]
    bundle exec ruby research/join-scanner/bench_ops.rb [--c-parser] 2000 15
    bundle exec ruby research/join-scanner/bench_check_query.rb 2000
    GRAPH_WEAVER_VERIFY_SCAN=1 bundle exec rspec       # 2200 examples, 0 failures
    GRAPH_WEAVER_ROUTING_READER=ast bundle exec rspec  # 1 failure, by design:
    # the one example that asserts an ordinary supergraph scans by default

`bench_matrix.rb` and `--c-parser` need `gem install graphql-c_parser` (found
beside the bundle, not in the Gemfile). `bundle exec rspec`, `srb tc` and
`bin/generate` are green on `9d67756`; `bin/federation-diff` passes.

---

## No CHANGELOG entry

Deliberate. Nothing here is meant to reach a user, and a bullet under
`## Unreleased` describing a reader that should not ship would have to be
deleted by whoever cuts the next release. If the owner takes §6 or §9's second
and third items instead, those earn their own entries with their own numbers.
