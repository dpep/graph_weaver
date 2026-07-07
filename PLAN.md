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

1. Prior-art check before naming: has anyone shipped Ruby+Sorbet GraphQL
   codegen recently (Shopify orbit especially)? Decides gem-for-world vs
   personal tool.
2. Stable class naming design — names come from GraphQL type names per
   selection site; must not shift when unrelated selections are added
   (generated code is app-code API). Current: one-level field-name
   disambiguation, then raise.
3. Input objects as variables (raise NotImplementedError today) — likely
   generated T::Structs with serialize.
4. Extraction: new gem repo (rspec-uuid conventions: gemspec + version.rb,
   CI matrix 3.3/3.4/4, codecov, CHANGELOG), demo schema becomes test
   fixture, CLI entrypoint (generate --schema X --queries dir). Leave this
   repo as the lab notebook.
5. Subscriptions (unsupported; raise).
6. Nice-to-haves: __typename auto-injection (currently required manually
   on abstract selections), fragment reuse across queries, directives on
   selections (@skip/@include make non-null fields nullable).

## External dependencies

- rmosolgo/graphql-ruby#5659 (directive-argument defaults fix; our branch
  `directive-argument-defaults` in ~/code/lib/ruby/graphql, pushed to the
  dpep fork, PR in draft). When it ships in a release: bump graphql,
  delete lib/directive_defaults_patch.rb + its requires (TODO in file).

## Gotchas worth remembering

- graphql-ruby to_definition/from_introspection reorder enum values and
  possible_types — codegen sorts both; keep any new emission deterministic
- schemas built from introspection/SDL have no scalar coercion or
  resolvers — codegen must stay name-keyed, never call schema runtime hooks
- graphql-client (the gem) casts scalars via coerce_isolated_input and
  only with a live schema class — documented in the early specs
