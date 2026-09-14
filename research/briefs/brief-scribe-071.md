# Brief: the 0.7.1 docs pass — the queue, then the fold, then the cut prep

Repo /Users/dpepper/code/lib/ruby/graph_weaver, main at **efde171** (you are in a worktree; nothing else is running). Read CLAUDE.md ("Docs are a complexity detector"; "Version bumps"). Toolchain `~/.rvm/wrappers/ruby-3.4.9/bundle exec ...`. Don't push, don't tag. Verify every behavior claim against the code or by running it. The two earlier fold briefs (/tmp/claude/graph_weaver/brief-scribe-fold2.md, brief-scribe-fold3.md) set the rules; this release is small, so the fold is light.

**1. The docs queue** — /tmp/claude/graph_weaver/scribe-queue-071.md, seven items from seniors U and T, each verified before writing. Item 4 includes a small code change (the `federation:diff` success sentence names what it doesn't check — find where "matches the schemas here" is composed, `lib/graph_weaver/federation.rb` or `internal/tasks.rb`, change the sentence, update the spec that pins it; CHANGELOG bullet). Item 5's recipe must be run in a scratch app or a spec before it is written down.

**2. The fold.** `CHANGELOG.md`'s `###  Unreleased` (about 45 bullets from nine lanes: security, packaging, filenames, union refusal, object pins, concurrency, writes/observability, specifiedByURL, and yours) becomes `###  v0.7.1  (<today's date>)`. 0.7.1 is a patch on a published 0.7.0, so — unlike the 0.7.0 folds — every fix stays a bullet (all of these reached users). Merge duplicates, put the *Actions* first in a short "What you must do" run (there are a few: `Testing::Router` specs comparing error hashes whole see `extensions.service`… no, that shipped in 0.7.0 — check each candidate against `git show v0.7.0:CHANGELOG.md`; real 0.7.1 actions include `payload[:code]` no longer carrying an HTTP status, a spec asserting a fabricated `userErrors` is non-empty, the `[req pid-n]` tag shape, `cache: true` naming a digest file for a second client, `examples/` shipping and CHANGELOG not), remove lane comments. Cut words, not facts.

**3. `docs/upgrading.md`** — a short "Upgrading from 0.7.0" section above "Upgrading from 0.6.1" with one row per Action.

**4. `DECISIONS.md`** — entries for: a message never carries a body (6eb92f9); whoever owns the mutable field owns the lock (972ec05); a retryable status retries however the failure arrived, and Retry-After wins over backoff (240d3c2 shipped in 0.7.0 — check; 9fd1944 is the 0.7.1 half); the file-name rule (536e2bc); `stub_graphql` considered and declined (branch `experiment/stub-graphql`; the reasoning is in /tmp/claude/graph_weaver/followups-post-070.md); a list field ending in `errors` fabricates empty (8c1bec4); the instrumentation extent stays per attempt below Retry (the writes lane's argument in its report — the caller-outcome extent is a contract rewrite for later). Skip any a lane already wrote.

**5. Version bump, ONE commit, exactly as CLAUDE.md says:** `lib/graph_weaver/version.rb` → `0.7.1`, `Gemfile.lock` updated (`bundle install` — CI's frozen install fails at setup otherwise), the CHANGELOG heading (already done in step 2 — make sure the date and version match). Run the full gate after.

Every fenced sample must parse and links resolve (`spec/doc_samples_spec.rb`; update allow-list keys when you reword). Commits: the queue as one or two, the fold as one, DECISIONS/upgrading as one, the version bump as one. Trailers:

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GbHLrRyUS8oTVYgKp5EMZo

Gate, separate commands: `bundle exec rspec spec/doc_samples_spec.rb`, full `bundle exec rspec`, `bundle exec srb tc`, `bundle exec ruby bin/generate` clean, `BUNDLE_FROZEN=true bundle install` succeeding. Report: shas; per queue item done/verified/skipped; bullet count before/after the fold; the Actions list; anything false found while verifying.
