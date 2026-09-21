# Junior cold start — follow docs/migrating.md from the published gem

Repo: /Users/dpepper/code/lib/ruby/graph_weaver, main at 89ded3e (READ-ONLY for you — modify nothing under it). Toolchain: ~/.rvm/wrappers/ruby-3.4.9/bundle exec … (PATH ruby is 2.6). Build under /tmp/claude/graph_weaver/round7/<your-app-name> (unique to you). Every claim in your report has a runnable repro; every message is quoted verbatim; every "the docs say X" is checked against what happened. Time-box dead ends at ~15 minutes; log and move on. Report; don't fix. Every repro states the exact scope it ran under. Earlier passes: research/logs/ and research/migration-experiment.md in the repo — skim the two nearest yours. Everything they found is fixed or listed in /tmp/claude/graph_weaver/round7/follow-ups.md; don't re-report those. Keep a timestamped log at /tmp/claude/graph_weaver/round7/<your-name>-log.md and put your full report there too (say so at the top of your final message if a write policy blocks it). Final message: a matrix of what you drove × outcome; ranked findings (severity on the ladder publish-blocker / silent wrong answer / quiet where it should speak / paper cut; repro; message verbatim; what a fix would look like; the files it would touch); a design critique from your viewpoint; the times you read source and why; minutes per step; one paragraph on whether you would ship on this.

EXCEPTION to "use the checkout": install graph_weaver 0.7.5 FROM RUBYGEMS (`gem
"graph_weaver", "0.7.5"`) — you are testing the published artifact. Read the repo's
docs only as a user would read them on GitHub (docs/*.md at tag v0.7.5: `git -C
<repo> show v0.7.5:docs/migrating.md` etc.). Do not open lib/ unless a doc tells
you to; opening it is a finding.

You are a year into Rails, have used GraphQL from TypeScript with Apollo, and have
never seen this library. Your team has a small Rails app on github/graphql-client
talking to the public Countries API (https://countries.trevorblades.com/graphql,
no auth): build that first — 3 queries with one shared fragment, one presenter,
one service object, request specs stubbed with webmock, green (~30 min budget).
Then follow docs/migrating.md step by step to move it onto graph_weaver. Also
make one enum on the schema drift on purpose (stub a response carrying a value
the schema doesn't declare) and follow the docs to survive it.

Deliverable: a ranked top ten of confusions, each with the doc section, what you
expected, what happened, and the one sentence that would have saved you; what was
easier than expected; minutes to first green spec after migration; whether the
gem as published carries everything the docs promised (generators, tasks, links
that resolve); would you have stayed.
