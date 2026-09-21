# Round 7 triage

## junior-fragments (sonnet, checkout 89ded3e) — 16 min to green, never opened lib/, would stay
Worst: paper cut. All three → scribe pass.
- doc: a `:wire` refusal fires in the tag's before-hook, so it can't be asserted
  with `expect { }.to raise_error` in the example — say so in testing.md (and
  how to assert it if there is a way: a group-level `around` or `rspec --tag`).
- doc: `:in_process` derives the live class ("the loaded class that defines
  everything the schema declares"); `:wire` doesn't take that fallback and serves
  a fake with a warning naming `config.schema = ...`. Document the two
  derivations side by side in testing.md.
- doc: a `:fake` pin `"Pet.species" => "RABBIT"` (undeclared) is accepted and
  routes through the fallback catch-all, unlike a typo'd field which is refused.
  One sentence in testing.md#pins: values aren't checked against the enum, only
  coordinates are; with `fallback: true` that is a way to rehearse drift.

## junior-migrate (sonnet, published 0.7.5) — 6.5 min whole migration, never opened lib/, would stay
Worst: quiet where it should speak (one). Rest paper cuts → scribe pass.
- QUIET: `schema:refresh` rewrites a dump graphql-client still reads (both gems
  in the Gemfile per migrating.md step 1): 2015 pretty lines → one compact line
  plus the `graph_weaver:` provenance key. Parsed fine by luck. Two fixes: (a)
  doc sentence in migrating.md step 2 ("refresh rewrites the file in place in
  graph_weaver's format; if another client reads this path, check it tolerates
  that"); (b) CODE, small: write the dump pretty-printed so a git diff of a
  schema dump stays readable — worth doing regardless of migration (tasks.rb /
  schema_loader.rb write path). → (a) scribe now; (b) a small lane.
- doc: getting_started's client section should say "no auth? omit `auth:`" —
  the only full constructor example always shows `auth:`.
- doc: migrating.md step 3 (register scalars/enums) is a silent no-op on an API
  with none; say the step is conditional.
- note: the Countries API has no enums; a repeat of this brief should pick an
  API with one for the drift exercise (PokeAPI has enums? check) — briefs.md.
- win: 0.7.5 hoist held on the published gem: `CountryFields = GraphQLTypes::CountryFields` in both modules.

## hunt7 (opus skeptic, checkout 89ded3e) — 24 findings; worst: publish-blocker (F1)
Codegen clean: object_node byte-identical over 4,057 files / 6 schemas; 33,720 round trips 0 failures.
Lanes: T (tasks/graph/loader): F1 F2 F8 F11 F16 F17 F18 F23. U (unused+installer+gemspec): F4 F5 F21 + non-git-checkout specs.
C (codegen/enums): F3 F12 F14 F15 F19 + the optional: hunch. F (testing/fake/overrides): F6 F7 F9 F10 F13 F20 F22 F24 + pin/null_chance/"default" paper cuts.
Scribe (after): as_json "__other__" sentence; client-contract signature (transports/generated_modules/CLAUDE.md); "both" for three;
got NilClass unreachable; testing.md:219 discovery claim; plus junior items above.
