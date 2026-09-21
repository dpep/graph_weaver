# Lane F — the testing harness: inert options, misdirecting refusals

Read /tmp/claude/graph_weaver/brief-common.md first, then CLAUDE.md's design section, then
/tmp/claude/graph_weaver/round7/hunt7-log.md findings F6, F7, F9, F10, F13, F20, F22, F24, and the Tier-4 items about pins beating
`null_chance:`, the `"default"` key, and `check_scalars!`'s two identical inspects.
Fixtures: /tmp/claude/graph_weaver/round7/hunt7-fake (specs), hunt7-app/wire (wire2_spec).

## Stance
"Refuse rather than guess" applies to OUTCOMES, not just arguments: an option that is
well-formed and does nothing must be refused the way a malformed one is. A refusal must
name a fix reachable from the branch that raised it. If a fix needs a rule with an
exception, say so and stop.

## Findings
- **F6**: an `"Interface.field"` coordinate is accepted and inert for pins, `list_size:`
  and `null_chance:`. Apply the abstract-type refusal (`pinnable!`) to the coordinate form.
- **F7**: the plain-number form of `null_chance:`/`list_size:` isn't validated (7, -1,
  NaN, a String). Validate both forms with the same value rule.
- **F24**: `null_chance:` on a non-null field is accepted and inert; refuse naming the
  field as non-null. And `"Person" => 1.0` refused with "did you mean 'person'" — a
  type key should null the whole subtree or be refused as a type; decide, one rule.
- **F9**: docs/testing.md:673 calls `GraphWeaver.client.check_query` inside an example,
  where the client is a FakeClient/InProcess/Router — NoMethodError. Give every client
  that holds a schema the method (the `Parsing` mixin already requires `schema` — that
  may be its home) so the doc is true. `in_process.rb`: the event lane may touch its
  instrument call; keep your change to the mixin include if possible and report.
- **F10**: the `:in_process` refusal names `graphql_in_process(MySchema)` "in the
  example", which can't run on the tag's before-hook path. Say what works on that path.
- **F13**: an above-the-wire graph with nothing to serve inherits the served graph's
  refusal (endpoint/stub/URL= sentences all false for it). Branch in `wire_mode` on
  `client_url`; the fix that applies is "give the graph a `schema`".
- **F20**: `check_scalars!`'s refusal still says `overrides: { "Money" => … }` and takes
  one positional argument; and the three-door message reached through it leads with
  `graphql_fake`, a no-op there. Say the door that works for `check_scalars!`.
- **F22**: `graphql_context` refuses on an untagged example whose `GraphWeaver.client` is
  an `InProcess` — the guard reads the tag, not the mode. Read the mode.
- Tier 4: a pin beats `null_chance:` on the same field (document); `"default"` as a
  `null_chance:` key always means the fallback (document the coordinate form for a field
  named default); `check_scalars!` "round-trips lossily" with two identical inspects when
  the class lacks `==` — say that's why.
- Also from the junior: a `:wire`/`:in_process` refusal raised in the tag's before-hook
  can't be asserted with `expect { }.to raise_error` in the example — if there's a way
  (an `around`, a helper), document it in testing.md; if not, say so there.

## Ownership
`lib/graph_weaver/testing.rb`, `lib/graph_weaver/testing/*.rb`, `lib/graph_weaver/rspec.rb`,
`lib/graph_weaver/internal/test_clients.rb`, `lib/graph_weaver/internal/overrides.rb`,
`lib/graph_weaver/internal/values.rb`, `lib/graph_weaver/parsing.rb`, `lib/graph_weaver/client.rb`,
`in_process.rb` (mixin include only — report anything more), their specs, `docs/testing.md`
and the `check_scalars!` section of `docs/scalars.md`, and ONE contiguous CHANGELOG block
under `## Unreleased` (correct the existing `null_chance:` and pin-refusal bullets in place).
Other lanes own tasks/graph/loader (T), unused/installer/gemspec (U), codegen/enums/
input_struct (C), logging/query_module/emit/railtie (event). Base off origin/main at 94d1999.

## Report
Per finding: before/after verbatim, rule in one sentence, sha; what you declined and why.
