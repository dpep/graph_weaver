# Lane: archive the user-research findings into the repo

Repo /Users/dpepper/code/lib/ruby/graph_weaver, main at **7d837e5** (worktree off it; two scribes are rewriting docs/ and README.md in their own worktrees — not yours). Toolchain `~/.rvm/wrappers/ruby-3.4.9/bundle exec ...`. Trailers on every commit:

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GbHLrRyUS8oTVYgKp5EMZo

**Why.** Over one session, ~40 agent passes (4 hunts, 15 juniors, 20 seniors, corpus sweeps, a mutation pass, a security review, a performance pass) drove the gem from throwaway apps and wrote findings to /tmp/claude/graph_weaver/*.md. Everything they found is fixed, documented, or in PLAN.md's backlog — but the logs carry the reasoning, the verbatim messages, the measurements and the matrices, and /tmp is ephemeral. Memorialize them in the repo as `research/`, kept out of the gem package.

**Do:**
1. `research/` with three subdirectories, copied from /tmp/claude/graph_weaver: `research/logs/` (every `senior-log-*.md`, `junior-log-*.md`, `hunt*-report.md`, `hunt-report.md`, `corpus-report.md`, `transport-hunt-report.md`, `mutant-report.md`, `inputs-memo.md`, `followups-post-070.md`, `scribe-queue-*.md`, and any other report-shaped `.md` you find — list what you took), `research/briefs/` (every `brief-*.md`), `research/corpus/` (the SCRIPTS only from /tmp/claude/graph_weaver/corpus/ — `*.rb`, `*.sh`, `*.mjs`, any README — never the `.json`/`.graphql` dumps, which are re-fetchable and 20 MB). Preserve file names.
2. `research/README.md`: what this directory is (one paragraph: synthetic user research from the 0.7.0/0.7.1 hardening; the logs are point-in-time and describe behavior AS FOUND, since fixed — the docs and CHANGELOG are the current truth); then an index table, one row per pass in order (hunt 1–3, juniors 1–15, seniors A–U, corpus 1–2, mutation, security), with the pass's viewpoint and its top finding in one line each — read each log's ranked-findings section to write the line; don't guess. Note which seniors/juniors have no log file (say "report only, in the session transcript") rather than inventing one. Then a short "how to run one again" pointing at the briefs and the corpus scripts.
3. `graph_weaver.gemspec`: add `':!:research'` to the `git ls-files` exclusion list in `s.files` — that line only; a scribe may touch the description line, expect a rebase. Prove it: `bundle exec gem build graph_weaver.gemspec`, `tar -O -xf graph_weaver-*.gem data.tar.gz | tar -tz | grep -c research` must be 0, then delete the `.gem`.
4. Also add `research/` to whatever excludes the directory from `srb tc` and rspec if either would otherwise walk it (check `sorbet/config` and `.rspec`); the Ruby scripts under `research/corpus/` must not be type-checked or loaded.
5. Gate, separate commands: `bundle exec rspec spec/doc_samples_spec.rb` (link checks — if it walks `research/`, exclude it there too), full `bundle exec rspec`, `bundle exec srb tc`, `bundle exec ruby bin/generate` clean, `BUNDLE_FROZEN=true bundle install`.

Commit in two: the archive (files + README), then the gemspec/config excludes. Report: file counts per subdirectory and total size, the index (paste it), the gem-contents proof, shas, `git status` clean.
