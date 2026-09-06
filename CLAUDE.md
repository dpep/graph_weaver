# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A typed GraphQL client for Ruby: generates `# typed: strict` Ruby (nested
`T::Struct`s + a typed `execute`) from your queries, checked against the schema
at generation time. Sorbet is core to the product.

## Design principle — correct and simple, in that order

Adoption follows delight, and delight follows from a tool that solves the real
problem without making you think. So the bar for any change is: is it correct,
and is it the *simplest* thing that is correct? Complexity is not neutral — it
is confusion, bugs, and frustration, paid for by every future reader and user.

What this means when choosing between designs:

- **One rule beats a rule with exceptions.** A behavior you can state in a
  sentence, and predict without reading the source, is worth more than one that
  is marginally more capable. Generated class names come from the response key —
  full stop — rather than from the type name with disambiguation-on-collision,
  because the second rule can't be stated without describing its own edge cases.
- **Prefer removing a decision to adding a knob.** The transport default got
  *better* by deleting auto-detection: one less thing to know, one less way to be
  surprised, and the fast path became the default. Reach for a config option only
  after the simple default has actually failed someone.
- **A convention can beat a capability.** One file holds one operation. That's a
  convention, and it makes module naming derivable from the filename; supporting
  multiple operations per file would be more capable and worse.
- **No spooky action at a distance.** Behavior should follow from the code in
  front of you, not from what else is in the Gemfile, what ran first, or which
  selection the walk happened to reach earlier.
- **Match the ecosystem's conventions** where one exists — a familiar shape costs
  the user zero learning, which is the cheapest simplicity available.
- **Errors are part of the interface.** A good message names what went wrong,
  where, and what to do about it. `optional: true` in the message beats the same
  advice buried in docs. The best bug fix often makes an error impossible; the
  next best makes it self-explanatory.
- **Refuse rather than guess.** When intent is ambiguous, fail loudly at
  generation time. A silent wrong answer is the most expensive outcome this
  library can produce, because the generated code looks authoritative.

When simplicity and capability genuinely conflict, say so out loud and pick
deliberately — but the default is simple.

**Docs are a complexity detector.** A section that belabors a topic is usually
not a writing problem — it is the library pushing complexity onto the reader.
Before expanding an explanation, ask whether the thing being explained should
exist. If two paragraphs are needed to say which of two ways applies, delete one
of the ways; the docs then shrink on their own, which is the signal the cut was
right.

## Sorbet typing policy — type by value, not for coverage

Sorbet being core does **not** mean every file should be `# typed: strict`. Type
where it pays off in developer experience; leave the rest at `# typed: true`.

- **Strict (full sigs) — developer-facing contracts.** The types users touch:
  `response.rb` (the envelope every `execute` returns), the error hierarchy
  (`errors.rb`), and the **generated code** (emitted `# typed: strict`). Concrete
  types here give downstream apps real call-site checking + autocomplete — that's
  the product.
- **`# typed: true` (loose) — dynamic / boundary internals.** The codegen
  (`codegen.rb`, `codegen/nodes.rb`, `codegen/emit.rb`, `codegen/scalar_type.rb`,
  `codegen/enum_type.rb`) walks graphql-ruby's approximately-typed AST and builds
  modules/strings dynamically; `client.rb` wraps a graphql-ruby schema and a
  duck-typed transport. Strict here is ~all `T.untyped` — paperwork that documents
  shape without catching anything. **Don't promote these to strict.**
- Rule of thumb: if a sig would be mostly `T.untyped`, it isn't worth writing.
  Concrete types = value; `T.untyped` sigs = paperwork.
- `railtie.rb` / `tasks.rb` are `# typed: ignore` (Rails/Rake DSL).

## Design invariants (don't "fix" these)

- **The client slot is duck-typed.** A transport, `Retry`, a live graphql-ruby
  schema class, or a test fake all satisfy one contract —
  `execute(query, variables:) => {"data" => ..., "errors" => ...}` — with no
  shared base class. **Don't formalize it as a strict Sorbet interface**: a
  graphql-ruby `Schema` class fits the slot without inheriting anything, and a
  strict interface would exclude it. This is why the transport/client seams stay
  loosely typed.
- **Codegen is query-driven.** Structs are generated per selection set, only for
  the types a query actually touches — not the whole schema (so extra schema
  types, e.g. federation `join__*`, generate no code).
- **Leaf codecs vs composite decoration.** `register_scalar` / `register_enum`
  *define/replace* how a leaf deserializes (its Ruby shape is fixed);
  `extend_type` only *decorates* a generated composite struct with mixins — it
  can't replace one, because a composite's shape varies per query. Don't add a
  "replace a composite's deserializer" path.

## Green before commit

```sh
bundle exec rspec        # full suite
bundle exec srb tc       # Sorbet typecheck (CI gates on this too)
```

Both must pass. Sorbet sigs are runtime-checked by sorbet-runtime, so a wrong
sig surfaces as an rspec failure, not only a `srb tc` error — a green suite
validates the sigs against real usage.

## Drive it from a throwaway app when the host seam changes

**The suite cannot test the gem's relationship with its host.** It is not a Rails
app, so anything that depends on Rails' boot order, Zeitwerk, or rake's task
graph is structurally invisible to it — and both bugs found that way were silent
in development and only appeared in production boot or when registrations
mattered:

- `rake graph_weaver:generate` never ran `:environment`, because the task asked
  `Rake::Task.task_defined?("environment")` at *load* time and Rails defines it
  *after* railties' `rake_tasks` blocks. Every `register_scalar`/`extend_type` in
  an initializer was silently dropped at generation, and `verify` reported the
  result up to date.
- `app/graphql/generated` sits under a Zeitwerk root while its files define
  top-level constants, so eager loading raised `NameError`. Lazy dev boot was
  fine; production was not.

So when the railtie, the rake tasks, the generator, or the documented install
path changes, spin up a scratch Rails app outside the repo, point its Gemfile at
your checkout, and actually use it. Worth exercising: **both** a remote endpoint
and the app's own graphql-ruby schema in-process; `RAILS_ENV=production` boot and
`rails zeitwerk:check`; a registration in `config/initializers` that must reach
generated output; the rake tasks end to end; and the testing harness from inside
the app's own specs. The app is disposable — rebuilding it is cheaper than the
bugs it catches.

## Version bumps

Bump `lib/graph_weaver/version.rb` and, in the **same commit**:

- update `Gemfile.lock` (the gem pins its own version there; CI runs a frozen
  `bundle install`, which fails at the *setup* step with exit code 16 — before
  tests — if the lock is stale), and
- add a `CHANGELOG.md` entry.

`gem push` (the actual RubyGems release) is a separate, manual step.
