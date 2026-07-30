# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A typed GraphQL client for Ruby: generates `# typed: strict` Ruby (nested
`T::Struct`s + a typed `execute`) from your queries, checked against the schema
at generation time. Sorbet is core to the product.

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

## Version bumps

Bump `lib/graph_weaver/version.rb` and, in the **same commit**:

- update `Gemfile.lock` (the gem pins its own version there; CI runs a frozen
  `bundle install`, which fails at the *setup* step with exit code 16 — before
  tests — if the lock is stale), and
- add a `CHANGELOG.md` entry.

`gem push` (the actual RubyGems release) is a separate, manual step.
