# Queued for the final scribe pass (from junior 14, the no-Sorbet app)

Source: /tmp/claude/graph_weaver/junior-log-14.md. The app ran clean end to end with no sorbet/tapioca gems (install, generate, :fake and live specs, verify, queries:check, production boot, zeitwerk:check). Findings are all prose:

1. README: the tagline and flagship example are Sorbet-first ("compiled into Sorbet types", the `srb tc` error) and nothing there says static Sorbet is optional. Add one sentence near the top: sorbet-runtime is the only dependency; `srb tc` is the app's choice, and without it the same typos surface as NoMethodError at runtime. Link the getting_started section.
2. docs/getting_started.md: "Sorbet, with or without" sits at the bottom after all five steps. Move it, or a two-line pointer to it, to where the adoption decision is made (before step 1).
3. Generated header comment `srb tc still holds typed call sites` (find it in codegen/emit.rb) reads as jargon to a non-Sorbet reader. Reword so it means something to both readers, or drop it; the wire: comments beside renamed props are the model.
4. The honest gap to state once: nilable-field misuse (`country.capital.upcase`) is the one class static Sorbet catches and runtime cannot. Say it in the "with or without" section if it isn't already.
