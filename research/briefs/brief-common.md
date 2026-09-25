# Common rules for every graph_weaver lane

Lives in the repo (research/briefs/brief-common.md) because /tmp is pruned after
three days and a lane brief that points at a missing file is silently skipped.
Update it in place; don't re-suffix per round.

Repo /Users/dpepper/code/lib/ruby/graph_weaver. You are in a worktree off the base
commit your lane brief names; rebase onto local `main` before reporting so the lead can
fast-forward. Read the repo's CLAUDE.md first — its design principle section decides
most calls ("one rule beats a rule with exceptions", "refuse rather than guess",
"errors are part of the interface").

## Toolchain

The PATH ruby is 2.6 and can't load bundler. Always:

    ~/.rvm/wrappers/ruby-3.4.9/bundle exec ...

## Gate — before EVERY commit, as separate commands

    bundle exec rspec              # full suite, 0 failures
    bundle exec srb tc             # No errors
    bundle exec ruby bin/generate  # "already up to date", tree clean

`bin/generate` also regenerates examples/github/generated when its cached dump is
present — a change to codegen/emit.rb reaches it; commit that drift with the change.
On the final commit add two random seeds (`--order rand:1`, one more) and, when the
change could reach them, `bin/federation-diff` and `bin/round-trip -c 2000`. There is
no rubocop in this bundle; don't run it. Mutant (`bundle exec mutant run
'GraphWeaver::Coerce'`, subjects in .mutant.yml) on a runtime module you reworked.

## Commits

Small, one idea each, imperative subject in the repo's voice (read `git log
--oneline -20`). Trailers on each:

    Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
    Claude-Session: https://claude.ai/code/session_01GbHLrRyUS8oTVYgKp5EMZo

CHANGELOG: one contiguous block under `## Unreleased` (create the heading if the
last version is cut; `.gitattributes` merges the file by union). An **Action** line
only when something a user has today changes behaviour. Never a bullet for a bug
introduced and fixed between releases. Correct an unpublished bullet in place rather
than contradicting it with a new one.

Comments: short, high-signal, say what a competent reader can't infer. No narration
of the fix, no counts or measurements that drift.

## Proof, not inspection

Watch every new spec fail before the fix. Run every doc example you write. A refusal
message is asserted verbatim in a spec. When the change touches the railtie, the
generator, the rake tasks or the install path, drive a scratch Rails app outside the
repo (CLAUDE.md says what to exercise) — the suite can't see the host seam.

## Traps

- `srb` reads the LAST `# typed:` sigil in a file; don't build .rbi files from
  heredocs that carry one.
- `Hash#inspect` differs between Ruby 3.3 and 3.4 (`{:a=>1}` vs `{a: 1}`); never
  interpolate a Hash into a message CI asserts — spell it as a caller writes it.
- Sorbet's stdlib RBI types `Numeric#real?` as TrueClass; an inline `real? ? … :
  refuse` is "unreachable" — use a sig-less helper.
- Wall-clock assertions fail on loaded CI; assert overlap or ordering, not elapsed
  time.
- A raw test HTTP server must send `Connection: close` or a retry races its
  keep-alive close (EOFError on Ruby 3.3).
- Bind test URLs nothing serves to `http://127.0.0.1:1/`, not a freed ephemeral port.
- `Log.instrument` is `instrument_request(payload)` / `instrument_operation(payload)`.
- A version bump changes every generated header: run `bin/generate` BEFORE rspec,
  never in parallel with it.
- Files under `research/` are the archive; don't read them for current behaviour.

## The shared scratch apps

/tmp/claude/graph_weaver/migrate/{menagerie,atlas} are shared across lanes and may
point at a worktree that no longer exists. Before driving one: repoint `path:` at
YOUR worktree, `bundle install`, and work on a branch there. Never commit to their
main. /tmp is pruned after three days — anything worth keeping goes under research/.

## Ownership

Your lane brief lists the files you own and who owns the others. If you need a file
you don't own: REPORT it, don't reach across.

## Report

Conclusions and evidence, not narration: the rule in one sentence, values
before/after, refusals verbatim, what you declined and why, shas, `git status` clean.
