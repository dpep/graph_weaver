# GraphWeaver senior-engineer evaluation — session G

Evaluator stance: senior Ruby engineer, third pass on custom scalars — angle
assigned is scalars where the registry meets MORE THAN ONE graph, and where
generated code meets `srb tc`, plus registration lifecycle under Rails and
cassette/fake drift. Read senior-log-A.md (registration, Money, equality) and
senior-log-D.md (inputs, modes, to_json, precision, federation) first — not
repeated here. Working dir: /tmp/claude/graph_weaver/senior-app-G, a real
Rails 7.2.3 app (A and D were plain Ruby — Rails initializer/to_prepare
lifecycle is untested territory). Gem consumed via `path:`, never edited.
Toolchain: `~/.rvm/wrappers/ruby-3.4.9/bundle exec ...`.

### pre-work — read source before writing code, and why

Read docs/scalars.md in full (registration doors), docs/getting_started.md's
"More than one schema" section, lib/graph_weaver/graph.rb (Graph#registry —
`GraphWeaver::Codegen.registry.dup.tap { replay this graph's registrations }`,
confirms per-graph registrations never mutate the global registry, only a dup),
lib/graph_weaver/railtie.rb in full (heavily commented with the exact bugs its
own ordering fixes — to_prepare vs initializer, Zeitwerk ignore timing, watch
mode), and lib/graph_weaver/tasks.rb + codegen/registry.rb for how
`unmatched_registrations`/`untyped_scalars` are accumulated. This is more
lib-reading than a normal session because the brief's central question —
"does verify/graphs tell you which registrations apply to which graph" — has
its answer in exactly how those two ivars are populated
(`lib/graph_weaver.rb:835,859,871`: `@unmatched_registrations |= ...`,
`@untyped_scalars |= codegen.untyped_scalars` — a **flat array union across
every graph in one generate!/verify_generated! run**, so scalar NAMES that
collide across two graphs' reports merge into one report line with no
graph label, while unmatched-registration messages at least embed
`schema.name` because the message string itself differs per graph). Confirmed
this by reading, then verified empirically below. ~25 min.

Tried Countries API (https://countries.trevorblades.com/graphql) and PokeAPI
beta (https://beta.pokeapi.co/graphql/v1beta) as a real second graph per the
brief's suggestion — introspected both (`__schema { types { name kind } }`):
Countries declares **zero** custom scalars or enums (just Boolean/Float/ID/
Int/String), and PokeAPI's only scalar is `jsonb`, with ~120 enums all
Hasura-generated `*_select_column` names — neither exposes a scalar/enum NAME
that collides with anything a second, hand-written graph would plausibly also
call `DateTime`/`Status`/etc. A genuine name collision across two graphs (the
brief's actual ask — "both declare a scalar named DateTime") needs both graphs
under my control to force the name match; a real second live graph proves
nothing about naming that a second in-process schema doesn't already. Used
two in-process graphql-ruby schemas for the collision tests, and note this
deviation rather than silently substituting it — ~8 min spent confirming
neither live API had a usable name collision before deciding this.

### multi-graph registry — results

Full setup: two in-process graphql-ruby schemas (`MainSchema`, `OtherSchema`),
each declared as a named `GraphWeaver.graph` block (`:main`, `:other`), each
with its own `namespace:`. `rake graph_weaver:generate` output, verbatim:

```
wrote app/graphql/main/generated/types/status.rb
wrote app/graphql/main/generated/types.rb
wrote app/graphql/main/generated/widget_query_query.rb
wrote app/graphql/other/generated/types/status.rb
wrote app/graphql/other/generated/types.rb
wrote app/graphql/other/generated/widget_query_query.rb
1 unregistered custom scalar → T.untyped: Weight (register with GraphWeaver.register_scalar)
```

**Scalar name collision, different meaning ("DateTime" — ISO-8601 vs epoch
millis)**: clean, no leakage. Main relies on the built-in `DateTime -> Time`
(ISO-8601) convention with no registration of its own; `:other`'s block
overrides `DateTime` to epoch millis (`Time.at(v / 1000.0)` /
`(v.to_i * 1000)`). Generated code for each: `const :created_at, Time` /
`Time.parse(data.fetch("createdAt"))` for Main, `const :occurred_at, Time` /
`Time.at(data.fetch("occurredAt") / 1000.0)` for Other — both typed `Time`,
both cast/serialize correctly for their own wire shape, confirmed by reading
both generated files. Matches senior-log-A's Money finding, generalized to
overriding a *built-in* name rather than a fresh one — no finding, this is
the design working as documented (`Graph#registry`:
`GraphWeaver::Codegen.registry.dup.tap { replay this graph's own calls }` —
never mutates the shared registry).

**Enum name collision, different members ("Status")**: clean. Neither graph
registers it; each auto-generates its own `T::Enum` under its own namespace
(`Main::GraphQLTypes::Status { Active, Inactive }` vs
`Other::GraphQLTypes::Status { Done, Failed, Pending }`) — confirmed by
reading both generated `types/status.rb` files. No finding — namespace
does exactly what docs/getting_started.md promises.

**A scalar registered for graph A only ("Weight" — BigDecimal in `:main`,
never registered in `:other`, though `:other`'s schema also has a `Weight`
field), used in a query in graph B**: generates correctly and in isolation —
confirmed in the actual generated source:

```
app/graphql/main/generated/widget_query_query.rb:  const :weight, T.nilable(BigDecimal)
app/graphql/other/generated/widget_query_query.rb: const :weight, T.untyped
```

No cross-contamination in the generated CODE — but the build-level advisory
is a **flat, un-attributed merge across every graph in the run**: the single
line `1 unregistered custom scalar → T.untyped: Weight` is emitted once for
the whole app, with no graph name, no hint that "Weight" is registered
correctly one graph over, and reads exactly like "you forgot to register
Weight anywhere" even though half the truth is "you forgot it for :other
specifically." Root cause, read from source rather than guessed:
`lib/graph_weaver.rb:859,871`: `@untyped_scalars |= codegen.untyped_scalars`
is an **Array#| union of bare scalar NAMES** across every graph a single
`generate!`/`verify_generated!` run touches — two graphs with an
unregistered scalar of the same name merge into one report line even where
they mean entirely different things. Contrast with
`unmatched_registrations` (`registry.rb:105`), whose message embeds
`schema.name` in the sentence itself, so at least *that* half of the advisory
disambiguates across graphs by accident of string composition, not by design
(confirmed by reading `Registry#unmatched`, which literally says "or a
registration for another schema" for exactly this reason — the same care
was not extended to `untyped_scalars_report`).

**Does `rake graph_weaver:graphs` say which registrations apply to which
graph?** No — read from source, `lib/graph_weaver/tasks.rb`'s `graphs` task
prints only `name`, `queries -> output`, `namespace`, `client` per graph.
Zero mention of scalars/enums/extend_type, registered or missing. An app
with five graphs sharing scalar names has to go read five `GraphWeaver.graph`
blocks by hand to answer "who registers what" — `graphs` was the obvious
place to answer it and doesn't.

**extend_type on a type name both graphs have ("Widget" — Main:
`{id,label}`, Other: `{id,name}`), each via a `extend_type(name) { block }`**:
this is where a real, high-severity bug turned up — see next section, since
it isn't really a "multi-graph" bug so much as a "graph-block registrations
are *replayed*, and replay is not idempotent for the block form" bug that a
same-name collision across two graphs makes immediately visible (and even a
single graph hits a milder version of it).

### HIGH SEVERITY finding — block-form `extend_type` in a `GraphWeaver.graph`
block mints an unstable module name, and `verify` can't see it

Repro, exact and deterministic (re-run 3x, identical every time):

```ruby
GraphWeaver.graph :main do
  ...
  extend_type("Widget") { def shout = label.upcase }
end
GraphWeaver.graph :other do
  ...
  extend_type("Widget") { def shout = name.upcase }   # same type NAME, both graphs
end
```

`rake graph_weaver:generate` writes `include GraphWeaver::TypeHelpers::WidgetV3`
into `main/generated/widget_query_query.rb` and
`include GraphWeaver::TypeHelpers::WidgetV4` into `other/generated/...`.
`rake graph_weaver:verify` immediately after: **"generated queries up to
date"** — a clean pass. Then a plain `bin/rails runner '1'` (any Rails
command that boots the app — console, runner, server) **fails to boot**,
verbatim, deterministically, every time:

```
GraphWeaver::Error: app/graphql/main/generated/widget_query_query.rb includes
GraphWeaver::TypeHelpers::WidgetV3, but nothing registers it — the
extend_type("WidgetV3") it was generated from is gone. Re-add that
registration, or regenerate without it: rake graph_weaver:generate
```

**Root cause, read from `lib/graph_weaver/codegen/type_helpers.rb:125-133`
(`helper_module`) and `lib/graph_weaver/graph.rb`'s `Graph#registry` (not
memoized — "Read here rather than captured at declaration... run them once
here" in `GraphBuilder.build`, replayed again on every `generate!`/
`verify_generated!` call):**

- A block-form `extend_type("Widget") { ... }` calls `helper_module`, which
  names the constant `GraphWeaver::TypeHelpers::Widget`, or `WidgetV2`,
  `WidgetV3`, ... — incrementing **only by checking whether that global
  constant already exists**, with no idea whether the existing one is
  "mine from last time" or "someone else's registration."
- Inside a `GraphWeaver.graph` block, registrations are stored as
  `[name, args, kwargs, block]` tuples and **replayed from scratch every
  time `graph.registry` is read** — which happens at least twice per
  process for every graph that has one: once at `GraphBuilder.build` (right
  after the block runs, to validate it against the schema) and once more
  inside `generate!`/`verify_generated!`'s `generation_plan`. Each replay of
  the SAME block calls `helper_module` again and mints a **new, additional**
  module — it never reuses the one from the previous replay in the same
  process.
- Two graphs extending the same type name make this land on nearby-but-wrong
  numbers immediately (both fighting over one global `TypeHelpers`
  namespace): boot order for THIS app is declare `:main` (creates `Widget`),
  declare `:other` (creates `WidgetV2`) — that's the full sequence a plain
  boot ever runs, since nothing after declaration reads the registry again.
  `rake graph_weaver:generate`'s own process runs the *same two* declaration
  reads, **then** two more from `generation_plan` (`:main` → `WidgetV3`,
  `:other` → `WidgetV4`) — the numbers actually embedded in the file.
- **A single graph, alone, hits a milder version of the same bug**: its own
  declaration-time read creates `Widget`; its own generation-time read
  collides with that and creates `WidgetV2` — so a plain boot (one read)
  never reaches `WidgetV2` either. I did not additionally isolate that case
  in its own app (time budget), but it follows from reading the same two
  code paths and needs no multi-graph collision to trigger — the two-graph
  setup only made the divergence obvious and gave a clean before/after.

**Why `verify` can't catch it**: `rake graph_weaver:verify` runs the exact
same process shape as `generate` (boot, then call into the registry again)
— so it reproduces the SAME numbering as the file on disk and reports a
clean match. It never boots the app the way `rails server`/`rails console`/
`rails runner` do (declaration-time read only, then straight to
`load_generated!`, no second registry read) — so verify is structurally
blind to the one thing that actually breaks: **the generated file's embedded
module name is only ever correct in the process that ran `generate!`
itself.**

**Fix / workaround, verified**: register a **named** module instead of a
block — `extend_type("Widget", MainWidgetHelper)` — which needs no
`helper_module` call and embeds the real constant name (`MainWidgetHelper`)
directly. Regenerated and booted cleanly (`bin/rails runner 'puts "BOOT OK"'`
→ `BOOT OK`) once both graphs switched to named modules. Confirms the fix,
but not for the reason docs/generated_modules.md's type-helpers section
already gives ("srb tc can't see into block-defined methods, prefer a named
module") — that reasoning is about static-type visibility; **this bug means
the block form can be outright unbootable**, a correctness problem, not a
typing-quality one, and the docs give no hint of it.

**Severity: high.** Non-additive to fix in place (the numbering scheme
itself has to become stable — e.g., keyed off registration identity/order
within one `graph.registry` build rather than "does this global name already
exist," or memoizing `Graph#registry` so a block never replays past its
first read in a process) — but the *workaround* (named modules) is
zero-cost and matches the docs' own general advice for other reasons, so an
app can route around it today with a one-line change per `extend_type`
block. What makes it high severity despite the cheap workaround: nothing
about generation, verify, or the block-form docs gives any signal this is
happening — `rake graph_weaver:verify` (the CI gate this gem exists to make
trustworthy) actively vouches for a tree that cannot boot. This is exactly
the class of bug CLAUDE.md's own "Drive it from a throwaway app" section
describes as structurally invisible to the gem's own spec suite (a
generate-time process vs. a boot-time process), and it is — I found it only
by using a real Rails app across two separate process invocations, which
neither senior-log-A nor -D did (both used a single long-lived Ruby process
with no generate/boot split).

### static typing of the generated output — every registration door under `srb tc`

Rails app with `sorbet`, `sorbet-static-and-runtime`, `tapioca` added;
`tapioca init` + `tapioca dsl` (needed once for ActiveRecord/ActionController
DSL RBIs — unrelated to graph_weaver). Baseline `srb tc`: clean.

Extended `MainSchema`/graph `:main` to cover every door the brief names, in
one query so the generated struct exercises all of them at once:

| door | registration |
|---|---|
| stdlib class | `register_scalar "Weight", BigDecimal` |
| class of your own, inferred `.parse` | `register_scalar "Sku", SkuCode` (my own class, `def self.parse`) |
| `cast:`/`serialize:` proc, object-shaped | `register_scalar "Money", MoneyValue, cast: ->(v){...}, serialize: ->(v){...}` |
| type-string, JSON narrowed via coordinate | `register_scalar "Query.meta", "T::Hash[String, T.untyped]"` |
| mapped + `fallback:` enum | `register_enum "Tier", Tier, fallback: Tier::Unknown` (schema has `GOLD`/`SILVER`/`PLATINUM`, `Tier` T::Enum only has `Gold`/`Silver`/`Unknown`) |
| plain `T::Enum`, unregistered | `Status` (no `register_enum` call at all) |
| `extend_type` mixin with its own sigs | `extend_type("Widget", MainWidgetHelper)`, `MainWidgetHelper#shout` has a real `sig` |

**Which produce a `T.untyped` prop, and does the doc say so?** Read straight
off the generated `const` lines:

| field | generated type | untyped? |
|---|---|---|
| `weight` (BigDecimal, :main) | `T.nilable(BigDecimal)` | no |
| `weight` (unregistered, :other) | `T.untyped` | **yes** — documented ("A scalar you never register... generates as T.untyped") |
| `sku` (SkuCode, inferred) | `T.nilable(SkuCode)` | no |
| `price` (MoneyValue, proc cast) | `T.nilable(MoneyValue)` | no |
| `meta` (JSON, unnarrowed elsewhere) | — (only narrowed at `Query.meta`) | n/a |
| `Query.meta` (narrowed) | `T.nilable(T::Hash[String, T.untyped])` | **partially** — the Hash's *values* stay `T.untyped` by construction (JSON can hold anything); documented, this is the whole point of narrowing |
| `tier` (mapped enum, fallback) | `Tier` (my own T::Enum) | no |
| `status` (unregistered enum) | `Main::GraphQLTypes::Status` (auto T::Enum) | no — enums always generate a concrete `T::Enum`, registered or not; only *scalars* have a T.untyped escape hatch |

So the doc's claim ("unregistered → T.untyped") is accurate and the only
door that produces it; every other door here reaches a concrete Sorbet type.
No finding — matches the docs exactly, worth having actually driven all
seven doors through one `srb tc` run rather than trusting the table.

**Misuse probes (`app/lib/misuse_probes.rb`), and what each layer catches:**

| # | misuse | `srb tc` | runtime |
|---|---|---|---|
| 1a | `result.weight.to_s("F")`, no nil-guard, **registered** nilable `BigDecimal` | **caught** — `Too many arguments provided for method Kernel#to_s. Expected: 0, got: 1` (NilClass's `to_s` takes none) | `ArgumentError: wrong number of arguments (given 1, expected 0)` |
| 1b | same call, **unregistered** `T.untyped` field (graph :other) | **not caught** — `T.untyped` accepts any call, nil-dereference included, zero static protection | same `ArgumentError`, only found by running it |
| 1c | `result.sku.to_s`, no `&.`, nilable class-of-your-own (`SkuCode`) | **not caught** — `NilClass#to_s` and `SkuCode#to_s` both exist (0-arity, returns String either way), so the nilable union is coincidentally safe by Sorbet's own rules even though the *intent* (skip the nil guard) is exactly the bug 1a demonstrates catching | no error — silently returns `""` for a nil `sku`, which reads as "no SKU" rather than "forgot to handle no SKU"; the dangerous case is one level more specific than "type mismatch" |
| 2 | `execute!(echo_tier: 42, ...)` — `Integer` where `T.any(Tier, String)` is typed | **caught** — `Expected T.any(Tier, String) for argument echo_tier ... Got Integer(42)` | n/a, never runs |
| 3 | `result.tier == "GOLD"` — `T::Enum` compared to the raw wire string instead of `Tier::Gold` | **not caught** — `==`'s signature takes untyped, Sorbet doesn't reason about enum/string equality | **worse than an exception: silently `false`, no error at all** — confirmed live (`r.tier == "GOLD"` → `false` for a real `Tier::Gold`... actually `Tier::Unknown` in my run since PLATINUM triggered the fallback, but the point holds for any member) |
| 4 | `Tier.deserialize("PLATINUM")` called directly, bypassing the generated `TIER_FROM_WIRE.fetch(...) { fallback }` table | **not caught** — `deserialize` takes any String | `KeyError: Enum Tier key not found: "PLATINUM"` — the `fallback:` protection is baked into the *generated struct's* `from_h`, not into the registered `T::Enum` itself, so calling `.deserialize` by hand (a natural thing to reach for on a `T::Enum`) reopens exactly the gap `fallback:` was supposed to close |
| 5 | `result.widget.shout` — the mixin from earlier, called on the REAL generated struct | **not caught (correctly no error)** — once actually `include`d into a struct that has `label`, the call typechecks fine; the earlier failure was `MainWidgetHelper` checked **standalone**, `self: MainWidgetHelper` (no `label`) |

Two are worth calling out over the rest. **#3 is the sharpest**: no
exception anywhere, `srb tc` silent, runtime silently wrong — a
`params[:tier] == "gold"` (or, more realistically, an existing test fixture
literal written before someone reached for `register_enum`) keeps passing
its own assertions while the branch it guards never runs. **#5 confirms a
real, generalizable rough edge in `extend_type`'s STATIC story, separate
from the process-boundary bug above**: a block or named-module mixin is
type-checked against `self: <the mixin itself>`, which has none of the
fields it depends on (`label`) — there is no way to give it a `sig` that
typechecks standalone, because the struct it will be mixed into is minted
per-query by codegen and has no stable, nameable interface to declare
(`requires_ancestor { Kernel }` doesn't help — tried it, same error, since
`Kernel` doesn't have `label` either and nothing else is nameable). The
practical upshot: **an `extend_type` mixin's own file will show a
`srb tc` error the moment it references any field of the type it decorates,
even though the real, generated usage typechecks fine** — a false
positive that either forces every such method down to `T.untyped` params/no
sig, or forces every project either to write `# typed: false` on type-helper
files (opting them out of the very checking the mixin door exists to keep),
or to accept the standing error. Worth one sentence in
docs/generated_modules.md's type-helpers section: mixins can't be sig'd
against the fields they use, only against what a caller does with their
return value.

**Drift: the server adds an enum value you mapped, with vs without
`fallback:`.** With `fallback: Tier::Unknown` (as configured): generation
silent — no warning that a fallback is actively absorbing a gap, matching
docs (fallback is presented as a deliberate forward-compat choice, not
something to flag every run) — `srb tc` unaffected (compiles clean either
way, since Sorbet knows nothing about wire values) — runtime absorbs
`"PLATINUM"` into `Tier::Unknown` correctly through the generated `from_h`.
**Without `fallback:`** (tested by removing it and regenerating, then
restoring): generation refuses immediately, verbatim:

```
Tier has no member for Tier value(s) PLATINUM — add them, pin with map:, or absorb with fallback:
```

Exactly the order the brief asks about: generation is the earliest and only
gate that fires by default; `srb tc` never sees wire values at all; runtime
would have raised only if generation had been forced through (it can't be —
this is a hard `GraphWeaver::Error`, not a warning).

### registration lifecycle under Rails

**Plain `config/initializers/*.rb`, top level.** A `GraphWeaver.graph` block
referencing an app-autoloaded constant (my `SkuCode`/`MainWidgetHelper`, both
under `app/lib`) raises immediately at boot, verbatim:

```
NameError: uninitialized constant MainWidgetHelper — a graph block runs
where it is written, so a registration in it stands where a top-level one
does. An autoloaded constant isn't resolvable while config/initializers run;
register from a Rails.application.config.to_prepare block, which generation
also runs first. Declare graph :main from one.
```

Excellent error — names the exact fix and even clarifies "which generation
also runs first" (so `to_prepare` isn't just a workaround, it's the one place
both boot and `rake generate` agree on). A registration whose type is
already loaded (stdlib, a gem) works fine directly in a plain initializer —
confirmed: `register_scalar "Weight", BigDecimal` never needed `to_prepare`.

**`Rails.application.config.to_prepare do ... end`**: the fix the error names.
Moved both graph blocks in; boots clean, `rake graph_weaver:generate` and
`rake graph_weaver:verify` both still work (they boot the app the same way,
running `to_prepare` as part of `:environment`).

**`Rails.application.config.after_initialize do ... end`**: also boots clean
— but only because BOTH my graphs' `output` paths (`app/graphql/main/generated`,
`app/graphql/other/generated`) happen to match the **default** convention
glob `GraphWeaver.generated_paths` already carries
(`app/graphql/*/generated`, read from `lib/graph_weaver/internal.rb:128`'s
`generated_dirs`) — so Zeitwerk had already ignored that glob during the
`ignore_generated` initializer, before any graph was ever declared, and it
didn't matter that the graphs themselves showed up later. **This is a trap
disguised as success**: swap to a non-conventional `output:` (I used
`lib/weird_generated`, still under an autoload root via this app's
`config.autoload_lib`) and declare that graph *after boot* (simulating
`after_initialize`, or a REPL/console-typed `GraphWeaver.graph` call, or any
path that runs later than `ignore_generated`), then force a reload
(`Rails.application.reloader.reload!`, the mechanism a real dev-mode file
edit triggers) — `check_generated_ignored!` catches it immediately and
refuses, verbatim:

```
GraphWeaver::Error: graph :weird's output lib/weird_generated was declared
after Rails set Zeitwerk up on it, so it can't be hidden from autoloading
and its modules can't load. Declare the graph in config/initializers
(schema -> { MyApp::Schema } resolves an autoloaded class when generation
asks), or name "lib/weird_generated" in GraphWeaver.generated_paths there.
```

No finding — the refusal is loud, correct, and exactly matches the code
comment's own stated intent (`railtie.rb`'s `check_generated_ignored!`
docblock). Confirms the design holds for the case that actually matters
(non-conventional output declared late); my first `after_initialize` probe
would have reported a false "it just works" if I'd stopped there, which
is itself worth noting: **`after_initialize` "working" for a conventional
output path is not evidence it's a safe general pattern** — it works by
coincidence of the default glob, not because `after_initialize` is a
documented-safe hook the way `to_prepare` is.

**Registering the same scalar name twice with different classes**: silent
last-write-wins, no warning either way — confirmed
(`GraphWeaver.register_scalar("Sku", String)` then `("Sku", Integer)`
leaves `registry.scalar_registry["Sku"].klass == Integer` with nothing
logged). Consistent with the registry being a plain mutable Hash and with
docs never claiming otherwise (re-registration is a documented, intended
capability elsewhere — see senior-log-A's post-generation drift check, and
this session's own `Duration`/`Interval` two-name reuse) — not filing this
as a finding, just confirming there is genuinely no guard here, silent
override is the whole story.

**A registration that raises during boot**: a malformed call
(`register_scalar("Bad", 42)`, `register_enum("Bad2", String)`) raises
immediately, with a clear `ArgumentError` (`"type: must be a class/module or
String, got 42"`, `"type: must be a T::Enum subclass, got String"`) — in a
plain initializer this aborts the whole Rails boot, which is correct:
loud-and-early beats a generated file that's wrong in a way nobody notices.
No finding, working as designed.

**`rails generate graph_weaver:install`**: exists (`lib/generators/graph_weaver/install_generator.rb`)
— read it rather than ran it (running it would have rewritten the initializer
this session already depends on). It scaffolds the initializer, directories,
and editor config, but writes zero actual `register_scalar`/`register_enum`
calls — only commented-out examples. For a schema-class source it correctly
wraps `GraphWeaver.client = ...` in `Rails.application.config.to_prepare`
itself (the exact lesson this section's `SkuCode`/`MainWidgetHelper` NameError
taught the hard way), so the generator already encodes the lifecycle rule my
own initializer had to learn from a boot failure — worth noting as a design
strength: the one place a fresh app is most likely to get this wrong (its
first initializer) is generated correctly by default.

### cassettes and fakes across registrations

**Record with one registration, change the registration, replay.** Recorded
`spec/cassettes/widget.yml` against `MAIN_CLIENT = GraphWeaver.new(MainSchema)`
with `Sku` registered as `SkuCode` (`.parse`). `rake graph_weaver:cassettes:check`:
clean (`0 stale (1 checked)`). Changed the registration to
`register_scalar "Sku", Integer` (a deliberately wrong Ruby type for the same
wire value, `"SKU-42"`), regenerated (`rake graph_weaver:generate` — this is
the step that actually changes the generated `const`/cast; the cassette file
itself is untouched), then re-ran the check:

```
spec/cassettes/widget.yml: 1 stale (1 checked)
  Main::WidgetQueryQuery {"echoTier":"GOLD","echoWeight":"1.0"}
    failed to cast response into Main::WidgetQueryQuery::Result: Parameter
    'sku': Can't set Main::WidgetQueryQuery::Result.sku to "SKU-42" (instance
    of String) - need a Integer
1 stale recording — the recorded server's answers no longer fit the structs
generated from your schema. Re-record (GRAPHWEAVER_RECORD=1, with a live
client:), or regenerate if it was the schema dump that moved: rake
graph_weaver:generate.
```

Names the field (`sku`), the struct, and both the recorded and expected
types — clean, exactly as docs/cassettes.md promises, confirmed rather than
trusted. **One inaccuracy worth flagging (low severity)**: the standard
advice line offers two remedies ("re-record... or regenerate...") as if
either could apply, but for a **registration-only** drift like this one,
`rake graph_weaver:generate` is a no-op (I'd already run it — that's how the
mismatch got baked into the generated code in the first place; the schema
never moved). The message can't tell "your schema drifted" from "your
registration drifted" apart, so it gives the same two-option advice either
way, and one of the two options does nothing for this cause. Restored the
original registration and regenerated — clean again
(`0 stale (1 checked)`), confirming the whole cycle is otherwise sound.

**A `:fake` pin whose value is the Ruby object vs. the wire string, for the
same scalar (`Sku` → `SkuCode`, `cast: :parse`).** Wire-string pin
(`overrides: { "Sku" => "SKU-99" }`): works exactly as documented —
`result.sku` is a real `SkuCode.parse("SKU-99")`, cast through the actual
registered `cast:`. **The Ruby object itself**
(`overrides: { "Sku" => SkuCode.parse("SKU-OBJ") }`, i.e. the very value type
`result.sku` is supposed to end up holding): **fails**, verbatim:

```
GraphWeaver::CastError:
  failed to cast response into Main::WidgetQueryQuery::Result: sku: Parameter
  'value': Expected type String, got type SkuCode with hash 1197480341243065734
  Caller: app/graphql/main/generated/widget_query_query.rb:90
  Definition: app/lib/sku_code.rb:14 (SkuCode.parse)
```

**Root cause, inferred from the message rather than re-read from
FakeClient's source (time budget)**: a scalar pin is spliced into the
fabricated response at the position the WIRE value would occupy, then run
through the real generated cast (`SkuCode.parse(v1)`) the same as a genuine
response — which is exactly the guarantee docs/testing.md advertises ("puts
a Ruby value on the wire the way its scalar registration serializes it...
casts... the same as a real response would"), but that guarantee is stated
for an **object pin's fields**, not for a **scalar pin's own value** — and
nothing in docs/testing.md's "scalar type pin" paragraph says a scalar pin
must be the wire spelling rather than the already-cast Ruby object, even
though that's the one thing every worked example in that section actually
shows (`"Money" => "12.00"`, a string, never a `Money`). The failure mode
is honest (a real Sorbet `TypeError`, wrapped and located) but doesn't say
*why* — "Expected type String, got type SkuCode" reads like a data bug, not
"you pinned the deserialized type where the wire type belongs," and I'd
expect this to be genuinely common: a test author reaches for a pin
specifically because they already have the domain object in hand (a
`build(:sku_code)`), and the doc's own "an object pin... reads the selected
fields off it" line, read quickly, doesn't obviously exclude "handing a
scalar its own finished value." Severity: medium — one sentence in
docs/testing.md's scalar-pin paragraph ("the pin is the WIRE value your
`cast:` would receive, never the Ruby object it produces") would close this
for good, and is additive (no behavior change, just an explicit "not this").

### final verification

`bundle exec rspec`: 3 examples, 1 intentional failure (the Ruby-object-pin
finding above — left red on purpose, as the reproduction). `bundle exec srb
tc`: 6 errors — 3 are this session's own spec files referencing
`GraphWeaver::Testing` without `# typed: false` (spec files aren't the
checked contract per this repo's own convention; not a finding), the other
3 are the deliberate misuse probes + the extend_type mixin finding, all
already written up above. Restored every registration this session
temporarily changed back to its working state before finishing (`Sku` back
to `SkuCode`, `Tier`'s `fallback:` back in place, initializer back to
`to_prepare` with named-module `extend_type`).

## Matrix: what I drove × outcome

| driven | outcome |
|---|---|
| two graphs, scalar name collision, different Ruby meaning (built-in `DateTime` override) | clean — no leakage, per-graph `.dup` works exactly as documented |
| two graphs, enum name collision, different members | clean — namespace prevents it |
| scalar registered for graph A only, schema B also has the name | generated code correct per-graph; **build-level advisory merges across graphs with no attribution** (finding) |
| `rake graph_weaver:graphs` / registration visibility | **does not show registrations at all** (finding) |
| `extend_type` block-form, same type name, two graphs | **HIGH — unbootable app; `verify` passes anyway** (finding) |
| 7 registration doors × `srb tc` | matches docs' T.untyped claim exactly; no finding on the coverage table itself |
| misuse probes (nil scalar, wrong variable type, enum-vs-string, enum fallback bypass, mixin self-check) | 2/6 caught statically; enum-vs-string is a **silent wrong answer, no exception anywhere** (finding); mixin can't be sig'd against its host struct (finding) |
| enum drift with/without `fallback:` | generation is the only real gate; exact refusal message confirmed |
| initializer vs `to_prepare` vs `after_initialize` | initializer refuses autoloaded constants with a precise message; `to_prepare` is the documented fix and works; `after_initialize` "worked" only by coincidence of the default output-glob convention — confirmed the real trap (non-conventional output, declared late) still gets refused correctly on reload |
| duplicate registration, same name, different class | silent last-write-wins, no finding (undocumented but never claimed otherwise) |
| malformed registration at boot | raises immediately with a clear `ArgumentError`, no finding |
| `rails g graph_weaver:install` | exists, read not run; correctly wraps schema-class client setup in `to_prepare` by default |
| cassette recorded, registration changed, replayed | `cassettes:check` names the field/struct/types precisely; advice line doesn't distinguish schema-drift from registration-drift (minor finding) |
| `:fake` pin — wire string vs Ruby object, same scalar | wire string works; **Ruby object fails with a confusing generic TypeError** (finding) |

## Ranked findings

1. **HIGH — block-form `extend_type` inside a `GraphWeaver.graph` block mints
   a process-unstable module name; `rake graph_weaver:verify` passes while
   the app can't boot.** Repro: two graphs, each `extend_type("Widget") { ... }`.
   Verbatim boot failure: `GraphWeaver::Error: ... includes
   GraphWeaver::TypeHelpers::WidgetV3, but nothing registers it — the
   extend_type("WidgetV3") it was generated from is gone.` `verify` says
   "generated queries up to date" moments earlier, same tree. Root cause:
   `Graph#registry` replays block-form registrations on every read (at least
   2x per process: declaration validation + generation), and
   `helper_module`'s naming counter (`type_helpers.rb:125-133`) only checks
   "does this global constant already exist," never "is this the same
   registration as before" — so the embedded name is a function of how many
   times *this specific process* happened to read the registry before
   writing the file, which a plain boot never matches. Not additive to fix
   properly (needs either registry memoization or an identity-based naming
   scheme); the workaround (named modules instead of blocks) is additive and
   zero-cost, and I verified it fixes the boot.

2. **MEDIUM — `T::Enum` vs. raw wire string is a silent, unflagged, wrong
   answer, not an error.** `result.tier == "GOLD"` returns `false` with zero
   exception anywhere (`srb tc` clean, runtime clean) even when `tier` really
   is the `GOLD`-equivalent member — the comparison is just the wrong
   operands, not a caught mistake, unlike every other misuse in this session
   which at least raised something. This is exactly the enum door's whole
   value proposition (compare against your own enum, not the wire spelling)
   turned into a footgun with no signal when someone does the natural wrong
   thing anyway. Additive fix: a doc callout in the enum section flagging
   this specific comparison as the one mistake nothing catches; not
   fixable in the library itself without breaking `==`'s generality.

3. **MEDIUM — `:fake` scalar pins silently assume the wire value, and a
   Ruby-object pin fails with a message that doesn't say why.**
   `overrides: { "Sku" => SkuCode.parse("x") }` (the Ruby object) raises
   `GraphWeaver::CastError: ... Expected type String, got type SkuCode`
   because the pin is spliced in and cast exactly like a real response would
   be — but nothing in docs/testing.md's scalar-pin paragraph says the pin
   must be pre-cast form, and every worked example there happens to be a
   string by coincidence rather than by stated rule. Additive: one sentence.

4. **MEDIUM — the untyped-scalar advisory (`N unregistered custom scalars →
   T.untyped: ...`) merges scalar names across every graph in a
   `generate!`/`verify_generated!` run with no per-graph label, unlike
   `unmatched_registrations`'s message (which at least embeds the schema
   name).** A scalar registered for one graph and forgotten for another
   reads exactly like "forgotten everywhere." Additive: prefix each name
   with its graph when there is more than one, the way `Tasks.heading`
   already does for other multi-graph reports in the same file.

5. **LOW-MEDIUM — `extend_type`'s mixin can never be given a `sig` that
   typechecks standalone against the fields it depends on.** `MainWidgetHelper#shout`
   (`def shout = label.upcase`, with a real `sig`) fails `srb tc` on its own
   file (`Method label does not exist on MainWidgetHelper`) even though it
   typechecks fine once mixed into the real generated struct — there is no
   nameable interface to declare against (`requires_ancestor` doesn't help;
   tried it), since the struct is minted per-query by codegen. Not really
   fixable without generating a stable shared interface per type (a bigger
   change than this brief's scope); worth one sentence in
   docs/generated_modules.md's type-helpers section warning that a
   field-referencing sig on the mixin itself will show a standing, false
   positive.

6. **LOW — `rake graph_weaver:graphs` shows zero registration information.**
   No scalars, enums, or extend_types, registered or missing, per graph —
   an app has to read every `GraphWeaver.graph` block by hand. Additive:
   one line per graph summarizing registered/unmatched/untyped counts.

7. **LOW — `cassettes:check`'s stale-recording advice doesn't distinguish
   "your schema drifted" from "your registration drifted."** Both produce
   the same "re-record... or regenerate..." line; for a registration-only
   drift, "regenerate" is a no-op (already run) and only re-recording
   applies. Additive, cosmetic.

8. **Non-finding, worth stating**: multi-graph scalar/enum isolation, the
   `after_initialize` non-conventional-output refusal, duplicate
   registration (last-write-wins), and boot-time raises on malformed
   registrations all work exactly as designed — actively tried to break
   each and could not.

## Design critique

The registry's `.dup`-per-graph model (`Graph#registry`) is the right
abstraction for the multi-graph door — it makes the *scoping* half of "more
than one graph" genuinely bulletproof, and I could not find a single case
where one graph's registration leaked into another's generated code. But
that same "read fresh every time, not memoized" design is exactly what
produces this session's headline bug: it was chosen so a registration
declared after a graph (Rails' alphabetical-initializer-order problem) still
lands, and that's a real problem worth solving — but the fix reached for
(replay the whole block on every read) silently assumes every registration
call in the block is **idempotent to repeat**, which is true for
`register_scalar`/`register_enum` (both just overwrite a Hash key) and false
for the one call that mints new global state as a side effect
(`extend_type`'s block form). The bug isn't really about "two graphs" at
all — it's a single hidden non-idempotency in a `replay-on-every-read`
design, and the two-graph collision was simply the fastest way to make it
visible. The broader lesson for this codebase's own stated principle
("no spooky action at a distance") is that `Graph#registry` being re-read
count is itself spooky: nothing in a `GraphWeaver.graph` block's own text
says or implies "this block might run more than once, and if it does,
anything you do here that isn't a pure Hash write will misbehave" — that's
exactly the kind of rule you can't predict without having read
`type_helpers.rb`'s counter logic, which is the CLAUDE.md standard this repo
holds itself to elsewhere ("a rule you can predict without reading the
source"). Everything else I drove — the untyped-scalar merge, the fake-pin
shape mismatch, the enum-vs-string silent wrong answer — is a smaller
instance of the same family: a design that is *correct* about the case it
was built for (one graph, a wire value, a scalar registered as a class) and
quietly loses a guarantee at the exact edge this brief was assigned to probe
(more than one graph, the deserialized object instead of the wire value, a
comparison instead of a cast).

## Where I had to read lib/ or spec/, and why

- `lib/graph_weaver/graph.rb` (`Graph#registry`) — to answer whether a
  graph's registrations mutate the shared registry or a copy, since the
  brief's first question ("does one win silently") turns entirely on this.
- `lib/graph_weaver/railtie.rb`, in full — to understand the
  initializer/`to_prepare`/Zeitwerk-ignore ordering before writing any Rails
  lifecycle test, since guessing at Rails boot order and then reporting
  what I guessed would have been worthless.
- `lib/graph_weaver/tasks.rb` + `lib/graph_weaver/codegen/registry.rb` — to
  find out exactly how `unmatched_registrations`/`untyped_scalars` are
  accumulated, before claiming the `graphs`/`verify` reports do or don't
  attribute a registration to a graph.
- `lib/graph_weaver/codegen/type_helpers.rb` (`helper_module`) — after
  seeing the `WidgetV3`/boot-failure error, to find the actual root cause
  rather than reporting only the symptom.

## Time

Rough total: ~4.5–5 hours across setup (~25 min: app scaffold, gems, two
schemas, two graphs), multi-graph registry probing (~45 min), the
extend_type bug discovery and isolation (~50 min — the single biggest time
sink, split across the initial accidental discovery, root-causing it by
reading `type_helpers.rb`, and verifying the named-module fix), srb tc setup
and the seven-door sweep with misuse probes (~70 min), registration
lifecycle (~40 min, most of it the `after_initialize`/Zeitwerk-ignore
non-conventional-output test), and cassettes/fakes (~35 min). No single dead
end exceeded the 15-minute budget; the closest was diagnosing why
`rails runner` failed to boot the first time, which turned into the
session's main finding rather than a dead end.

## Would I ship on this surface?

Yes, with the extend_type caveat flagged loudly to the team before anyone
uses it. The multi-graph registry itself is the most confidence-inspiring
part of this whole evaluation — a real design decision (copy-on-read,
namespaced output) that holds up under deliberate collision attempts across
scalars, enums, and (mostly) type helpers, and the static-typing story for
every *scalar* registration door is exactly as good as the docs claim, with
runtime as a real, verified second line of defense for what `srb tc`
structurally can't see (nil dereferences on an unregistered field, enum
drift, a T::Enum's own `.deserialize` bypassing the generated fallback
table). But the `extend_type` block-form bug is a genuine "your CI is lying
to you" defect — `rake graph_weaver:verify` is this gem's entire pitch for
being trustworthy in CI, and I found a deterministic, three-line
reproduction where it gives a clean pass on a tree that cannot boot. I
would not ship a second `GraphWeaver.graph` block using block-form
`extend_type` on a type name another graph also touches without either the
named-module workaround or an upstream fix — and I'd file this specific bug
upstream before doing anything else with the gem, since "trust the green
CI gate" is exactly the promise it breaks.
