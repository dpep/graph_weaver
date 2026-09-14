# Input-type closure on Hasura-shaped schemas

Main @ fdf0fb1. Repo read-only; all work under `/tmp/claude/graph_weaver/inputs-*`.

## What is actually true

Outputs are query-driven because a selection set *is* the query. An input type has
no selection set, so the only static answer to "what can `$where` hold" is its
transitive closure. That is not a bug in the walk (`codegen.rb:1240` `input_node`,
memoized by GraphQL name, registered before its fields recurse) — it is the honest
answer. The README sentence is the thing that is wrong: **codegen is query-driven
for outputs and closure-driven for inputs**, and it has always been.

## Measurements

**(a) Closure of the junior's two variables, PokeAPI (2262 input types, 176 enums):**

| depth | cumulative input types reached |
|---|---|
| 0 (the declared roots) | 2 |
| ≤1 | 43 |
| ≤2 | 239 |
| ≤3 | 479 |
| ≤5 | 979 |
| saturates at ≤7 | **1035** |

Plus 146 enums = the 1181 files. Separately: `$where` alone reaches 428, `$order_by`
alone reaches 607. 51% of all reachable input fields are themselves input objects.

**(b) GitHub control (402 input types).** Closure size per root: median **1**, p90 **1**,
p99 **8**, max **34**. 90% of GitHub's input types are leaf-shaped. Generating
GitHub's *worst* root (`CreateRepositoryRulesetInput`) emits **43 files / 58 KB**; a
typical mutation emits 2–3. PokeAPI's mean closure is 116; 24% of its roots exceed 100.
The two schemas are three orders of magnitude apart on the same rule.

**(c) Cost.** (M2 Air; Sorbet 0.6.13485; app has no sorbet config, so this is a minimal
config over the generated tree + the gem — not a whole-Rails typecheck.)

| | with the closure | without | delta |
|---|---|---|---|
| `srb tc` wall | 0.22 s | 0.075 s | **+0.15 s** (+0.89 s CPU) |
| `require` of the tree | 0.307 s | 0.003 s | **+0.30 s** |
| peak RSS | 105 MB | 56 MB | **+49 MB** |
| generation | ~1.4 s total, dominated by Rails boot | | ~0.2 s of codegen |

Source is **2.2 MB / 31.6 k lines**, not 5.1 MB — `du` is 1181 files × 4 KB blocks,
so 57% of the headline number is filesystem slack. 1030 of 1181 files (87%) are
`_order_by` / `_bool_exp` / aggregate-bool-exp machinery.

**(d) What the caller gets.** Probed with real `srb tc` runs
(`/tmp/claude/graph_weaver/inputs-work/srbprobe/`):

| call site | `srb tc` | runtime |
|---|---|---|
| `BoolExp.new(heigth: …)` | **caught** (7004) | — |
| `BoolExp.new(height: "tall")` | **caught** (7002) | — |
| fully-typed `.new` chain, typo 3 deep | **caught** | — |
| fully-typed `.new` chain, `IntComparisonExp` on a String column | **caught** | — |
| `BoolExp.new(pokemon_v2_pokemontypes: {…hash…})` | **rejected** — though `coerce` accepts it | — |
| `BoolExp.coerce(heigth: …)` | nothing | refused, `path=["heigth"]`, "did you mean 'height'?" |
| `coerce(…{ nmae: … })` 2 deep | nothing | refused, full path, spellchecked |
| `coerce(name: { _gte: 1 })` | nothing | refused, `type_mismatch`, `path=["name","_gte"]` |
| `where` built from `params` (the junior's controller) | nothing | refused with a path |

The generated `execute` sig is already
`T.nilable(T.any(PokemonV2PokemonBoolExp, T::Hash[T.untyped, T.untyped]))`. The hash
branch is untyped by construction, so **on the path a Rails app actually takes —
`build_where` assembling a Hash from `params`, `pokemon_searches_controller.rb` —
`srb tc` checks nothing, and the runtime `FIELDS` table catches everything.** The
1035 structs earn their keep only on a hand-written fully-typed `.new` chain, which
is the one thing a dynamic filter is never built with.

## Options

| | what the caller writes | `srb tc` still checks | runtime still refuses | PokeAPI | GitHub | one sentence? |
|---|---|---|---|---|---|---|
| **1 status quo** | struct or hash, any depth | everything, on the typed path | everything | 1181 files / 2.2 MB | 43 worst, 2–3 typical | yes: *one GraphQL input type, one Ruby type* |
| **2 depth cutoff N** | hash below N | above N only | above N only (no table below) | N=1→43, N=2→239, N=3→479 | unchanged (max depth ~3) | no — needs N, and *"how deep is my filter"* is not a question a user can answer |
| **3 roots only, nested hash** | hash below the root | root props only | **top-level keys only** — the 2-deep typo and the wrong comparison type both ship | 2 files *if* the tables go too; **~1181 files / 1.5 MB if they stay** | 1–2 files, loses GitHub's genuinely useful nesting | yes, but the asymmetry is invisible at the call site |
| **4 per-graph `inputs: :shallow`** | depends on config | depends on config | depends on config | knob-dependent | knob-dependent | no |
| **5 inline the filter as a query literal** | a variable per leaf | **more** — `T::Array[String]`, not `T::Hash[T.untyped, T.untyped]` | everything, at the leaf | **1 file / 7.7 KB** | unchanged | yes — it's the shape the gem already advises for input collisions |

Option 3's size win is conditional and it is the wrong condition: keeping the per-type
`FIELDS` tables (needed for every refusal in the (d) table below the root) leaves the
file count essentially unchanged, and dropping them deletes the only checking that
fires on this schema. Option 2 is worse still — the junior's real filter,
`pokemon_v2_pokemontypes.pokemon_v2_type.name`, sits at depth 2, exactly on the
boundary a cutoff would have to pick. Option 4 answers a per-schema question with a
per-graph knob and makes the generated shape depend on a config file.

## Recommendation

**Keep the closure (option 1). Fix the sentence, and teach option 5 where the user
will meet it.** The deciding reason: every alternative trades one sentence for two and
buys nothing the measurements say we need — 0.15 s of typecheck and 0.30 s of boot is
an annoyance, not a defect, and option 3, the only one that would really shrink the
tree, deletes the nested runtime refusal that the junior app's entire per-field form-
error demo rests on.

Three changes, none of which alter what is generated:

1. **README/docs**: outputs are query-driven, input types are closure-driven. One sentence.
2. **Generator prints the count** per graph — `PokemonSearch: 1 module + 1181 shared
   types (1035 inputs from $where, $order_by)` — so nobody is surprised by a `git status`.
3. **Document the literal-filter shape.** `codegen.rb:1293` (`input_collision_advice`)
   already tells users to "write that path as a literal in the query, with a variable
   per field". That advice is the whole fix here and it's buried in an error message.

**Proof of concept** (`/tmp/claude/graph_weaver/inputs-work/variants/`, PoC run at
`inputs-work/poc.rb`). Same query, filter inlined, a variable per leaf:

```
$where + $order_by as variables : 1183 files, 2.26 MB
literal where, $order_by variable: 610 files, 1.21 MB
literal where and order_by       :    1 file,  7.7 KB
```

The literal module's sig is
`params(name: T.nilable(String), min_height: T.nilable(Integer), type_names: T.nilable(T::Array[String]), limit: T.nilable(Integer))`
— concrete types `srb tc` genuinely checks, where `$where` gave an untyped hash. It
executes correctly against a fake (filter travels in the query text, `pikachu` comes
back), and refusals land as `path=["minHeight"]` / `path=["typeNames", 0]` — the form
field itself, which collapses the hand-written `form_field_for` case in the junior's
controller.

**The honest caveat:** `$order_by` cannot be inlined when the sort column is chosen at
runtime — GraphQL has no dynamic object keys — so that variable's 607 types are
unavoidable. The escape hatch is partial, and the docs must say so.

## Ship

**Not a 0.7.0 blocker** — agreed with your prior. It is correct and slow, not wrong,
and the 0.7.0-sized piece is the one-line README correction. The generator count and
the literal-filter docs section are **0.8**. If file count itself later becomes the
complaint, the mechanical follow-up is emitting inputs as one file per graph (1181 →
~147 files, 5.0 → 2.2 MB on disk, and it deletes the 1035-line forward-declaration
`eval` in `types.rb`, which exists only to work around the per-file split) — but the
measurements say file count is not what hurts, so don't over-build this now.
