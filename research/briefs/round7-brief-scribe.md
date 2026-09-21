# Scribe — round 7's doc items, one voice

Read /tmp/claude/graph_weaver/brief-common.md (toolchain, commit rules), then CLAUDE.md's
"Docs are a complexity detector" paragraph — the editorial standard. Then
/tmp/claude/graph_weaver/round7/triage.md (the round's findings by tester, with which went to
which lane) and the three tester logs beside it (junior-fragments-log.md,
junior-migrate-log.md, hunt7-log.md — search the finding numbers named below). The five
fix lanes have all landed on main; their CHANGELOG bullets under `## Unreleased` are the
current truth for any behaviour you describe — verify each claim against the code or by
running it, and if a lane's bullet and the code disagree, say so in your report and write
what is true.

Voice: the existing docs' — direct, present tense, no history. Every fenced sample runs
(`spec/doc_samples_spec.rb`); every link resolves; existing heading anchors stay stable.

## Items (each one or two sentences unless said otherwise)

From the juniors:
1. `docs/testing.md`: `:in_process` derives the live class from what is loaded; `:wire`
   doesn't take that fallback and serves a fake with a warning naming `config.schema =`.
   Say the two derivations side by side. (Lane F already documented how to assert a
   tag's before-hook refusal — check it's there and consistent.)
2. `docs/testing.md#pins`: a pin value isn't checked against the enum's declared values,
   only the coordinate is; with `fallback: true` that is a way to rehearse drift.
3. `docs/getting_started.md` client section: no auth? omit `auth:` — the constructor's
   only full example always shows it.
4. `docs/migrating.md` step 2: `schema:refresh` rewrites the dump in place in
   graph_weaver's format (now pretty-printed JSON with a `graph_weaver:` provenance key);
   if graphql-client still reads that file during the migration, it tolerates the extra
   key — say so rather than leave it to luck. Step 3: registering scalars/enums is
   conditional; an API with none skips it.

From the hunt (Tier 4, not taken by a lane):
5. `docs/scalars.md` enums section: `as_json` of a member that absorbed a value writes
   the sentinel `"__other__"` — the round trip holds, but `render json:` emits a value no
   server declares; one sentence where the "three things follow" list is. (Lane C edited
   this section for F15 — build on what's there.)
6. The client contract is `execute(query, variables:, operation_name:)`. Three places
   say only `(query, variables:)`: the refusal in `lib/graph_weaver/query_module.rb`
   (`client must respond to #execute(query, variables:)` — a one-string change, do it),
   `docs/generated_modules.md` near the "Clients" section's quoted message, and
   CLAUDE.md's "The client slot is duck-typed" invariant line. Fix all three.
7. `docs/generated_modules.md`: the quoted `got NilClass` example is unreachable (the nil
   client raises "no client configured" first) — replace with a reachable example.
8. `docs/testing.md` near line 219: the "the live schema class is found for you … if two
   loaded classes match" discovery claim describes something the code doesn't do — it's
   `config.schema`, else the graph's, else what `GraphWeaver.client` already runs
   in-process. Rewrite to what is true (lane F may have touched this; check).
9. The enum collision refusal says "both become the constant" for three values — this is
   a message, in `lib/graph_weaver/codegen.rb` (`enum_values`): make the sentence count
   ("all become"), one-word change, spec updated if pinned.
10. `docs/upgrading.md` ~line 125 (a 0.7.x row): "schema:refresh refuses it rather than
    overwriting" — lane T says it now "steps over it" with the recompose line. Historical
    rows describe their release; leave it unless it's in the "Upgrading from 0.7.4"
    section, in which case make it current.
11. `lib/graph_weaver.rb` ~line 626 comment: "One query you have as a string is
    Client#check_query" — now every schema-holding client answers it; fix the sentence.

## Ownership

`docs/*.md`, `README.md`, `CLAUDE.md` (the one line), the three message strings named
above and their specs, `spec/doc_samples_spec.rb` keys. Nothing else in `lib/`. No
CHANGELOG entry for docs; the two message changes (6, 9) get one short bullet together.
No other lane is running. Base off `origin/main` at the current head.

## Report

Per item: file and heading, what you wrote or why you didn't; any lane bullet you found
untrue and what you wrote instead.
