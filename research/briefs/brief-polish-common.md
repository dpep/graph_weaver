# Docs polish — common rules for both scribes

Repo /Users/dpepper/code/lib/ruby/graph_weaver, main at **7d837e5** (you are in a worktree; the other scribe owns the other half of the docs — file ownership is in your brief and is strict). 0.7.1 is cut and tagged; this is docs-only work for the next patch, so: no behavior changes, no CHANGELOG entry, no version bump. Toolchain `~/.rvm/wrappers/ruby-3.4.9/bundle exec ...`. Read CLAUDE.md's "Docs are a complexity detector" and "Design principle" first; they are the editorial standard.

**The job.** These docs grew across six release rounds of agents adding a paragraph per finding. They are accurate and too long, and they narrate history. Rewrite for a developer who has never seen the gem and needs to get started and use it successfully — what to do, what happens, what to do when it doesn't — and cut everything else:

- **Current behavior only.** Delete "used to", "no longer", "previously", "this release", "since 0.x", "an earlier version", "a hunt/junior/senior found", "before the fix" and every sentence that exists to explain a change rather than a behavior. History lives in CHANGELOG.md (untouched by you) and DECISIONS.md (untouched). The one exception is docs/upgrading.md, which is history by nature — see the reference brief.
- **Lead with what a developer needs most.** In each file, the first screen answers "what is this, when do I want it, the three-line example." Move the edge cases, the refusal tables, the "why not the other design" paragraphs below the fold or into one "Details" section per file. A sentence that begins with a caveat before the reader has seen the happy path is in the wrong place.
- **Shorten; don't add.** Every paragraph that belabors a topic is the library pushing complexity onto the reader — if two paragraphs explain which of two ways applies, keep the way and the sentence, cut the other. Target: each file at most two thirds of its current length, and say in the report what each went from and to. Cut words, never facts a user needs; a fact you cut must be either duplicated elsewhere (say where) or a fact no user needs.
- **Keep every claim true.** Verify against the code or by running it before keeping a sentence; anything you can't verify, delete rather than guess. Every fenced sample must parse and run where it is behavioral (`spec/doc_samples_spec.rb` — its allow-list keys on literal excerpts; update keys for your files only, and expect a rebase on that spec file since both scribes touch it). Every link must resolve. Keep existing heading anchors stable (the other scribe's files link to yours; you can add headings, not rename them without grepping `docs/ README.md` for the anchor and reporting any you couldn't fix).
- **Voice.** Direct, present tense, second person where it helps, no "we", no marketing. Match the README's existing register. Error messages quoted verbatim are fine; don't paraphrase one.
- **Don't touch:** `lib/`, `spec/` except `spec/doc_samples_spec.rb` keys, `CHANGELOG.md`, `DECISIONS.md`, `PLAN.md`, `CLAUDE.md`, the other scribe's files.

Commits: one per file or small group, trailers on each:

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GbHLrRyUS8oTVYgKp5EMZo

Gate before each commit, separate commands: `bundle exec rspec spec/doc_samples_spec.rb`, then at the end the full `bundle exec rspec`, `bundle exec srb tc`. Report: per file before/after line counts, what was cut and where each cut fact now lives (or why no user needs it), any claim found false, any anchor you couldn't keep stable, shas, `git status` clean.
