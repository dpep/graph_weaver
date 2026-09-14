# Round six — common rules

You are evaluating graph_weaver (checkout /Users/dpepper/code/lib/ruby/graph_weaver, main at the sha in your launch message; 0.7.0 is on RubyGems and main carries the 0.7.1 fixes) from the viewpoint your brief names. Fourteen seniors, fifteen juniors, four hunts, two corpus sweeps, a mutation pass and a security review are in; logs at /tmp/claude/graph_weaver/senior-log-{A..O}.md and junior-log-{1..15}.md, the open list at /tmp/claude/graph_weaver/followups-post-070.md. Skim the two nearest yours so you don't repeat them; everything they found is fixed or listed.

Toolchain: `~/.rvm/wrappers/ruby-3.4.9/bundle exec ...` (never `source rvm`). Build under `/tmp/claude/graph_weaver/<your app dir>` with a unique name, Gemfile `path:` at the checkout (main, so the 0.7.1 fixes are in). Do not modify the gem. Every claim has a runnable repro, every message is quoted verbatim, every "the docs say X" checked against what happened. Time-box dead ends at ~15 minutes. Report; don't fix.

Keep a timestamped log at `/tmp/claude/graph_weaver/<your log>.md`. Final message: a matrix of what you drove × outcome; ranked findings (severity, repro, message verbatim, what a fix would look like); a design critique from your viewpoint; the times you read lib/ or spec/ and why; minutes per step; one paragraph on whether you'd ship on this surface.
