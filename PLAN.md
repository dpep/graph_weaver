# Project Plan — typed GraphQL codegen for Ruby/Sorbet

_Resume-from-here notes. The README is the lab notebook (findings); this is
the plan. Update both when state changes._

## Vision

A "graphql-codegen for Ruby": `.graphql` queries + a schema (live class,
introspection JSON, or SDL) → checked-in `# typed: strict` Ruby — nested
T::Structs, generated casting, typed execute — so `srb tc` sees the exact
shape of every query result. Dynamic (eval) mode for development, build
step for CI/static checking. Runtime deps: graphql + sorbet-runtime only
(graphql-client is NOT a dependency; the exploration outgrew it).

## State: working prototype, all green

`bundle exec rspec` (35 examples) + `bundle exec srb tc` + `bin/generate`
(regenerates lib/generated/ from queries/; parity specs enforce freshness).

Language coverage: queries, mutations, typed variables (kwargs on execute,
optional-when-defaulted, enum/scalar serialization), fragments (inline,
named, interface conditions), union- AND interface-typed fields
(__typename dispatch, required at generation time), enums (T::Enum),
custom scalars (name-keyed SCALAR_CASTS / SCALAR_SERIALIZERS registries).
Sources: live schema / introspection JSON / SDL — byte-identical output
(enum values + abstract-type members sorted for determinism).
Transport: executor: kwarg — in-process schema or HttpExecutor (e2e spec
against WEBrick). Federation supergraph SDL loads transparently (needs
directive_defaults_patch until upstream fix ships).

## Next steps (in rough order)

~~Extraction~~ DONE 2026-07-07: this repo IS the gem now — GraphWeaver,
github.com/dpep/graph_weaver, rspec-uuid conventions throughout. The
graphql-client spikes live in git history (tag: `exploration`) and
NOTES.md. Prior-art check partially answered: graphql-client PR #7
(tapioca compiler over schema-wide dynamic classes) stalled since
Jan 2024 with users asking; schema-wide typing can't catch
unfetched-field bugs or type unions/interfaces — the niche looks open.

1. Stable class naming design — names come from GraphQL type names per
   selection site; must not shift when unrelated selections are added
   (generated code is app-code API). Current: one-level field-name
   disambiguation, then raise.
2. Input objects as variables (raise NotImplementedError today) — likely
   generated T::Structs with serialize.
3. CLI entrypoint (graph_weaver generate --schema X --queries dir) —
   bin/generate is spec-fixture tooling, not shipped.
4. Subscriptions (unsupported; raise).
5. First release: 0.1.0 to rubygems once naming design settles.
6. Nice-to-haves: __typename auto-injection (currently required manually
   on abstract selections), fragment reuse across queries, directives on
   selections (@skip/@include make non-null fields nullable).
7. Tapioca DSL compiler over dynamic mode (idea from graphql-client
   PR #7): RBI the GraphWeaver::Codegen.load-eval'd modules so development mode
   gets static types without the bin/generate build step — tapioca is
   already in every Sorbet shop's workflow. Upstream's
   Tapioca::Dsl::Helpers::GraphqlTypeHelper is prior art for type mapping.

## External dependencies

- rmosolgo/graphql-ruby#5659 (directive-argument defaults fix; our branch
  `directive-argument-defaults` in ~/code/lib/ruby/graphql, pushed to the
  dpep fork, PR in draft). When it ships in a release: bump graphql,
  delete lib/graph_weaver/directive_defaults_patch.rb + its requires (TODO in file).

## Gotchas worth remembering

- graphql-ruby to_definition/from_introspection reorder enum values and
  possible_types — codegen sorts both; keep any new emission deterministic
- schemas built from introspection/SDL have no scalar coercion or
  resolvers — codegen must stay name-keyed, never call schema runtime hooks
- graphql-client (the gem) casts scalars via coerce_isolated_input and
  only with a live schema class — documented in the early specs
