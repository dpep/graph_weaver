# Common: fixing the hunt 2 findings

Baseline main **e773183** (v0.7.0 tag at 4730ec0 plus docs; 1515 examples, surface 475, CI green on Ruby 3.3/3.4/4). Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, trailers and method, then CLAUDE.md. The findings are in `/tmp/claude/graph_weaver/hunt2-report.md` — read your lane's items there in full; each carries a repro path under `/tmp/claude/graph_weaver/hunt2-*.rb`, exact output, and a proposed fix that is a starting point, not an order. Run each repro before and after. Worktree branch; don't push. **Each gate command is its own Bash call, never chained** — the silence watchdog kills an agent after 600s.

Four lanes run at once, partitioned by file. Touch only your files; report anything you'd change elsewhere. CHANGELOG: a new `## Unreleased` heading exists or you create it; keep your bullets in ONE contiguous block headed by `<!-- lane: <name> -->` so the merge is mechanical. `spec/support/public_surface.txt`: your names only, contiguous. Messages that a spec pins must not depend on this Ruby's spelling of Hash#inspect or NoMethodError — CI runs 3.3, 3.4 and 4.

Every fix: spec watched failing first, the hunt repro run after, gate as separate commands before each commit (`rspec`, `srb tc`, `bin/generate` clean, two random seeds; `bin/round-trip -c 2000` when codegen or coercion changed), small commits, trailers from brief-common. If a proposed fix would be a rule with an exception, or the current behavior is right, say so with the reason and leave it — a refusal is a valid resolution, a silent skip is not.

Report: shas; per finding — fixed / refused-instead / left, the message verbatim where one changed; what you'd change in another lane's files; `git status` clean.
