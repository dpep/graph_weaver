# Scribe A: the front door

Read /tmp/claude/graph_weaver/brief-polish-common.md. You own the path a new developer walks: **README.md, docs/getting_started.md, docs/generated_modules.md, docs/testing.md, docs/cassettes.md, docs/editors.md, docs/alternatives.md, examples/README.md**, and `graph_weaver.gemspec`'s `description` only if the README tagline changes (`spec/gemspec_spec.rb` pins them together — keep them equal).

Specific asks:
- README: a reader decides in one screen. Tagline, the three-line example, install, what it gives you (typed results, tests without a server, drift detection), links. Everything else moves to getting_started or goes. Say once that static Sorbet is optional (sorbet-runtime is the only Sorbet gem required) — it is there now, keep it, and keep it short.
- getting_started.md is 781 lines. A getting-started guide is the happy path: install, one query, generate, one spec, verify in CI. Multi-graph, federation, and every "if you also…" moves to the file that owns that topic (a one-line pointer stays). The §5 CI section keeps its per-topology scripts but loses the prose around them.
- generated_modules.md and testing.md are the two references a working developer reads most; they are 844 and 819 lines. Each wants a first screen that is a table of contents in prose — what the module gives you / which mode to pick — then sections a reader can jump to. The mode table in testing.md is the most valuable thing in the docs; make sure it is near the top and every mode has one sentence and one example.
- cassettes.md and editors.md: check they still describe current behavior (cassettes lock under parallel processes now; `[req pid-n]` tags) and trim.
- alternatives.md: keep; it is short and honest. Only cut history.

Report as the common brief says.
