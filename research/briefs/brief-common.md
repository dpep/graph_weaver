# Common brief — graph_weaver (round 4)

Repo: /Users/dpepper/code/lib/ruby/graph_weaver. Baseline main e26afa0: 1141 examples, srb clean, public surface locked at 424 names by spec/public_surface_spec.rb (spec/support/public_surface.txt — a new public name goes in the same commit). 0.6.1 is on RubyGems; work goes under `## Unreleased` in CHANGELOG.md.

## Read first
CLAUDE.md (principles + invariants), DECISIONS.md, CHANGELOG.md `## Unreleased` + `v0.6.1`/`v0.6.0`.

## Toolchain
`~/.rvm/wrappers/ruby-3.4.9/bundle exec ...` (or `export PATH="$HOME/.rvm/rubies/ruby-3.4.9/bin:$PATH"`); `source ~/.rvm/scripts/rvm` is refused in sandboxed shells. Run from the worktree root. GitHub dump: /Users/dpepper/code/lib/ruby/graph_weaver/examples/github/schema.json (read in place). Scratch files: /tmp/claude/graph_weaver/<your-name>-*.

## Worktree
If `git log -1` is behind `main` and your branch has no commits, `git merge --ff-only main` and continue. Commit to the worktree's own branch. Don't push, rebase, or merge main afterwards.

## Green gate — before every commit, as SEPARATE commands
bundle exec rspec; bundle exec srb tc; bundle exec ruby bin/generate (tree must stay clean); when codegen/runtime changed: two random seeds (`--order rand:N`), `bundle exec ruby bin/round-trip -c 2000`, `bundle exec ruby bin/federation-diff`, `bundle exec ruby examples/federation.rb`. Commit each piece as soon as it's green (a cut-off agent loses little). Trailer on every commit:
Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GbHLrRyUS8oTVYgKp5EMZo

## Codegen changes: prove zero false refusals on real schemas
When the reserved names, the emitter, or a refusal path changes, sweep every field and argument of the cached integration dumps (`integration_schema` in spec/support caches pokeapi and countries; `examples/github/schema.json`) and run `bin/round-trip <dump> -c 300` on each. GitHub's schema has no Hasura-style per-column input objects; PokeAPI's does, and its `pp` column is what caught an over-broad reserved list after "zero collisions on GitHub" had been measured. Then `INTEGRATION=1 bundle exec rspec spec/integration/countries_spec.rb spec/integration/pokeapi_spec.rb` if the network is there.

## Method
Spec watched failing first for every behavior change; assert messages where the message is the fix. Refuse rather than guess. One rule beats a rule with exceptions. If you conclude a change is worse than the status quo, say so and stop. Use `trekr --refs 'Owner#method'` / `rq Name` over grep. Inline comments short and high-signal.

## Report
Bugs/decisions with evidence and shas; what you investigated and left; specs added; doc deltas for files you don't own; DX observations; `git status` clean.
