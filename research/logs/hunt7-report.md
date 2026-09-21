# Hunt 7 log — the skeptic

Started 2026-09-20 20:49 local. Repo READ-ONLY at 89ded3e. Scratch under
/tmp/claude/graph_weaver/round7/hunt7-app.

## 20:49 — orientation
Read brief-hunt.md, brief-common.md, follow-ups.md. HEAD confirmed 89ded3e, tree clean.

## 20:55 — probe harness
`/tmp/claude/graph_weaver/round7/hunt7-app/probe/gen.rb DIR` — DIR holds
schema.graphql, queries/*.graphql, optional fragments/*.graphql and setup.rb.
Drives `GraphWeaver.generate!(schema:, queries:, output:)` with
`GraphWeaver.fragments_paths` pointed at DIR/fragments. Gemfile: `path:` at the
checkout, graphql + sorbet-runtime + rspec. `bundle install` clean.

## 21:00 — F1 CONFIRMED: two shared fragments camelizing to one class silently merge
p1: fragments `petFields { id name }` and `PetFields { id age }`, one query
spreading each as a whole field. Generation SUCCEEDS. `types.rb` emits
`require_relative "types/pet_fields"` TWICE; one `types/pet_fields.rb` survives
(id/name). `one_query.rb` emits a single alias `PetFields = GraphQLTypes::PetFields`
and types BOTH `pet` and `other` as it. `other` selects `{id age}` on the wire and
is decoded as `{id name}` → `age` dropped, `name` always nil. srb tc cannot see it.
`check_shared_collisions!` (codegen.rb:230) compares hoisted names against enums
and input types only — never hoisted-vs-hoisted.

## 21:05 — H1 FALSIFIED: input strictness around `fallback: true`
p3. `Species::Other` AND the raw wire string `"__other__"` are both refused, verbatim:
  $species of Pet: GraphQLTypes::Species::Other absorbs values the server added,
  so there is nothing to send for it — expected one of: CAT, DOG (got "__other__")
Nothing to report. Moving on.

## 21:07 — F2: `as_json` of an absorbed enum writes `__other__`
p2 runtime: from_h({"species"=>"FERRET"}).as_json => {"species"=>"__other__"}.
docs/scalars.md "Three things follow from that, and they are the whole rule" lists
three; this is a fourth. generated_modules.md:94 sells as_json as "what a cache
entry, a log line or a JSON API response wants".

## 21:10 — H2 FALSIFIED (mostly): client contract kwarg
`execute!` against a fake with `execute(query, variables:)` raises
`ArgumentError: unknown keyword: :operation_name`. Not new — CHANGELOG:3515
announced it in an older release. BUT query_module.rb:98 still refuses with
"client must respond to #execute(query, variables:)" (mirrored at
docs/generated_modules.md:851 and CLAUDE.md:87) while docs/transports.md:45 says
`execute(query, variables:, operation_name:)`. Inconsistent contract statement.

## 21:18 — F1 strengthened
p4: `fragment petFields on Pet {id name}` + `fragment Pet_Fields on Owner {email age}`,
different TYPES, both spread as whole fields in one query. Still generates. `owner`
is typed `PetFields` (the Pet one). Runtime:
  GraphWeaver::CastError: failed to cast response into GraphQLTypes::PetFields: key not found: "id"
p1 runtime (same type, all surviving props present) is silent:
  r.other.name => nil   (the wire sent no name)
  r.as_json    => {"pet"=>{"id"=>"1","name"=>"Rex"}, "other"=>{"id"=>"2","name"=>nil}}
  — `age`, which the wire DID send and the query DID ask for, is gone.
Mechanism: generate_types builds one node per hoisted name, emit_types_files keys
the plan by FILENAME, so the second node overwrites the first in the Hash before
refuse_duplicate_file! iterates the merged keys. The duplicate
`require_relative "types/pet_fields"` in types.rb is the visible tell.
Multi-graph is NOT affected: refuse_duplicate_types! (graph_weaver.rb:938) guards it.

## 21:20 — delegated three lanes
- objnode/round-trip (exported trees, byte-identity claim + widened property test)
- docs samples (generated_modules/scalars/testing/migrating/getting_started §5)
- Rails host seam + schema tasks (Graph#source rule, installer .gitattributes)
Mine: hoisting, enums, testing surfaces (:wire, null_chance, pins, Router).

## 21:35 — H3 FALSIFIED: `:wire` per graph works as documented
/tmp/claude/graph_weaver/round7/hunt7-app/wire/wire_spec.rb, 2 graphs (`:shop`
url + live class, `:local` a graphql-ruby class in the client slot, no url).
3 examples green. Log verbatim:
  INFO: :wire has no endpoint for graph :local — its client posts to none, so its modules run above the wire, as graphql: :in_process would
  INFO: :wire serving Shop::Schema (in-process) at https://shop.example.com/graphql
Shop crosses the wire (POST + HTTP 200 in the log), Local runs in-process. Both in
one example works. Nothing to report on the happy path.

## 21:40 — F3: the above-the-wire graph inherits the SERVED graph's refusal
wire/wire2_spec.rb: graph :local has a client that posts nowhere AND no schema.
It runs above the wire (by design), then refuses with the endpoint message:
  :wire serves your schema at the endpoint your client posts to, and graph :local
  has none to serve — no live GraphQL::Schema class, no composed supergraph, and no
  type information (nothing at app/graphql/schema.json, and
  GraphWeaver::Testing.config.schema is unset). Your client's own schema can't stand
  in here: reading it introspects the endpoint :wire has stubbed. Commit a dump
  (rake graph_weaver:schema:refresh URL=…), or tag the example graphql: :live.
Three sentences are false for this graph: its client posts to no endpoint, :wire
stubbed no endpoint for it, and there is no URL to pass to `schema:refresh URL=`.
The fix that applies — give the graph a `schema` — is the one it doesn't name.
wire_mode (test_clients.rb:167) has the graph in hand and doesn't branch on
client_url.

## 21:50 — F4: hoisting silently skips the two degenerate abstract shapes
p8. `fragment NodeFields on Node { id label }` (interface-level fields only, no
`... on`) spread as a whole field in two queries:
  one_query.rb: class Node  < T::Struct   (OneQuery::Result::Node)
  two_query.rb: class Other < T::Struct   (TwoQuery::Result::Other)
No types.rb at all. Two unrelated structs with identical props, named for the
RESPONSE KEY — exactly the state the hoisting change says it fixed.
p7: the same for a union fragment narrowing to exactly one member
(`fragment itemFields on Item { __typename ... on Post { id body } }`) →
`Feed` and `Feed2`, position-named.
Boundary confirmed: add ANY interface-level field beside one `... on`
(`{ __typename id label ... on Post { body } }`) and it hoists to
`GraphQLTypes::NodeFields`. So the trigger is whether `abstract_field`
(codegen.rb:929) falls through its first two branches:
  conditions.empty?                                  -> abstract_level_struct
  conditions.size == 1 && shared.empty? && OBJECT    -> narrowed_struct
  hoistable_spread                                   -> hoisted_ref      <-- 3rd
Docs say "Object or abstract, same sentence" and list five non-hoisting shapes;
these two are not among them. Adding a second `... on` to such a fragment later
moves every consuming query's constant with no warning.
Note the fix is NOT just reordering: `hoisted_fragment` (codegen.rb:207) has a
two-way object/union split, so it cannot express the interface-level-only struct
that `abstract_level_struct` builds. (source reading, not run)

## 21:52 — H4 FALSIFIED: `parse` vs `generate!` hoisting asymmetry is documented
`client.parse` on a query that spreads a hoistable fragment gives
`GraphWeaver.parse::Parsed::Result::Pet`, not `GraphQLTypes::PetFields`.
docs/generated_modules.md:420 says so: "dynamic `parse` inlines everything."
`check_query` behaved as documented on all three inputs (valid, typo, unparseable).

(Times above 21:0x onward were estimated; real clock was ~21:00 at the F4 entry.)

## 21:05 — F5: the abstract-mixin refusal tells you to do what you already did
p10. `extend_type("Pet", PetHelpers)` where PetHelpers declares `name` and `age`
abstract; `fragment PetFields on Pet { id name }` spread as a whole field:
  GraphQLTypes::PetFields includes PetHelpers, which declares "age" abstract — this
  selection does not provide it, and every struct generated from Pet includes the
  mixin, so `srb tc` fails on this one. Select it here, or select Pet through one
  shared fragment (`{ ...Frag }`), which hoists one struct for every query to share.
The subject IS the hoisted struct. Same message, unbranched, for the non-hoisted
case (OneQuery::Result::Pet) — refuse_unsatisfiable_mixin! (codegen.rb:1564) has
`@name` in hand and doesn't look at it.

## 21:08 — H5/H6/H7 FALSIFIED
- Pruning: p11 regenerates after a query stops spreading the fragment;
  types.rb, types/pet_fields.rb and the types/ dir all go. Clean.
- Multi-graph namespaces: p12, two graphs with different `Pet.name` types, both
  spreading one shared fragment — NsA::GraphQLTypes::PetFields (String) and
  NsB::GraphQLTypes::PetFields (Integer), each query aliasing its own. Correct.
  refuse_duplicate_types! fires when two graphs share a types module.
- QueryModule#query_string / #operation_name: correct on a generated module, a
  parsed named operation, and a parsed anonymous one (takes the parse `name:`).
- `used_union_names` -> `used_fragment_names` is in docs/upgrading.md:37 and
  spec/support/public_surface.txt.

## 21:10 — baseline suite
Exported 89ded3e to /tmp/claude/graph_weaver/round7/hunt7-export, bundle install,
`bundle exec rspec`: 2114 examples, 3 failures — ALL THREE are artifacts of the
export not being a git repo (the gemspec's `git ls-files` writes
"fatal: not a git repository" to stderr and three specs capture subprocess output
with 2>&1). Baseline is green. Noted as a robustness paper cut only.

## 21:12 — F6 (paper cut): grammar in the three-spelling enum refusal
p9, `enum Status { OTHER Other other ACTIVE }`:
  enum Status values OTHER and Other and other both become the constant Other — ...
"both" for three values. The suggested `alias:` line is correct and works.

## 21:20 — H8 FALSIFIED: Router really does read its context once per execute
/tmp/claude/graph_weaver/round7/hunt7-export/ctx_probe.rb — the repo's own
RouterGraph supergraph, `fetch` wrapped to record the context each hop got and to
reassign `router.context = { who: "mallory" }` after the FIRST hop:
  ["products", "alice"]
  ["reviews", "alice"]
  second execute: [["products", "mallory"], ["reviews", "mallory"]]
Both hops of the in-flight query kept the identity it started with; the
reassignment took effect for the next execute. router.rb:331 reads it once,
above both the verbatim and the stitched path. Fix is real.

## 21:22 — H9: `alias:` + hoisted struct, both halves correct
p13. Ends on a hoisted struct: emits `sig { returns(T.nilable(PetFields)) }
def first_pet = pets.first`. Reads through one:
  OneQuery: alias "first_pet_name" on Owner: 'name' is inside the shared fragment
  PetFields, which hoists to GraphQLTypes::PetFields — a path can't read into it.
  Register the alias on Pet, or select a field beside the spread to keep the
  struct local — pass optional: true to skip selections that don't fit
`optional: true` does silently drop the accessor. Reported as a hunch only: for a
THROUGH-hoisted path the accessor can never exist for any query that spreads the
fragment, so the advertised escape deletes the registration everywhere in silence.

## 21:25 — the fake/null_chance lane reported (see its findings in the final report)

## 21:35 — F7: `unused` now reports every selection of a before_action-loaded query
u1/. Query `{ pet { id zzqname zzqage } }` (prop names chosen so nothing else in
the swept tree mentions them). Controller:
  class PetsController
    before_action :load_pet
    def load_pet
      @result = PetQuery.execute!
    end
    def show
      render json: @result
    end
  end
Today (89ded3e):
  app/graphql/queries/pet.graphql: Pet.id — selected, never read (PetQuery::Result::Pet#id)
  ... and the other three. `4 selections, 4 unread`. STRICT=1 exits 1.
Pre-change emulation (SCOPE replaced with a never-matching regex,
/tmp/claude/graph_weaver/round7/hunt7-app/unused_pre.rb):
  PetQuery: every prop counted as read — handed whole to a serializer at
  app/controllers/pets_controller.rb:9, as `result`
So it is a regression from dae7c4e. Mechanism: unused.rb:195
`locals.clear if SCOPE.match?(line)` clears the whole table at the next `def`,
and ASSIGN (`/\b([a-z_]\w*)\s*=[^=~]/`) captures `result` from `@result` with the
sigil dropped, so the sweep can't tell a method-scoped local from an
instance-scoped ivar. An ivar's claim should survive `def`.
Same-method ivar and same-method local both still credited correctly.

## 21:40 — H10 FALSIFIED: mapped-enum TO_WIRE with alias: is right
p14. `enum Status { LEGACY_MODE legacy_mode ACTIVE }` mapped onto AppStatus with
`alias: { "legacy_mode" => "LEGACY_MODE" }`:
  STATUS_FROM_WIRE: "ACTIVE"=>Active, "LEGACY_MODE"=>Legacy, "legacy_mode"=>Legacy
  STATUS_TO_WIRE:   Active=>"ACTIVE", Legacy=>"LEGACY_MODE"
The target spelling is what goes out, both in `as_json` and in the variable
coercion. 0.7.4 fix holds.

## 21:42 — spot-check of the Rails lane's F2, from source
graph.rb:167 `def source = dump_source || client_url`; `dump_source` is the dump's
provenance url else the graph's OWN `live_schema`; `client_url` (graph.rb:182)
returns nil for a schema class in the client slot, and says so in its comment.
So a graph declaring `schema "db/x.json"` + `client DemoSchema` has source == nil
while `source_transport` falls through to the client object and works. The
Unreleased entry ("a dump with neither but a client naming a server is
re-introspected through that client") is true only when that client posts to a url.
Confirmed independently of the lane's repro.

## 21:50 — corroborations
- Docs lane's `Pet.ID` finding reproduced independently in my own u1 fixture:
    app/graphql/queries/pet.graphql: Pet.ID — selected, never read (PetQuery::Result::Pet#id)
  for `query Pet($id: ID!) { pet(id: $id) { id zzqname } }`. (It only surfaces
  when nothing else in the swept tree writes `id:` — my earlier controller did.)
- Rails lane's supergraph finding verified from source: schema_loader.rb:736
  `raise ... if composed_dump?(cache) && !federation_sdl?(content)` and
  schema_loader.rb:204 `federation_sdl?(sdl) = sdl.match?(/@join__\w/) || ...`.
  A `directive @join__field(...)` DEFINITION in the introspected SDL satisfies the
  predicate, so the guard passes while every join APPLICATION is discarded.
- Rails lane's F2 verified from source: graph.rb:167/182 (see 21:42).
- Docs lane's as_json `__other__` finding is the same as my F2 (p2), found
  independently by both lanes.

---

# REPORT — Hunt 7, the skeptic

Repo READ-ONLY at 89ded3e, tree clean, nothing committed. Everything I built is
under /tmp/claude/graph_weaver/round7/hunt7-app (my probes), hunt7-export (a
tarball of 89ded3e, for running the suite and the router fixture), and the three
delegated lanes' own directories (hunt7-docs, hunt7-rails, hunt7-fake, hunt7-objnode).

Baseline gates on the export: `rspec` 2114 examples / 0 real failures (3 are
artifacts of the export not being a git repo — the gemspec's `git ls-files` writes
to stderr and three specs capture subprocess output with 2>&1); `srb tc` clean;
`bin/generate` "already up to date".

The findings are in the final message. This file is the working log above.
# Hunt 7 — the skeptic. Full report

Repo READ-ONLY at 89ded3e; `git -C ... status` clean; nothing committed, no worktree.
Scratch: /tmp/claude/graph_weaver/round7/hunt7-app (mine), hunt7-export (a `git archive`
of 89ded3e, for the suite + the router fixture), hunt7-docs, hunt7-rails, hunt7-fake,
hunt7-objnode (the four lanes I ran).

**Premise, and how it came out.** The brief's premise was that the last two rounds
created as many bugs as they fixed. Partly true, and asymmetrically so. The *codegen*
work is in excellent shape — the `object_node` byte-identity claim survived 4,057
generated files across 6 schemas and 2,027 queries, and 33,120 round trips found
nothing. The *task and lint* surface is where the new bugs are: five of the seven
worst findings are in `tasks.rb`, `graph.rb`, `schema_loader.rb` and `unused.rb`,
and three of those are regressions from the Unreleased block itself.

## Baseline gates (on the export, since I may not write to the checkout)
- `rspec` — 2114 examples, 3 failures, **all three artifacts of the export not being a
  git repo**: the gemspec runs `git ls-files`, which writes `fatal: not a git
  repository` to stderr, and `spec/faraday_spec.rb:19`,
  `spec/federation_drift_spec.rb:313`, `spec/log_subscriber_spec.rb:103` each capture
  subprocess output with `2>&1`. Same 3 at `--order rand:1` and `--order rand:7331`.
- `srb tc` — `No errors! Great job.`
- `bin/generate` — `already up to date`
- `bin/federation-diff` — `matches the schemas here, field for field and type for type
  (checked 3 of 3 subgraphs)`
So the tree is green; everything below is something the gates cannot see.

## 1. Matrix — what I drove × outcome

Mine (probe harness `/tmp/claude/graph_weaver/round7/hunt7-app/probe/gen.rb DIR`):

| # | driven | outcome |
|---|---|---|
| p1 | two shared fragments camelizing to one class, same type | **F3 — silent merge** |
| p4 | same, on two different types | F3 — `CastError` instead of silence |
| p6 | hoisted fragment named after a schema enum | guarded, good refusal |
| p7 | union fragment narrowing to one member | **F12 — does not hoist** |
| p8 | `fragment X on SomeInterface { id label }` in two queries | **F12 — does not hoist** |
| p8b | same + one interface-level field beside a `... on` | hoists — boundary found |
| p2/p3 | generated enum `fallback: true`, `Other`/`Other2`, inputs | as documented; **F24** on `as_json` |
| p9 | `enum Status { OTHER Other other ACTIVE }` | refuses well; **F26** grammar |
| p10 | `abstract!` mixin unsatisfied by a hoisted struct | **F14 — circular advice** |
| p11 | regeneration after a query stops spreading a fragment | prunes cleanly |
| p12 | two namespaced graphs, one shared fragment, different field types | correct |
| p13 | `alias:` ending on / reading through a hoisted struct | both correct |
| p14 | mapped enum + `alias:`, TO_WIRE | correct (0.7.4 fix holds) |
| p15 | unions in interfaces in lists, aliases on the abstract arm, unknown member | correct; exact `from_h`→`as_json` round trip |
| p5 | `check_query` valid/typo/unparseable; `parse` vs `generate!` hoisting | as documented |
| wire/ | `:wire` with a url graph + a url-less graph, separately and together | as documented |
| wire2/ | above-the-wire graph with nothing to serve | **F13 — wrong refusal** |
| u1/ | `unused` with a `before_action`-loaded ivar; with `$id: ID!` | **F4**, **F5** |
| export | router context reassigned mid-execute | correct (0.7.5 fix holds) |
| export | `bin/round-trip` on p15's schema, plain + `--hostile`, 600 cases | 0 failures |

Lanes: docs samples (generated_modules / scalars / testing / migrating / getting_started
§5), Rails host seam + schema tasks (a real Rails 8.1.3.1 app plus seven plain-rake
graph shapes), fake data (`null_chance:`, pins), object_node byte identity +
`bin/round-trip`. Their matrices are in their own logs; their findings are folded in below.

## 2. Findings, ranked by harm

### Tier 1 — silent wrong answer

**F1. `schema:refresh` guts a composed supergraph, says it succeeded, exits 0.**
`schema_loader.rb:736` guards with `composed_dump?(cache) && !federation_sdl?(content)`,
and `federation_sdl?` (schema_loader.rb:204) is `sdl.match?(/@join__\w/) || …`. A gateway
whose introspection still *declares* `directive @join__field(...)` satisfies the predicate,
so the guard passes while every join *application* — the routing table — is thrown away.
Repro: `/tmp/claude/graph_weaver/round7/hunt7-rails/plain/s6b_gateway`,
`rake graph_weaver:schema:refresh`. Verbatim:
```
graph :api
refreshed db/supergraph.graphql from http://127.0.0.1:4568/graphql
```
exit 0; `grep -c join__field` 36 → 3 (the 3 are definitions). Then
`rake graph_weaver:federation:subgraphs` prints `subgraphs: {` / `}` and exits **0** — the
federation gate now proves nothing and says nothing. A 0.7.5 regression: delete the
`client` line and `source` is nil and the file is left alone.
Fix: compare routing tables, not a substring — `SchemaLoader.routing_table?` already
answers the real question; and skip a supergraph graph by name rather than routing it
into `refresh!` to rely on the guard (`tasks.rb:438`'s `&& !graph.supergraph`).
Files: `lib/graph_weaver/schema_loader.rb`, `lib/graph_weaver/tasks.rb`.

**F2. `Graph#source` tests for a url where the docs test for a client, so `queries:check`
gives a false green on a graph whose server is right there.**
`graph.rb:167` `def source = dump_source || client_url`, and `client_url` (graph.rb:182)
returns nil for a schema class in the client slot — but `source_transport` falls through
to the client object and works. So `schema:diff` reaches the server and the other two
insist there is none. Real Rails app, drifted schema, documented `client "DemoSchema"`:
```
$ rake graph_weaver:schema:diff
db/inproc_schema.json vs DemoSchema: 4 changes, 2 breaking
  Pet.name  removed
db/inproc_schema.json is stale …                                        exit 1
$ rake graph_weaver:queries:check
every query validates against db/inproc_schema.json as committed — not the server (rake graph_weaver:schema:diff asks whether the server moved)
                                                                        exit 0
$ rake graph_weaver:schema:refresh
db/inproc_schema.json records no source url and the graph names no client — left as checked in
```
The query is `pet(id: $id) { id name }`, which `DemoSchema` can no longer answer, and
"the graph names no client" is false — `rake graph_weaver:graphs` printed it one command
earlier. This contradicts getting_started.md:447-459 ("or the server the graph's client
names"), and it is the Unreleased headline item's own rule.
Fix: `source` falls back to the client **object**, as `source_transport` already does.
Files: `lib/graph_weaver/graph.rb`, `lib/graph_weaver/tasks.rb`.

**F3. Two shared fragments whose names camelize to one class silently merge.**
`/tmp/claude/graph_weaver/round7/hunt7-app/p1`: `fragment petFields on Pet { id name }`
and `fragment PetFields on Pet { id age }`, one query spreading each as a whole field.
Generation succeeds. `types.rb` emits `require_relative "types/pet_fields"` **twice**, one
`types/pet_fields.rb` survives, and the query module emits a single alias typing *both*
fields as it:
```
  PetFields = GraphQLTypes::PetFields
    const :pet,   T.nilable(PetFields)
    const :other, T.nilable(PetFields)
```
Runtime: `from_h({"pet"=>{"id"=>"1","name"=>"Rex"},"other"=>{"id"=>"2","age"=>7}})` gives
`r.other.name => nil` and `as_json` `{"other"=>{"id"=>"2","name"=>nil}}` — `age`, which the
wire sent and the query asked for, is gone. `srb tc` cannot see it. On two different
*types* (p4) it surfaces as an unexplainable
`GraphWeaver::CastError: failed to cast response into GraphQLTypes::PetFields: key not found: "id"`.
Mechanism: `generate_types` builds one node per hoisted name and `emit_types_files` keys
the plan by filename, so the second overwrites the first before `refuse_duplicate_file!`
iterates the merged keys. `check_shared_collisions!` (codegen.rb:230) compares hoisted
names against enums and input types — never hoisted against hoisted.
Fix: one more pass in `check_shared_collisions!` — a `{class_name => fragment}` map over
`names`, refusing the second. Files: `lib/graph_weaver/codegen.rb`,
`spec/hoisted_fragments_spec.rb`.

**F4. `rake graph_weaver:unused` reports every selection of a `before_action`-loaded query
as unread — a regression from dae7c4e.**
`/tmp/claude/graph_weaver/round7/hunt7-app/u1`, the canonical Rails shape:
```ruby
class PetsController
  before_action :load_pet
  def load_pet = @result = PetQuery.execute!
  def show = render json: @result
end
```
Today: `4 selections, 4 unread`, four `— selected, never read` lines; `STRICT=1` exits 1.
With `SCOPE` replaced by a never-matching regex (unused_pre.rb, emulating pre-dae7c4e):
`PetQuery: every prop counted as read — handed whole to a serializer at
app/controllers/pets_controller.rb:9, as \`result\``. Mechanism: unused.rb:195
`locals.clear if SCOPE.match?(line)` clears the whole table at the next `def`, and
`ASSIGN = /\b([a-z_]\w*)\s*=[^=~]/` captures `result` from `@result` with the sigil
dropped, so the sweep cannot tell a method-scoped local from an instance-scoped ivar.
The CHANGELOG says "reports more, not less, and silence stays the safe direction" — this
is the unsafe direction: a red build telling you to delete fields you render.
Fix: keep the `def` reset for plain locals; let an `@`-prefixed assignment survive it
(the sigil has to be captured to know). Files: `lib/graph_weaver/internal/unused.rb`.

**F5. `unused` prints a coordinate that is not in the query.**
For `query Pet($id: ID!) { pet(id: $id) { id zzqname } }` (reproduced independently in
my own u1 fixture after the docs lane found it):
```
app/graphql/queries/pet.graphql: Pet.ID — selected, never read (PetQuery::Result::Pet#id)
```
`unused.rb:230-243` scans `/[A-Za-z_]\w*/` over the *whole file*, comments included, and
`wire_word` prefers any word whose `prop_name` matches — so `ID` from `$id: ID!` wins.
The doc (getting_started.md:352) says each line names "the selection to go and delete".
Fix: draw candidate words from the parsed selection set, not `source.scan`.
Files: `lib/graph_weaver/internal/unused.rb`.

**F6. An `"Interface.field"` coordinate is accepted and completely inert — for pins,
`list_size:` and `null_chance:` alike.** `Overrides.coordinate!`
(internal/overrides.rb:142) only checks `type.respond_to?(:fields)`, which a graphql-ruby
interface does; `pinnable!`, which correctly refuses an abstract type, is applied only to
the bare-type key. The bare name gives excellent advice —
`override key "Named" names interface Named, and a pin fabricates a scalar, enum or
object: pin the concrete type — "Person", "Robot"` — and the coordinate form sails
through and does nothing, which is exactly what docs/testing.md's Pins section promises
cannot happen. Repro: `/tmp/claude/graph_weaver/round7/hunt7-fake/spec/interface_coordinate_spec.rb`.
Fix: refuse an abstract type in `coordinate!` too. Files: `lib/graph_weaver/internal/overrides.rb`,
`docs/testing.md`.

**F7. The plain-number form of `null_chance:`/`list_size:` is not validated at all.**
`validate_per_field!` opens `return unless option.is_a?(Hash)`. `null_chance: 7`, `-1`,
`NaN` are silently accepted (always/never null); `null_chance: ENV["X"]` gives
`ArgumentError: comparison of Float with String failed` from inside the fabricator,
naming neither the option nor the fake. `list_size: "3"` →
`TypeError: no implicit conversion of String into Integer`; `list_size: -1` →
`ArgumentError: negative array size`. The Unreleased entry sells the refusal as covering
the option; it covers only the Hash. Fix: run the same check over a non-Hash value first.
Files: `lib/graph_weaver/internal/overrides.rb`.

### Tier 2 — crash, or a refusal that misdirects

**F8. `schema:refresh` still abandons every graph after the first failure.** The exit-code
half of the Unreleased claim is fixed; the abandonment half is not — the `rescue … abort`
is outside the loop. A ok → B unreachable → C ok: A refreshes, B errors, **C is never
attempted**. A supergraph graph first: it aborts and graph `:b` is never printed.
Files: `lib/graph_weaver/tasks.rb` (schema:refresh, 411-446).

**F9. docs/testing.md:673's `GraphWeaver.client.check_query(source)` crashes under every
testing mode.** `undefined method 'check_query' for an instance of
GraphWeaver::Testing::FakeClient` / `… GraphWeaver::InProcess`. It is defined only on
`GraphWeaver::Client`, and the paragraph is explicitly about being inside an example.
Fix: delegate `check_query` from FakeClient/InProcess/Router (each holds a schema), or
change the doc. Files: those three, or `docs/testing.md:673`.

**F10. The `:in_process` refusal names a fix that cannot be reached on the tagged path.**
The tag builds the client in its own `before(:each)`, so `graphql_in_process(MySchema)` in
the body is too late — yet the message leads with it:
`:in_process runs your resolvers, so it needs the live GraphQL::Schema class — and
GraphWeaver.client isn't running one in-process to borrow. Name it in the example —
graphql_in_process(MySchema) — or set GraphWeaver::Testing.config.schema = MySchema for
the whole suite. …` Files: `lib/graph_weaver/testing.rb:336`, `lib/graph_weaver/internal/test_clients.rb`.

**F11. `schema:diff`'s verdict depends on which *other* graphs the app has.** `tasks.rb:381`
aborts before the loop when no graph has a dump, so the live-class branch at 388 is
unreachable for a single live-class graph: it prints `no schema dump at
app/graphql/schema.json — take one: rake graph_weaver:schema:refresh
URL=https://api.example.com/graphql` and exits 1, naming a path the app never mentions.
Add an unrelated graph that *does* have a dump and the same graph prints `graph :live
generates from Petstore::Schema directly — no dump to keep in step` and exits 0. That is
the spooky action at a distance CLAUDE.md forbids. Files: `lib/graph_weaver/tasks.rb:381`.

**F12. Hoisting silently skips the two degenerate abstract shapes, including the commonest
one there is.** `fragment NodeFields on Node { id label }` — interface-level fields, no
`... on` — spread as a whole field in two queries gives `OneQuery::Result::Node` and
`TwoQuery::Result::Other`: two unrelated structs with identical props, named for the
*response key*, and no `types.rb` at all. Same for a union fragment narrowing to exactly
one member. `abstract_field` (codegen.rb:929) tries `conditions.empty?` and
`conditions.size == 1 && shared.empty? && OBJECT` **before** `hoistable_spread`. The
CHANGELOG says "object or abstract, same sentence" and the docs list five non-hoisting
shapes; these two are not among them. Adding a second `... on` to such a fragment later
moves every consuming query's constant, silently. Note the fix is not a reorder:
`hoisted_fragment` (codegen.rb:207) has a two-way object/union split and cannot express
the interface-level-only struct. Files: `lib/graph_weaver/codegen.rb`,
`docs/generated_modules.md`, `spec/hoisted_fragments_spec.rb`.

**F13. `:wire`'s above-the-wire graph inherits the served graph's refusal.** A graph whose
client posts nowhere runs above the wire by design, then refuses with the endpoint
message:
```
:wire serves your schema at the endpoint your client posts to, and graph :local has none
to serve — no live GraphQL::Schema class, no composed supergraph, and no type information
(nothing at app/graphql/schema.json, and GraphWeaver::Testing.config.schema is unset).
Your client's own schema can't stand in here: reading it introspects the endpoint :wire
has stubbed. Commit a dump (rake graph_weaver:schema:refresh URL=…), or tag the example
graphql: :live.
```
Three sentences are false for this graph: its client posts to no endpoint, `:wire` stubbed
none for it, and there is no URL to pass. The fix that applies — give the graph a `schema`
— is the one it does not name. `wire_mode` (internal/test_clients.rb:167) has the graph in
hand and does not branch on `client_url`. Repro: `hunt7-app/wire/wire2_spec.rb`.

**F14. The abstract-mixin refusal tells you to do what you already did.** With
`fragment PetFields on Pet { id name }` spread as a whole field and a mixin declaring
`age` abstract:
```
GraphQLTypes::PetFields includes PetHelpers, which declares "age" abstract — this
selection does not provide it, and every struct generated from Pet includes the mixin, so
`srb tc` fails on this one. Select it here, or select Pet through one shared fragment
(`{ ...Frag }`), which hoists one struct for every query to share.
```
The subject *is* the hoisted struct. `refuse_unsatisfiable_mixin!` (codegen.rb:1564) has
`@name` and does not look at it. Files: `lib/graph_weaver/codegen.rb`, `spec/abstract_mixin_spec.rb`.

**F15. A mapped-enum member the schema doesn't declare gives a bare `KeyError`.**
Exhaustiveness checks schema→member only, so `SPECIES_TO_WIRE.fetch(member)` misses:
`GraphWeaver::InputError: $species of AddPet: key not found: #<PetKind::Ferret>`, and on
the result side a plain `KeyError` that isn't even a GraphWeaver error. One line away, the
sibling path is exemplary. Files: `lib/graph_weaver/codegen/enum_type.rb`, `lib/graph_weaver/input_struct.rb`.

**F16. `schema:diff` aborts (exit 1) on the shape `refresh` deliberately skips (exit 0).**
A dump with no provenance and no client: `refresh` says "left as checked in" and exits 0;
`diff` aborts the whole run with `records no source url — pass one: …`.
Files: `lib/graph_weaver/tasks.rb`.

**F17. `client -> { … }` is accepted silently, then leaks a rake backtrace.**
`NoMethodError: undefined method 'execute' for an instance of Proc` with 11 frames — the
one refusal in these tasks that isn't a clean abort, and an easy mistake because the same
docs page mandates a lambda for `schema`. Files: `lib/graph_weaver/graph.rb`.

**F18. `queries:check` names neither the graph nor the dump when a server is unreachable.**
In a multi-graph app the entire output is
`Errno::ECONNREFUSED: … — POST http://127.0.0.1:1/graphql`, and the other graph's queries
were never checked. This is the first thing a 0.7.4→0.7.5 CI sees, given the Action.
Files: `lib/graph_weaver/tasks.rb`, `lib/graph_weaver.rb`.

**F19. Most lines of a multi-query refusal list don't name the file.** Only 3 of 33
`raise GraphWeaver::` sites in codegen.rb interpolate `@path`, so `3 of 3 queries refused:`
lists two anonymous entries — defeating the point of the list, which is to fix a directory
in one pass. Fix: wrap in `generation_plan`'s rescue, which has `path`.
Files: `lib/graph_weaver.rb`.

**F20. `check_scalars!`'s cast refusal still says `overrides: { "Money" => … }`** — and
`check_scalars!` takes one positional argument, so following it literally gives
`ArgumentError: wrong number of arguments (given 2, expected 1)`. The Unreleased entry
fixed the two rspec-facing spellings and missed this one, which docs/scalars.md documents
as being run inside an `it` block. The new three-door message, when reached through
`check_scalars!`, leads with `graphql_fake(…)`, which is a no-op there.
Files: `lib/graph_weaver/testing.rb`.

### Tier 3 — quiet where it should speak

**F21.** `.gitattributes` "skipped where already marked" is `body.include?(glob)` over the
whole file: a comment mentioning the path suppresses the mark silently, and
`app/graphql/generated/ linguist-generated` (no `**`) isn't detected so a redundant line
is appended. Files: `lib/generators/graph_weaver/install_generator.rb`.
**F22.** `graphql_context` refuses on an untagged example that *is* running against
resolvers (`GraphWeaver.client` is an `InProcess`) — the guard reads the tag, not the mode.
Files: `lib/graph_weaver/rspec.rb`.
**F23.** A hand-maintained dump whose descriptions differ from the server is permanently
`is stale` with `(schema) changed in ways this summary doesn't name — compare the dumps`,
and the only advice is the newly destructive `refresh`. Ordering and comments are fine;
descriptions are not. Files: `lib/graph_weaver/schema_diff.rb`, `lib/graph_weaver/tasks.rb`.
**F24.** `null_chance: { "Person.id" => 1.0 }` on a non-null field is accepted and inert;
`null_chance: { "Person" => 1.0 }` is refused with `did you mean 'person'?`, which is a real
key that nulls the whole subtree. Files: `lib/graph_weaver/internal/overrides.rb`.

### Tier 4 — paper cuts

- `as_json` of an enum that absorbed a value writes the sentinel `"__other__"`. The stated
  law (`from_h(JSON.parse(to_json)) == result`) holds, but `render json: result` now emits
  a value no server declares, and scalars.md's "three things follow … and they are the
  whole rule" lists three. Found independently by two lanes. (`docs/scalars.md`)
- The client-contract refusal says `#execute(query, variables:)`; the real contract is
  `execute(query, variables:, operation_name:)` (docs/transports.md:45 has it right, and
  the mismatch raises `ArgumentError: unknown keyword: :operation_name`). Mirrored at
  docs/generated_modules.md:851 and in CLAUDE.md's design-invariant line.
  (`lib/graph_weaver/query_module.rb:99`, `docs/generated_modules.md`, `CLAUDE.md`)
- `enum Status values OTHER and Other and other both become the constant Other` — "both"
  for three. The suggested `alias:` line is correct and works. (`lib/graph_weaver/codegen.rb`)
- docs/generated_modules.md:851's quoted `got NilClass` is unreachable — the nil path
  raises `no client configured — set GraphWeaver.client= or pass a client` first.
- docs/testing.md:219 describes discovery ("the live schema class is found for you … if
  two loaded classes match") that the code does not do — it is `config.schema`, else the
  graph's, else whatever `GraphWeaver.client` already runs in-process.
- A pin beats `null_chance:` on the same field, silently and undocumented.
- `"default"` as a `null_chance:` key always means the fallback, so a schema field named
  `default` is reachable only by the coordinate form.
- `check_scalars!`'s "round-trips lossily" prints two identical `inspect`s when the app
  class defines no `==`, and doesn't say that's why.
- Three specs fail in a checkout that isn't a git repo (an unpacked gem, a vendored copy,
  a shallow CI export): the gemspec's `git ls-files` writes to stderr and they capture
  `2>&1`. Cost me ten minutes deciding the baseline wasn't red.

## 3. Hypotheses I falsified (as valuable as the findings)

- **The `object_node` byte-identity claim is true.** 4,057 generated files, 6 schemas
  (including 3 live public introspection dumps), 2,027 queries — byte-identical across the
  refactor window, including every refusal string, prop order and `from_h` body. Every
  shape the brief named was driven by name. A negative control (the object-fragment hoist
  at HEAD) proved the harness detects real diffs.
- **`bin/round-trip` found nothing** — 33,120 trips across 49 invocations, plain and
  `--hostile`, at four times the suite's count, on schemas it has never seen and a 312 KB
  real dump. Plus 600 of my own on p15's schema.
- **`Testing::Router` really does read its context once per execute.** Wrapping `fetch` on
  the repo's own supergraph and reassigning `router.context =` after the first hop:
  `["products","alice"], ["reviews","alice"]`, then `[["products","mallory"],
  ["reviews","mallory"]]` on the next execute. The 0.7.5 fix is real.
- **`:wire` per graph works exactly as documented.** Both log lines appear verbatim; Shop
  crosses the wire (POST + HTTP 200), Local runs in-process, both in one example.
- **Inputs stay strict around `fallback: true`** — both `Species::Other` *and* the raw wire
  string `"__other__"` are refused. I expected the string to slip through; it doesn't.
- **Multi-graph namespaces are correct**, and `refuse_duplicate_types!` guards two graphs
  sharing a types module. Two graphs with different `Pet.name` types get their own structs.
- **Hoisted-type pruning is clean** — stop spreading the fragment and `types.rb`,
  `types/pet_fields.rb` and the `types/` directory all go.
- **The mapped-enum `alias:` TO_WIRE fix (0.7.4) holds** — the target spelling goes out in
  both `as_json` and the variable coercion.
- **All five documented non-hoisting shapes behave**, individually verified.
- **Both halves of the `alias:`-and-hoisting rule hold**, with a good refusal.
- **`check_query` at getting_started.md:324 is byte-identical** to what runs, `"column" => 37`
  included; `parse` vs `generate!` hoisting asymmetry is documented at
  generated_modules.md:420.
- **`QueryModule#query_string`/`#operation_name`** are correct on a generated module, a
  parsed named operation and a parsed anonymous one.
- **The exotic shape round-trips exactly**: unions inside interfaces inside lists with
  aliases on the abstract arm and an unknown union member — `from_h` → `as_json` equals the
  input hash, dispatch and `Other` correct.
- **Value validation of the `null_chance:` *Hash* form is airtight**, `NaN` included, and
  spellchecking is real and good.
- **`.gitattributes` is idempotent, one line per graph, and handles a missing trailing
  newline**; two of six spellings are detected correctly.

## 4. Design critique, from the evidence lens

**The codegen has a safety culture; the tasks don't.** Every collision in `generate_types`
has a named refusal — except the one nobody thought of (F3), and the guard is one loop
short of covering it. The tasks, by contrast, ship three ways to lose data or pass a CI
gate that proves nothing (F1, F2, F4), and they do it *by adding a source of truth*
(`Graph#source`) whose predicate doesn't match the sentence the docs use to describe it.
The lesson is narrow and actionable: **when a change's value is "one rule for every
graph", the rule needs a single function and one caller apiece.** Today `source`,
`source_transport` and `client_url` are three functions that disagree, and the refusal
text ("the graph names no client") is written against a fourth idea.

**"Refuse rather than guess" is applied to arguments and not to outcomes.** The library is
excellent at refusing a *malformed input* — a bad coordinate, a bad enum spelling, an
unpinned scalar. It is much weaker at refusing an *inert* one: an interface coordinate that
matches nothing (F6), a non-null `null_chance:` (F24), a plain `null_chance: 7` (F7), two
fragments landing on one class (F3). The failure mode is the same each time — the check
answers "is this well-formed?" instead of "will this do anything?" — and that is the check
worth adding as a habit, because the well-formed-but-inert case is precisely the one that
leaves a suite green and wrong.

**Three refusals now point at the state the reader is already in.** F13 tells an
above-the-wire graph about the endpoint it doesn't have; F14 tells you to hoist the struct
that *is* hoisted; F10 names a call that cannot run on the path that raised. All three are
messages written for one branch and then reached from a second that was added later. The
gem's own principle says errors are part of the interface — which means a *new branch is a
new interface* and needs its own sentence, not the neighbouring one.

**The hoisting rule is stated as one sentence and implemented as the third of four
branches** (F12). That is the "one rule beats a rule with exceptions" principle failing
quietly: the exceptions exist, they are undocumented, and they cover the most ordinary
interface fragment anyone writes. Either hoist those shapes or say in the docs that an
abstract fragment must name at least one concrete condition *and* something beside it.

**What is genuinely strong, and worth saying so:** the `object_node` restructure is the
cleanest refactor evidence I have seen — byte-identical across four thousand generated
files, with a negative control proving the measurement. The round-trip property test is
real and earns its place. The router context fix is correct. `:wire` per graph is a good
design, implemented correctly, with log lines that say what it chose. The refusal *prose*,
where it is aimed at the right branch, is better than most libraries manage.

## 5. Times I read source, and why

- `codegen.rb` `generate_types` / `hoisted_fragment` / `check_shared_collisions!` — to
  find what the collision guard covers, which is how I predicted F3 before running it.
- `codegen.rb` `abstract_field` / `hoistable_spread` / `hoisted_fragment` — to explain why
  p7 and p8 didn't hoist, and to establish that F12's fix isn't a reorder.
- `codegen.rb` `refuse_unsatisfiable_mixin!` — to confirm F14's message is unbranched.
- `internal/test_clients.rb` `for` / `standin` / `wire_mode` — to predict the per-graph
  `:wire` dispatch before driving it, and to locate F13's missing branch.
- `rspec.rb` `serve!` / `wire_targets` / `endpoint!` — same.
- `query_module.rb` `dispatch` / `client_for` — after the unbranded `ArgumentError`, to see
  whether the contract message matched the call.
- `client.rb` `check_query` — to check the `fragments:` default against the doc.
- `testing/router.rb` `execute` — to see whether the context read is above or below the
  plan, before writing the concurrency probe.
- `internal/unused.rb` `sweep` / `READ` / `ASSIGN` / `SCOPE` — to explain F4 and to be sure
  the emulation of pre-dae7c4e behaviour was faithful.
- `graph.rb` `source` / `source_transport` / `client_url` — to verify the Rails lane's F2
  independently of its repro.
- `schema_loader.rb` `federation_sdl?` and the overwrite guard — to verify F1's mechanism
  independently of its repro.
- `internal/overrides.rb` `coordinate!` / `pinnable!` — to verify the fake lane's F6
  independently of its repro.
I read source to *form* a hypothesis cheaply and to *verify a lane's headline claim*
without re-running it. Every finding above still has a run behind it.

## 6. Minutes per step (mine; the lanes report their own)

| step | min |
|---|---|
| Brief, common brief, follow-ups, CHANGELOG, repo layout | 12 |
| Probe harness + bundle | 8 |
| Fragment hoisting: collisions (p1, p4, p6, p7), the degenerate abstract shapes (p8) | 26 |
| Enum fallback / alias / OTHER-Other-other (p2, p3, p9, p14) | 16 |
| Writing the four lane briefs | 14 |
| `:wire` fixture, two-graph spec, the nothing-to-serve case | 22 |
| `check_query` / `parse` / `QueryModule` (p5) | 8 |
| Abstract mixin, pruning, multi-graph namespaces, `alias:` (p10-p13) | 15 |
| Baseline gates on the export (rspec ×3 seeds, srb tc, generate, federation-diff) | 18 |
| Router context probe | 11 |
| `unused` — ivar regression, A/B emulation, `Pet.ID` corroboration | 21 |
| Exotic-shape round trip (p15) + `bin/round-trip` on it | 12 |
| Source reads to verify the three lanes' headline claims | 10 |
| Log + report | 30 |
| **total (excluding the four lanes, which ran in parallel)** | **~3 h 45** |

## 7. Would I ship on this?

Not as it stands, and the blocker is narrow. Three things in the Unreleased block are
worse than what they replaced, and all three are in the same place: `schema:refresh` can
now destroy a checked-in supergraph and report success (F1); `queries:check` now claims a
rule — "the client the graph names" — that `Graph#source` doesn't implement, so a named
graph with an in-process client gets a green CI gate against a schema its server no longer
matches, while `schema:diff` one command earlier said it was stale (F2); and `unused` now
fails a `STRICT=1` build on the most ordinary Rails controller shape there is (F4). F1 is
the one I would call a publish-blocker on its own — it is silent, it is destructive, it
downgrades a federation gate to a no-op that exits 0, and the `Action` note in the
CHANGELOG warns about a *hand-maintained dump* while the supergraph case is the one that
actually loses something irrecoverable. F2 and F4 are a day's work between them and both
have a one-function fix. F3 and F12, which are mine, are real but rarer and could ship as
known issues with a doc line.

What makes me *want* to ship is the other half of the evidence. The codegen — which is the
product — came through everything I could throw at it: byte-identical across a refactor,
33,720 round trips without a failure, a green suite under three orderings, a clean
`srb tc`, and an exotic nested-union-in-interface-in-list query that round-trips exactly.
That is unusually good, and it is the part an adopter's data flows through. The damage is
concentrated in the operational surface, which is also the surface a single release can
fix without touching a line of generated code. Hold the release for F1 and F2, take F4 in
the same pass, and I would sign it.
