# Lane: docs — B4, D1, D5, and the doc-samples spec (D6)

Read /tmp/claude/graph_weaver/brief-hunt-common.md first.

You are the scribe with one engineering task at the end. The standard: a doc sample runs as pasted, and the upgrade guide names every change that turns running code into a raise.

- **B4**: two samples raise as written — `docs/transports.md` ~187 passes a live object as `client:` to `Codegen.generate` (it must be a constant name or String; show the constant), and `docs/federation.md` ~234 omits `require "graph_weaver/federation"`. Fix and run both.
- **D1**: `docs/upgrading.md`'s 0.7.0 section omits four breaking changes: `client` that isn't a constant refused at generation; a `cast:`/`serialize:` proc returning a value refused at registration; a router's `fake:` refusing `seed:`; the `DateTime`-for-`Date` wire change. Add them in the section's own shape, each saying what to do. Reconcile its opening sentence.
- **D5**: `README.md` ~189 says upgrading covers "what 0.5.0 moved"; `docs/getting_started.md` ~328 links `#2-what-the-generator-writes`, which doesn't exist (`#2-run-the-generator`); `docs/upgrading.md` ~196 omits `BigDecimal` from the no-pin-needed scalar list. Fix all three; then check every intra-doc anchor in README + docs/ resolves (script it).
- **CHANGELOG hunch**: the v0.7.0 block's graph example shows `schema Billing::Schema` (bare constant) while the text below says a bare constant in an initializer raises under Zeitwerk. Make the example `schema -> { Billing::Schema }` and consistent with getting_started.
- **D6, the engineering task**: there is no doc-samples spec — none of the ~110 fenced `ruby` samples in README + docs/ are parsed. Write `spec/doc_samples_spec.rb`: extract every ```ruby fence from README.md and docs/*.md, and for each assert it parses (`RubyVM::AbstractSyntaxTree.parse` or `Prism`), with an allow-list for deliberate `...` elisions keyed by file + a short excerpt (not line numbers, which drift). Report how many parse, how many are allow-listed, and any sample that fails for a reason other than elision (that's a finding — fix the sample). Don't try to *execute* samples; parsing is the durable cheap gate, and say in the spec's header comment why execution isn't attempted.

Ownership: `README.md`, `docs/upgrading.md`, `docs/transports.md` (the sample only — the transport lane owns its prose), `docs/federation.md`, `docs/getting_started.md` (anchors and prose — the codegen lane owns the graph-block section's semantics; don't change what it says a block does), `docs/errors.md`, `docs/cassettes.md`, `docs/real_world.md`, `docs/logging.md`, `docs/editors.md`, `CHANGELOG.md` (the v0.7.0 example fix, plus your Unreleased block), `spec/doc_samples_spec.rb`. Not yours: `docs/testing.md` (harness lane), `docs/scalars.md` (transport lane), `docs/generated_modules.md` (codegen lane), anything under `lib/`.

Every sample you touch: run it. Gate: `rspec` (your new spec included), two seeds.
