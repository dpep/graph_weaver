# Junior cold start — shared fragments, enums, and the testing tags, from the docs

Repo: /Users/dpepper/code/lib/ruby/graph_weaver, main at 89ded3e (READ-ONLY for you — modify nothing under it). Toolchain: ~/.rvm/wrappers/ruby-3.4.9/bundle exec … (PATH ruby is 2.6). Build under /tmp/claude/graph_weaver/round7/<your-app-name> (unique to you). Every claim in your report has a runnable repro; every message is quoted verbatim; every "the docs say X" is checked against what happened. Time-box dead ends at ~15 minutes; log and move on. Report; don't fix. Every repro states the exact scope it ran under. Earlier passes: research/logs/ and research/migration-experiment.md in the repo — skim the two nearest yours. Everything they found is fixed or listed in /tmp/claude/graph_weaver/round7/follow-ups.md; don't re-report those. Keep a timestamped log at /tmp/claude/graph_weaver/round7/<your-name>-log.md and put your full report there too (say so at the top of your final message if a write policy blocks it). Final message: a matrix of what you drove × outcome; ranked findings (severity on the ladder publish-blocker / silent wrong answer / quiet where it should speak / paper cut; repro; message verbatim; what a fix would look like; the files it would touch); a design critique from your viewpoint; the times you read source and why; minutes per step; one paragraph on whether you would ship on this.

Use the CHECKOUT at 89ded3e via `path:` in a scratch Rails app's Gemfile (these
surfaces are newer than the published gem). Do not open lib/ unless a doc tells
you to; opening it is a finding. Your only sources: README.md and docs/.

You are a year into Rails, have used GraphQL from a Python client, and have never
seen this library. Task: a small Rails app that serves its OWN graphql-ruby schema
(a Pet adoption API: Pet with an enum Species, a Money-ish custom scalar, a
Shelter with a list of pets, an interface Animal with two implementations, one
mutation) and ALSO consumes it through graph_weaver in-process. Write four
queries where two spread one shared fragment on Pet and one spreads a shared
fragment on the interface; a presenter typed against the shared Pet type; a
policy that switches on Species with a fallback for values the server adds
later; specs using graphql: :fake for one, :in_process for one, and :wire for
one — and one spec that runs a query string through client.check_query.
Then: add a Species value to the schema without regenerating and see what every
layer tells you.

Deliverable: a ranked top ten of confusions (doc section, expected, happened, the
one saving sentence); what was easier than expected; minutes to first green spec;
every generated name you had to type in app code and whether you could guess it;
would you have stayed.
