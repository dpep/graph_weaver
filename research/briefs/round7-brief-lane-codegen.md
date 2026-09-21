# Lane C — hoisting collisions, the degenerate abstract shapes, and enum refusals

Read /tmp/claude/graph_weaver/brief-common.md first, then CLAUDE.md's design section
(especially "one rule beats a rule with exceptions" and "refuse rather than guess"), then
/tmp/claude/graph_weaver/round7/hunt7-log.md findings F3, F12, F14, F15, F19 and the "Hunch" about `optional: true`. Fixtures:
/tmp/claude/graph_weaver/round7/hunt7-app (p1, p4, p7, p8, p8b, p10 via `probe/gen.rb DIR`).

## Stance
You own the invariant: "a whole field selected as exactly one named shared fragment is one
type in GraphQLTypes, named for the fragment — and where that can't hold, generation says
so, naming the query." If a fix needs a rule with an exception, say so and stop; if the
fix is worse than the status quo, say so and stop.

## Findings
- **F3 (silent wrong answer)**: two shared fragments whose names camelize to one class
  (`petFields` / `PetFields`) silently merge — one types/pet_fields.rb survives, both
  fields alias it, and a selected field disappears from `from_h`. `check_shared_collisions!`
  compares hoisted names against enums and inputs, never against each other. Refuse,
  naming both fragments and the class, at generation.
- **F12 (rule with undocumented exceptions)**: an interface fragment with only
  interface-level fields (`fragment NodeFields on Node { id label }`) and a union fragment
  narrowing to one member are NOT hoisted, because `abstract_field` tries the
  abstract-level-only and single-narrowing strategies before `hoistable_spread`. Decide:
  hoist them (the honest reading of the CHANGELOG sentence "object or abstract"), which
  means `hoisted_fragment` learns the interface-level-only struct and the narrowed
  struct; OR document the two shapes as not hoisting with the reason. Lean: hoist — the
  interface-level-only fragment is the commonest abstract fragment anyone writes, and
  "adding a second `... on` later silently moves every consumer's constant" is exactly
  the spooky action the principles forbid. If hoisting one of them can't be stated in the
  one sentence, document that one and say why.
- **F14**: the abstract-mixin refusal tells a hoisted struct to hoist. Branch on
  `@name`/the struct being `GraphQLTypes::*`: for a hoisted struct the fix is "select the
  member in the fragment".
- **F15**: a mapped-enum member the schema doesn't declare (app enum has `Ferret`, schema
  doesn't) gives a bare `KeyError` on both sides. Refuse at generation (exhaustiveness
  both ways — an app member with no wire value is a registration the schema disproves)
  unless `fallback:` names it; and the runtime path raises a GraphWeaver error naming
  the member, never a bare KeyError.
- **F19**: 30 of 33 codegen refusals don't carry the file, so `3 of 3 queries refused:`
  lists anonymous entries. Wrap in `generation_plan`'s rescue (it has `path`) so every
  refusal in a multi-query run names its file once.
- **Hunch**: for an `alias:` path that reads through a hoisted struct, the refusal's tail
  offers `optional: true`, which would silently drop the accessor for every query
  spreading the fragment. Check; if true, the refusal shouldn't offer it there.

## Ownership
`lib/graph_weaver/codegen.rb`, `lib/graph_weaver/codegen/nodes.rb`, `codegen/aliases.rb`,
`codegen/enum_type.rb`, `lib/graph_weaver/input_struct.rb`, `lib/graph_weaver/hints.rb`,
the `generation_plan` region of `lib/graph_weaver.rb`, specs, regenerated fixtures if
emission changes (commit drift with the change — coordinate: the running event lane ALSO
regenerates fixtures for its `execute` change; rebase carefully and re-run
`bin/generate` after), `docs/generated_modules.md` hoisting + enums sections,
`docs/scalars.md` enums section, and ONE contiguous CHANGELOG block under `## Unreleased`.
NOT `codegen/emit.rb` (event lane) unless F12 forces it — then report and we sequence.
Base off origin/main at 94d1999. Round-trip on the final tree: `bin/round-trip -c 2000` and
`-q spec/support/federation/queries`.

## Report
Per finding: before/after verbatim, rule in one sentence, sha; what you declined and why.
