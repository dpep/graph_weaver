# Common: fixing the hunt findings

Baseline main **a1bd5ec** (1272 examples, surface 452, CI green on Ruby 3.3/3.4/4). Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, trailers and method, then CLAUDE.md. The findings come from `/tmp/claude/graph_weaver/hunt-report.md` — read your lane's findings there in full (they carry the repro paths, exact outputs and a proposed fix each; the proposed fix is a starting point, not an order). Repro scripts live under `/tmp/claude/graph_weaver/hunt-*/`; run each one before and after. Worktree branch; don't push.

Four lanes run at once, partitioned by file. Touch only your files; report anything you'd change elsewhere. CHANGELOG: every lane appends under `## Unreleased` — keep your bullets in ONE contiguous block headed by an HTML comment naming your lane (`<!-- lane: harness -->`) so the merge is mechanical; the coordinator removes the comments. `spec/support/public_surface.txt` is shared: add only your names, contiguous.

Every fix: spec watched failing first, the hunt repro run after, gate as separate commands before each commit (`rspec`, `srb tc`, `bin/generate` clean, two random seeds; `bin/round-trip -c 2000` when codegen or coercion changed), small commits, commit trailers from brief-common. If a finding's proposed fix would be a rule with an exception, or you conclude the current behavior is right, say so with the reason and leave it — a refusal is a valid resolution, a silent skip is not.

Report: shas; per finding — fixed / refused-instead / left, the message verbatim where a message changed; what you'd change in another lane's files; `git status` clean.
