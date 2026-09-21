# Lane U — unused lint, the installer's gitattributes, and a non-git checkout

Read /tmp/claude/graph_weaver/brief-common.md first, then CLAUDE.md's design section, then
/tmp/claude/graph_weaver/round7/hunt7-log.md findings F4, F5, F21, and the Tier-4 item "Three specs fail in a checkout that isn't a
git repo". Fixture for F4/F5: /tmp/claude/graph_weaver/round7/hunt7-app/u1 (and the
`unused_pre.rb` emulation the hunt describes).

## Stance
`unused` is a lint whose stated law is "silence is the safe direction" — a red build must
never tell you to delete a field you render. If a fix needs a rule with an exception, say
so and stop.

## Findings
- **F4 (silent wrong answer, regression from the Unreleased `unused` change)**: a
  `before_action`-loaded `@result = PetQuery.execute!` is dropped at the next `def`
  because `ASSIGN` captures `result` with the sigil stripped and `SCOPE` clears the whole
  table. Rule: a plain local stands for its module only inside the method that assigned
  it; an `@`-prefixed assignment survives the method boundary (capture the sigil). Spec
  watches the u1 shape go from 4 unread to 0 unread with the serializer credit.
- **F5**: the coordinate printed comes from scanning every word in the file (comments and
  `$id: ID!` included), so `Pet.ID` is named for a field the query never selected. Draw
  candidate words from the parsed selection set.
- **F21**: the installer's "already marked" check is `body.include?(glob)` over the whole
  .gitattributes, so a comment mentioning the path suppresses the mark, and a
  `app/graphql/generated/ linguist-generated` line (no `**`) isn't detected. Match a
  non-comment line whose pattern names the directory; keep idempotency.
- **Tier 4**: three specs (faraday_spec:19, federation_drift_spec:313, log_subscriber_spec:103)
  fail in a non-git checkout because the gemspec's `git ls-files` writes to stderr and they
  capture `2>&1`. Make the gemspec quiet outside a git repo (fall back to `Dir.glob`), or
  have those specs not capture stderr — pick the one that fixes the cause.

## Ownership
`lib/graph_weaver/internal/unused.rb`, `lib/generators/graph_weaver/install_generator.rb`,
`graph_weaver.gemspec`, their specs, the `unused` paragraph in `docs/getting_started.md`
("The selections nothing reads" section ONLY — lane T edits §5's schema-task sentences),
and ONE contiguous CHANGELOG block under `## Unreleased` (correct the existing `unused`
bullet in place rather than contradicting it). Other lanes own everything else named in
/tmp/claude/graph_weaver/round7/hunt7-log.md; stay out. Base off origin/main at 94d1999.

## Report
Per finding: before/after verbatim, rule in one sentence, sha.
