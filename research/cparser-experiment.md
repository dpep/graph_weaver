# graphql-c_parser under graph_weaver — an experiment

Run 2026-09-29 against `ddad21d`, graphql 2.6.10, graphql-c_parser 1.1.4,
Ruby 3.4.9, macOS.

**Since written:** F1 is fixed — `operation_offset` lexes rather than reading a
reported column — and the docs recommendation this memo argues against is gone.
F2 through F8 are upstream and stand as found.

**Recommendation: (d) — don't recommend it, and delete the recommendation the
docs already make.** `docs/getting_started.md:474` currently tells apps to add
`gem "graphql-c_parser"`. Following that advice breaks `rake
graph_weaver:generate` for the *ordinary* query file — an anonymous operation
in a file containing any non-ASCII byte, or any file with CRLF line endings —
and makes the gem unable to read schema dumps that graph_weaver's own
`schema:refresh` writes. The speedup is real (parse ≈2.2× faster,
`SchemaLoader.load` 15–50% faster) and costs ~17% more memory, but it is not
worth either of those two.

## How the experiment was driven

`bundle exec` does **not** auto-require a Gemfile gem — verified: with
`gem "graphql-c_parser"` in the Gemfile and `bundle install` run,
`GraphQL.default_parser` under `bundle exec ruby` is still
`GraphQL::Language::Parser`. Only `Bundler.require` loads it, which in practice
means Rails (`config/application.rb`). So "every load here picks up
automatically" is true for a Rails app and false for a plain Ruby script, a
Rake-less CLI, or the gem's own suite.

To reproduce: add `gem "graphql-c_parser"` to the Gemfile, `bundle install`,
then

    RUBYOPT="-rgraphql-c_parser" bundle exec rspec

which is what `Bundler.require` amounts to. The Gemfile change is reverted on
this branch — a line that does nothing under `bundle exec` is worse than no
line.

---

## Function

### F1 — codegen refuses to name an anonymous operation (blocker)

`Codegen#operation_offset` (codegen.rb:469) computes a character offset as

    @query.lines.first(operation.line - 1).sum(&:length) + operation.col - 1

and then treats the result as a *byte* count. That is correct only because
graphql-ruby's Ruby parser reports a `col` that is a byte position minus a
**character** line start (`Language::Parser#column_at`) — the comment above the
method says so. The C parser reports a true character column, so the
compensation over-shoots by the number of extra bytes in any multibyte
character before the operation.

    # who — everyone
    { people { name } }

| parser | operation line | col |
|---|---|---|
| `GraphQL::Language::Parser` | 2 | 3 |
| `GraphQL::CParser` | 2 | 1 |

`declares!` catches the bad splice and refuses — no silent wrong answer, which
is the design working — but what the user sees is:

```
queries/people.graphql: could not name the anonymous operation — the document GraphWeaver would send does not declare "PeopleQuery". Name the operation in the query itself (`query PeopleQuery { ... }`) and please report this as a bug.
```

Triggers, all confirmed end to end through `Codegen.generate` against
`Demo::Schema`:

| query file | ruby parser | C parser |
|---|---|---|
| `# who\n{ people { name } }` | OK | OK |
| `# who — everyone\n{ people { name } }` | OK | **refuses** |
| `# naïve\n{ people { name } }` | OK | **refuses** |
| `# who\r\n{ people { name } }` (CRLF) | OK | **refuses** |
| `# who — everyone\nquery Existing { ... }` | OK | OK |

This is the default path, not a corner: seven of the eight `.graphql` files in
`spec/queries` and `examples/github/queries` are anonymous operations, because
naming them from the filename is the convention the docs teach. Any comment
containing an em dash, a curly apostrophe, an arrow, or an accented name trips
it, and so does every file in a repo that normalises to CRLF.

`spec/codegen_spec.rb` already pins this: "declares the name in the document it
emits (after a comment with an em dash)" fails under the C parser. It was
written for exactly this hazard.

A fix has to stop depending on `col`'s byte/character semantics *and* on `line`
(which the C parser also gets wrong for CRLF — see F5), so it is not a
one-liner. Not attempted here; it is the gate on ever recommending the C parser.

### F2 — the C lexer rejects spec-legal floats, including ones graphql-ruby prints (blocker)

`FloatValue ::= IntegerPart ExponentPart` is legal GraphQL. The C lexer splits
it into two tokens:

    { f(a: 1e5, b: 1.0e5) }

    ruby:  [:FLOAT, 1, 8, "1e5"]
    c:     [:INT, 1, 8, "1"]  [:IDENTIFIER, 1, 9, "e5"]

Rejected: `1e5`, `1E5`, `0e0`, `123e4`, `1e100`, `1e-9`, `1e+100`. Accepted:
`1.0e100`, `1.5E-3`, `3.4e+38` — anything with a fractional part.

Reached through the public surface:

```ruby
client.check_query("query Q($n: Float = 1e5) { people { name } }")
# ruby: [{"message" => "Float isn't a defined input type (on $n)", ...}]   # schema has no Float
# c:    [{"message" => "syntax error, unexpected IDENTIFIER (\"e5\"), expecting RPAREN or VAR_SIGN at [1, 22]", ...}]
```

The sharp edge is that **graphql-ruby prints floats in the form its own C
parser cannot read**. `Schema#to_definition` — which is what
`rake graph_weaver:schema:refresh` writes to the dump — emits exponent notation
with no fractional part once a value is large or small enough:

| SDL default | printed as | C parser re-reads it? |
|---|---|---|
| `1.0` | `1.0` | yes |
| `1e-5` | `0.00001` | yes |
| `3.4e38` | `3.4e+38` | yes |
| `1e15` | `1e+15` | **no** |
| `1e100` | `1e+100` | **no** |
| `1e-10` | `1e-10` | **no** |
| `-1e20` | `-1e+20` | **no** |

So a schema with a `Float` default at or beyond ~1e15, or below ~1e-4, produces
a `db/schema.graphql` that the C parser cannot load — written by this gem, on
the documented path, unreadable by the parser the docs recommend.

Upstream: fixed but unreleased.
[PR #5719](https://github.com/rmosolgo/graphql-ruby/pull/5719) (merged
2026-08-29, shipped in graphql-ruby **2.6.11**) rewrote the Ragel rule from
`FLOAT = INT ('.'[0-9]+) (…)?` — where the `.` is mandatory — to
`FLOAT = INT ('.'[0-9]+ EXPONENT? | EXPONENT)`. But graphql-c_parser is
versioned separately, `version.rb` on master still reads `1.1.4`, and 1.1.4 was
cut 2026-08-03, before the merge. Verified: graphql 2.6.11 plus
graphql-c_parser 1.1.4 still rejects `1e5`. **There is no installable
combination with the fix**; it wants a 1.1.5 that has not been cut.

### F3 — the C parser rejects a described `schema` definition

    """d"""
    schema { query: Query }

    c: syntax error, unexpected SCHEMA ("schema") at [2, 1]

Legal per spec (`SchemaDefinition ::= Description? schema …`), and accepted by
the Ruby parser. Every other described definition (type, interface, union,
enum, input, scalar, directive) parses fine. Composed supergraphs open with
`schema @link(...)`; one that carries a description is unloadable.

Cause, in `graphql-c_parser/ext/graphql_c_parser_ext/parser.y`: every other
definition rule is prefixed `description_opt`; `schema_definition` alone is
`SCHEMA directives_list_opt operation_type_definition_list_opt`. No upstream
issue filed — one-line grammar change with clear precedent in the same file.

### F4 — the C parser silently accepts a NUL byte

A query carrying a literal NUL byte is `Expected NAME, actual: UNKNOWN_CHAR
("\u0000") at [1, 4]` under the Ruby parser and parses clean under the C
parser. Garbage in, no complaint.

### F5 — CRLF sources get every line number doubled

The C parser counts `\r` and `\n` as separate line breaks.

    query Q {\r\n  a\r\n  b\r\n  c\r\n}\r\n

| field | ruby | c |
|---|---|---|
| `a` | line 2 | line 3 |
| `b` | line 3 | line 5 |
| `c` | line 4 | line 7 |

Parse errors inherit it: a syntax error on line 3 of a CRLF file is reported at
`[5, 4]`. Every `file:line:col` graph_weaver prints for a CRLF query file is
wrong, and F1's refusal is a downstream consequence.

Cause, in `lexer.rl`: `NEWLINE = [\c\r\n];` is a *character class* whose action
increments `meta->line`, so `\r\n` matches twice. The Ruby lexer counts
`"\n"` occurrences only. No upstream issue filed.

### F6 — every parse-error message is reworded; positions are identical

Seventeen inputs through both parsers, sixteen rejected by both: **every line
and column matched, in all sixteen**, and every message differed. A
representative slice (raw `GraphQL.parse`; `check_query` and the rake task
surface these strings verbatim):

| input | ruby | c |
|---|---|---|
| `{ media {{ id } }` | `Expected NAME, actual: LCURLY ("{") at [1, 10]` | `syntax error, unexpected LCURLY ("{") at [1, 10]` |
| `query Q { people { name }` | `Expected NAME, not end of file at [1, 25]` | `syntax error, unexpected end of file at [1, 25]` |
| `{ pe-ople { name } }` | `Expected type 'number', but it was malformed: "-ople".` | `syntax error, unexpected invalid token ("-") at [1, 5]` |
| `{ search(term: "abc) { id } }` | `Expected string or block string, but it was malformed` | `syntax error, unexpected invalid token ("\"") at [1, 16]` |
| `quory Q { a }` | `Expected one of SCHEMA, SCALAR, TYPE, ENUM, INPUT, UNION, INTERFACE, actual: IDENTIFIER ("quory") at [1, 1]` | `syntax error, unexpected IDENTIFIER ("quory") at [1, 1]` |
| `""` | `Unexpected end of document` | `syntax error, unexpected end of file` |
| `{ a(b: "\uZZZZ") }` | `Bad unicode escape in "\uZZZZ"` | `Parse error on bad Unicode escape sequence: "\uZZZZ" (error) at [1, 8]` |

The C wording is flatter — it names the token it hit but not what it wanted
(except where bison happens to say `expecting X`). The Ruby wording names both.
For a tool whose job is to tell you which line of which query file is wrong,
that is a downgrade, not a wash.

Two specs pin the Ruby wording and fail under the C parser —
`spec/schema_check_spec.rb:60` and `:290`. Both are category (c): a spec that
pinned the Ruby parser's phrasing, not a behaviour bug. They are the only two
of the three failures that a docs sentence could cover.

The rake line becomes:

    1:16  Expected NAME, actual: LCURLY ("{") at [1, 16]     # ruby
    1:16  syntax error, unexpected LCURLY ("{") at [1, 16]    # c

### F7 — a described definition anchors at a different node

The Ruby parser positions a described definition at its **description**; the C
parser positions it at the keyword. Over the repo's 29 `.graphql` files, 26
compared byte-identical AST-for-AST and 3 differed on exactly this — the
`link__Purpose` enum values in the three fixture supergraphs:

    $.link__Purpose[15].SECURITY[0]@pos: [64,3] vs [67,3]

`to_query_string` is identical either way, and graph_weaver reports no SDL
positions, so this is cosmetic here. It is real for anything that maps a schema
back to source. (Cause: the Ruby parser captures `loc = pos` *before* reading
the description; the C grammar takes line and col from the keyword token.)

### F8 — the Ruby parser's leniency is gone (C is the correct one)

| input | ruby | c |
|---|---|---|
| `{ a { } }` | accepts | rejects |
| `input A { }` | accepts | rejects |
| `enum E { }` | accepts | rejects |
| `type A { }` | accepts | accepts |
| `{ }` | accepts | accepts |

The C parser is right per spec; the Ruby parser is inconsistently lenient. Still
a behaviour change for anyone whose hand-written SDL has an empty body.

### What did NOT change

- `bin/generate` — byte-identical output both ways, tree clean both ways.
- `bin/round-trip -c 2000` — 11,650 round trips, 0 failures; same per-schema
  counts as the baseline.
- `bin/round-trip -q spec/support/federation/queries` — 1,524 round trips, 0
  failures, counts identical to the baseline line for line.
- `bin/federation-diff` — passes.
- `bundle exec srb tc` — no errors.
- Block strings with escapes, `\u` inside block strings, string escape
  sequences, comments between definitions, `extend schema`, `extend type`,
  `@oneOf`, `repeatable` directives, variable directives, operation directives,
  default values (including `null`), trailing commas, 200-deep nesting, a
  5,000-element list literal, a 10,000-character field name: all AST-identical.
- A 10 MB / 26,015-definition SDL parses under both, same definition count — no
  size or token limit. `max_tokens:` is honoured identically ("This query is too
  large to execute."), as is `filename:` propagation and `parse(nil)`.
- `GraphQL.scan` is broken on `GraphQL::CParser` (no `.scan`), but graph_weaver
  never calls it.

### Suite

`RUBYOPT="-rgraphql-c_parser" bundle exec rspec`, default order plus
`--order rand:1` and `--order rand:7331`: **2189 examples, 3 failures**, the same
three every time. Baseline is 2189 / 0.

| failure | class |
|---|---|
| `codegen_spec.rb` "…(after a comment with an em dash)" | **(b) behaviour** — F1 |
| `schema_check_spec.rb:60` "keeps the position out of an unparseable query's message" | (c) pinned wording — F6 |
| `schema_check_spec.rb:290` "reports an unparseable query rather than raising" | (c) pinned wording — F6 |

No spec was changed.

---

## Speed

Measured on a busy box — load average moved between 10 and 38 during the
session, which is three other lanes, not this one. Wall clock on that box is
useless: a first pass had `build schema` at 1.40× and a repeat at 1.83×, both
noise. Everything below is **process CPU time**, which other load does not
perturb, medians of 7 reps, arms alternated per rep (`ruby` first on even reps,
`c` first on odd), **a fresh process per arm per rep** — which is also the
condition a boot-time load actually starts in. Two full runs, both reported, so
the spread is visible.

| types | stage | ruby (ms) | c (ms) | c/ruby |
|---|---|---|---|---|
| 500 | `GraphQL.parse` | 96.7 / 109 | 42.7 / 46.1 | 0.44× / 0.42× |
| | `build schema` | 84.2 / 108 | 112 / 150 | 1.33× / 1.39× |
| | `SchemaLoader.load` | 228 / 254 | 117 / 162 | 0.51× / 0.64× |
| | `routing_table` | 141 / 171 | 75.5 / 94.5 | 0.54× / 0.55× |
| | peak RSS | 91 MB | 107 MB | 1.17× |
| 2000 | `GraphQL.parse` | 376 / 351 | 173 / 160 | 0.46× / 0.46× |
| | `build schema` | 432 / 404 | 467 / 421 | 1.08× / 1.04× |
| | `SchemaLoader.load` | 829 / 747 | 679 / 650 | 0.82× / 0.87× |
| | `routing_table` | 649 / 626 | 422 / 426 | 0.65× / 0.68× |
| | peak RSS | 175 MB | 207 MB | 1.18× |
| 8000 | `GraphQL.parse` | 1005 / 1055 | 476 / 456 | 0.47× / 0.43× |
| | `build schema` | 1498 / 1265 | 1396 / 1291 | 0.93× / 1.02× |
| | `SchemaLoader.load` | 3491 / 2641 | 1866 / 1703 | 0.53× / 0.65× |
| | `routing_table` | 1841 / 1672 | 1353 / 1186 | 0.73× / 0.71× |
| | peak RSS | 550 MB | 640 MB | 1.16× |

Reading it:

- **`GraphQL.parse` is 2.1–2.4× faster**, flat across three orders of magnitude.
  Warm and in-process it reaches 2.7× (0.36–0.37×); a fresh process pays for the
  extension's first parse, and a fresh process is the case that matters.
- **`SchemaLoader.load` is 15–50% faster**, `routing_table` 27–46% faster.
- **`build schema` is parser-independent work and shows no gain** — 0.93–1.39×,
  and *consistently worse* at 500 types across both runs. I have no mechanism
  for that; identifier strings are not interned by either parser, and the C arm's
  total GC time at 500 types is *lower* (82 ms vs 129 ms). Reported as measured.
- **Memory is the reliable cost.** +16–18% peak RSS for a full load, at all three
  sizes, measured twice and corroborated by `/usr/bin/time -l` on a standalone
  8000-type load (342 MB → 413 MB, +21%). For a **parse-only** workload it is far
  worse: the 10 MB SDL parses in 1829 ms vs 3464 ms but at **567 MB vs 277 MB —
  2.05×**. The C lexer materialises the whole token array before parsing; the
  Ruby lexer streams. That matters here, where `bin/round-trip -c 1000` on
  PokeAPI has already been killed at 6 GB.

### The docs' current numbers

`docs/getting_started.md:477` claims "~3× faster parsing; a 2000-type supergraph
loads in three quarters of the time and its routing table in half". Measured:
parse 2.1–2.4× (2.7× warm), load 0.82–0.87× (not 0.75×), routing table
0.65–0.68× (not 0.50×). Optimistic on all three, and silent about the +17%
memory.

---

## Install story

- Source-only. All fourteen published versions are platform `ruby`; there are no
  precompiled native gems, so every `bundle install` on every machine and every
  CI ruby compiles it. A clean build here took **~10 s**, which is fine for CI
  with `bundler-cache: true`, and is a hard failure anywhere without a compiler.
  Ragel and Bison are *not* needed — the generated `.c` is vendored and the
  `.y`/`.rl` sources are deliberately excluded from the package.
- `required_ruby_version >= 3.0.0`; 1.1.4 released 2026-08-03. It builds and runs
  on Ruby 3.4.9 here. **Ruby 3.3 and Ruby 4 are unverified locally** — only a
  3.4.9 wrapper exists on this box, and CI's matrix is `[4, 3.4, 3.3]`.
  graphql-ruby's own CI does run `rake compile` on a `ruby: 4.0` leg, so the
  extension builds there; but the only job that sets `GRAPHQL_CPARSER=1` and
  therefore actually runs a suite *through* the C parser is pinned to Ruby 3.3.
  Build coverage on 4.0, not behavioural coverage.
- Its graphql constraint is loose: `graphql >= 2.2.10`. No resolution conflict
  with the gem's `graphql >= 2.6.7`, but it also means the C grammar is a
  *snapshot* — a language feature graphql-ruby adds is not automatically
  understood by whatever c_parser version resolves. F2 is that coupling made
  visible: the fix is on master and in graphql-ruby 2.6.11, and still
  uninstallable because the parser gem has not been re-cut.
- Upstream documents none of this. The whole
  [C parser guide](https://graphql-ruby.org/language_tools/c_parser.html) is
  about twenty lines, calls the gem "a drop-in replacement for the built-in
  parser", and carries no caveat about wording, positions, or leniency.

---

## Recommendation

**(d) don't recommend it**, and remove the recommendation from
`docs/getting_started.md:474-480`.

What decides it, in order:

1. **F1.** The documented opt-in breaks the documented query-file convention.
   An anonymous operation is what the docs tell you to write; an em dash in a
   comment or a CRLF checkout then makes `rake graph_weaver:generate` refuse with
   a message that tells the user to file a bug. That is shipping a trap.
2. **F2.** graph_weaver writes schema dumps the C parser cannot read back. A
   `schema:refresh` today, a `generate` tomorrow, and the second one fails on a
   file the first one produced. Fixed on master, unreleased, and not fixable by
   pinning — there is no installable version that has it.
3. **F3/F4/F5.** Spec-legal input rejected, invalid input accepted, and wrong
   line numbers on CRLF. Three upstream defects in the thing being recommended,
   two of them (F3, F5) unreported.
4. The gain does not buy them off. A 2.2× on the parse stage comes out as
   15–50% off `SchemaLoader.load`, on a path a production boot never takes —
   "a large dump costs nothing until something asks for it", as the same docs
   page says two paragraphs earlier. Generation-time and boot-time seconds, for
   +17% resident memory and the four defects above.

Not (b): adding it to the gem's own dev bundle would put CI three specs red and
would run the gem's suite against a parser that rejects spec-legal GraphQL.
Not (c): a runtime dependency on a source-only C extension, for this, is
indefensible.

**If it is ever recommended again**, the gate is F1 — `operation_offset` must
stop reading `col` (and `line`, for CRLF) as anything the parser guarantees —
and the docs sentence has to say all of:

> Parse-error wording differs: graphql-ruby's C parser says `syntax error,
> unexpected LCURLY ("{") at [1, 10]` where the Ruby parser says
> `Expected NAME, actual: LCURLY ("{") at [1, 10]`. Line and column are the
> same. It also rejects floats written as `1e5` (write `1.0e5`), and uses about
> 17% more memory.

That sentence is three caveats long, which is itself the signal: a knob whose
documentation needs three exceptions is the shape CLAUDE.md says to delete
rather than explain.

Two things worth doing regardless of the C parser:

- **F1 names a latent bug in this gem.** `operation_offset` is correct only
  because graphql-ruby's Ruby parser reports a broken column. The C parser is
  the one that is right. If graphql-ruby ever fixes `Language::Parser#column_at`
  — and it is a bug, not a contract — codegen breaks on exactly the inputs in
  F1's table with no C parser anywhere in the bundle. The compensation should go
  whether or not anyone ever opts in.
- **F3 and F5 are one-line upstream fixes with clear in-file precedent** and no
  ticket. Cheap to file; they are the difference between "a drop-in replacement"
  being true and being marketing.

---

## Reproducing

    # F1
    require "graphql-c_parser"
    GraphWeaver::Codegen.generate(schema: Demo::Schema, name: "PeopleQuery",
      query: "# who — everyone\n{ people { name } }\n", path: "q.graphql")

    # F2
    GraphQL::CParser.parse("{ f(a: 1e5) }")
    GraphQL::Schema.from_definition("type Query { c(h: Float = 1e100): Float }").to_definition
    # => "type Query {\n  c(h: Float = 1e+100): Float\n}\n"   which CParser cannot parse

    # F5
    GraphQL::CParser.parse("query Q {\r\n  a\r\n}\r\n").definitions.first.selections.first.line  # => 3

The AST comparator used for the corpus and edge sweeps parses one source with
both `GraphQL::Language::Parser` and `GraphQL::CParser` in the same process and
walks `#scalars`, `description`, `comment`, `line`/`col` and `#children` in
lockstep. It lives only in this session's scratch; it is ~90 lines and cheaper
to rewrite than to maintain.
