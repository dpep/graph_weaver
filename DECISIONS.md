# Decisions

Roads not taken, and why. The code shows what was chosen; it is silent about
what was considered and rejected — and those are the ones that get re-litigated,
usually by someone with the same good instinct that was already followed to its
end once.

Only entries where the rejected path is *tempting* belong here. An obvious call
needs no record. What changed and when lives in `CHANGELOG.md`; the invariants
and principles live in `CLAUDE.md`; stated non-goals (subscriptions, `@defer`,
uploads, normalized caching, fragment masking, batching) live in `REVIEW.md` §7.

---

## The client slot stays duck-typed

**Considered:** formalizing `execute(query, variables:, operation_name:)` as a
Sorbet interface or a base class, so the thing every client implements is
declared rather than implied.

**Rejected because** a live graphql-ruby `Schema` class satisfies the slot and
cannot inherit from us. An interface would exclude the one implementation we
neither wrote nor control — and that implementation is the whole in-process
story. The openness is the feature.

Downstream of this: `Parsing` requires `#schema` of its includers and can't
declare it, hence one `T.unsafe(self)` in that mixin.

## `InProcess` lives outside `Transport::`

**Considered:** moving it under `Transport::`, or restructuring so
`Transport::HTTP` parents a native and a Faraday implementation and `InProcess`
slots in beside them.

**Rejected because** `Transport` is a base class, not a namespace: it owns the
GraphQL-over-HTTP flow (encode the body, classify network failures, `ServerError`
on non-2xx, parse). `InProcess` implements none of that. And the restructure
wouldn't achieve its goal anyway — a bare `Schema` class is in the client slot
too, so `Transport::` still wouldn't mean "things you can pass as `transport:`".
The taxonomy can't be clean because the slot is deliberately open.

Renaming the abstract base (`Transport::Base`) to stop it sharing a name with its
namespace is the smaller, honest version if this ever itches again.

## `Transport::HTTP` is the default; Faraday is opt-in

**Considered:** keeping the previous `defined?(::Faraday)` auto-detection.

**Rejected because** Faraday arrives transitively through stripe, octokit and
friends, so adding an unrelated gem silently changed your transport, your
timeouts, and your connection reuse (Faraday's default adapter reconnects per
request; measured 10 connections for 10 requests versus 1). Behaviour that
depends on what else is in the Gemfile is unreasonable-about-able. Same code,
same transport.

## Cassettes live in `spec/cassettes`, not `spec/fixtures`

**Considered:** `spec/fixtures/`, or a namespaced `spec/fixtures/graph_weaver/`,
as the more conventional home for test data.

**Rejected because** Rails globs the fixture path for `{**,*}/*.yml`
(`active_record/test_fixtures.rb`) — recursively, so a subdirectory doesn't save
you. `fixtures :all` would try to load cassettes as ActiveRecord fixtures. The
conventional-looking choice is the broken one.

## Directories organize queries; they don't namespace modules

**Considered:** deriving module names from nested query directories, so
`admin/pets.graphql` becomes `AdminPetsQuery` instead of colliding with
`pets.graphql`.

**Rejected because** it *moves* collisions rather than removing them —
`admin/pets.graphql` and `admin_pets.graphql` would then collide — so the
refusal has to exist either way, and the naming rule stops being statable
without describing which path segments count. A duplicate base name refuses,
naming both files.

## `#parse` requires a schema, so `Retry` doesn't have it

**Considered:** delegating `#parse` through `Retry` to whatever it wraps, so
`Retry.new(client).parse(q)` reads naturally.

**Rejected because** `respond_to?(:parse)` would then be true half the time and
false the other half — a `Retry` over a bare HTTP transport has no schema to
reach through to. The rule is "anything holding a schema can parse against it",
which is a domain, not an exception. `Retry` doesn't meet the precondition.

## Mutations generate `…Mutation` modules

**Considered, and initially rejected:** keeping the uniform `…Query` suffix,
because renaming breaks call sites *and* because the generated filename changes,
leaving a stale `_query.rb` that `load_generated!` keeps requiring.

**Reversed once generated-file pruning landed** — the stale-file half of the
objection dissolved, and the remaining "one rule beats a conditional one"
argument lost to `SaveListEntryMutation.execute!` being what a user types every
day. The generated filename mirrors the constant, so `ls generated/` still
answers "what's the constant".

## One shared types module, not three

**Considered:** keeping `GraphQLInputs`, `GraphQLUnions` and `GraphQLEnums`
separate on the grounds that their file shapes genuinely differ (a manifest plus
per-type files versus a single file).

**Rejected because** file layout is an implementation detail and the constant a
user types is not. Merging also *deleted* a mechanism: the artifacts used to
alias each other's constants across files, which lexical scope now handles for
free. Per-type files were extended to all three rather than dropped — adding an
enum value diffs one file.

## Subgraph mapping is derived, then verified — never guessed

**Considered:** requiring an explicit `subgraphs:` map, on the grounds that
auto-detection is guessing and a wrong guess silently points a test suite at the
wrong resolvers.

**Rejected because** matching on *what a schema defines* against the routing
table is a derivation with evidence, not a guess — and the ambiguous cases
(two candidates, or none) refuse rather than pick. Detection and validation are
the same check run in two directions, so there is no second code path to
disagree.

## Only some `ArgumentError`s were branded

**Considered:** two uniform answers. Brand all ~50 `raise ArgumentError` sites
under `GraphWeaver::Error`, so "everything descends from `Error`" is literally
true; or leave subgraph detection's refusals as `ArgumentError` and qualify the
sentence in `docs/errors.md`.

**Rejected because** the first throws away the one thing `ArgumentError`
communicates — you passed something wrong at this call site, like any Ruby
method — and `pool_size: must be >= 1` is exactly that. The second leaves the
refusals a `Testing::Router` user actually meets outside the umbrella the docs
point them at, which is where a spec helper rescues.

What survives is a line that can be stated: **what the library concludes,
having read your schema, is a `GraphWeaver::Error`; an argument wrong on its
face is an `ArgumentError`.** Subgraph mapping (`ConfigurationError`) and a
query file whose name can't spell a constant are verdicts; `cast:` not being a
Symbol is not. A rule with a stated boundary beats a uniform one that lies
about half its cases.

## An abstract type is bucketed on `__typename`, not planned away

**Considered:** keeping the `abstract_boundary` refusal, on the reasoning that a
representation needs one concrete `__typename` and the planner — which takes no
variables and runs before any fetch — cannot know it.

**Rejected because** the planner doesn't have to know it. It only has to plan
*every* possibility: the supergraph says which concrete types a subgraph can
answer a union or interface with, so the plan carries a branch per type and
execution picks the one the data came back as. Deciding at execution is the
existing precedent — `@skip`/`@include` already filter deferrals against the
variables in hand for exactly the same reason.

The corollary is smaller and sharper than the rule it replaced. A fragment
whose condition can't hold at a position — `... on Note` where the answering
subgraph's union holds no Note — is **dropped**, not refused, even though
"refuse rather than guess" pulls the other way. It isn't a guess: the fragment
can never match, so `{}` is the only answer, and a real `@apollo/gateway`
returns exactly that. What still refuses is the case where the supergraph
genuinely doesn't say — no `@join__unionMember`/`@join__implements`, and the
type in more than one subgraph — because then the branch list itself would be
invented.

## A nested field set crosses whole, or not at all

**Considered:** assembling a nested `@key`/`@requires` object from more than
one fetch — `store { id }` from the subgraph in hand and `store { region
{ code } }` from a prefetch, deep-merged into one representation. It is what
`@apollo/gateway` does internally (`deepMerge(entity, dataReceivedFromService)`),
and it would close the last nested case rather than refusing it.

**Rejected because** the only shapes that produce the split are ones where the
gateway is no longer an oracle. A field set reaching *through* a key field is
the common one, and there the gateway doesn't split at all: composition drops
`@external` from key fields — an entity's key is answerable by any subgraph
declaring it — so the extending subgraph looks able to resolve the whole path,
the gateway satisfies the `@requires` locally, and gets back whatever that
subgraph happens to hold. Merging would mean answering *better* than the
gateway, which under `0 wrong` is the same failure as answering worse. So a
root fed by two fetches refuses, naming both halves and where each comes from.

That trap is also why the fixture graph's nested `@requires` walks a plain
external field (`dimensions`) and not the nested `@key`'s object (`store`):
the first is diffable against a real gateway, the second isn't.

## The in-process router refuses rather than approximates

**Considered:** planning every query shape, falling back to a best-effort answer
where the semantics are uncertain.

**Rejected because** a test double that answers 5% of queries differently from
production is worse than one that answers 80% and declines the rest loudly. The
refusal boundary *is* the product. Non-null propagation is the concrete reason:
before that pass existed, three queries returned silently wrong data where the
real router returned `data: null`.

A corollary: a `--strict` mode for the drift differ was built and then deleted,
because once a partly-local supergraph became a supported setup, failing on any
skipped subgraph was wrong for every graph except a fully-local one — and that
one's report already says "checked 3 of 3".

## `federation:diff` fails when it checked *nothing*

**Considered:** leaving zero-checked as a pass, on the `--strict` reasoning
directly above — absence is supported, and the headline already says "checked 0
of 4".

**Rejected because** zero is not a small number of subgraphs, it is a different
kind of answer: the gate would pass whatever the subgraphs said, so a green run
carries no information at all. "Checked 3 of 4" did real work. And the failure
that produced it was silent — Rails leaves `rake_eager_load` false, so a stock
app's CI gated on nothing while printing honest prose. There is no setup where
you'd deliberately run this task against a supergraph none of whose subgraphs
are here; the abort says to drop it from CI if that's really you.

The rule stays statable in one sentence: it fails when it found drift, and when
it had nothing to look at.

## Output structs allow Ruby-keyword prop names

**Considered:** narrowing the ban to types with a registered `alias:` whose path
starts at the prop.

**Rejected because** the ban turned out to be unnecessary, not merely too broad.
All 33 producible keywords construct, deserialize and typecheck as props; the
only bare read is an `alias:` delegator's first hop, which now spells
`self.next`. The proposed narrowing would also have made generation depend on
unrelated global registry state.

## Queries directories are a list again

**Considered:** leaving `queries_path` singular, as 0.4.x made it — one
`generate!` run reads one directory against one schema, and a second entry
would produce modules at runtime that `rake graph_weaver:generate` never
generated and `verify` never checked.

**Rejected because** that failure was the *divergence*, not the plurality:
back then `load_queries!` walked the list and `generate!` read only its first
entry. Every reader now goes through `GraphWeaver.query_files`, so a second
directory is generated, verified and loaded alike — and a duplicate module
name across two directories refuses, as it already did within one. What
survives is the honest half of the argument: one run reads one *schema*, so
`schema_path` stays singular.

## Deferred, deliberately

- **`write_timeout` on `Transport::HTTP`** — a real gap (nothing bounds sending),
  but not yet worth a kwarg. Note `open_timeout` *is* the connect timeout and
  covers the TLS handshake too (`net-http`'s `ssl_socket_connect(s, @open_timeout)`);
  `ssl_timeout` is the OpenSSL session timeout and not a handshake deadline.
- **A `net_http:` passthrough hash** — the answer if the timeout/TLS kwarg list
  keeps growing. Deliberately a hash and not a block: the pool creates
  connections lazily and on failure, so a block would run an unpredictable number
  of times. Configuration survives that; behaviour doesn't.

## Variables coerce in execute's body, under a narrow sig

`first: params[:page_size]` arriving as a String is the most common real
coercion in a Rails app, and the library has to serve it. What it must not do
is pay for that with the static check.

**The road taken:** the emitted sig stays exactly as narrow as the schema
(`first: Integer`), and `.checked(:never)` lets an untyped value through to the
body, where `GraphWeaver::Coerce` converts it from what the scalar already
knows — `cast:` for anything that has one, the Ruby type's own rule for the
built-ins that don't. A typed call site is still an `srb tc` error; an untyped
one works; garbage raises `InputError` naming the variable, the operation and
the value.

**Not taken: widening the sig** — `first: T.any(Integer, Float, String)`,
resolved at generation time. This one *shipped*, as `coerce:` and
`auto_coerce`, through 0.5.x, which makes it the most instructive rejected
path here. It bought the untyped boundary its conversion by discarding the
static check at *every* call site of that variable, typed ones included, and
because it was resolved at generation time a global switch silently loosened
kwargs across the whole codebase. The narrow sig gives the same call the same
answer without giving anything up, so both knobs are gone.

**Not taken: an explicit second door** — `PersonQuery.coerce(params)` or
`execute_loose(...)` alongside the typed `execute`. Honest about which values
are trusted, but it is two methods for one idea, and every call site has to
know which it is on. Coercion that is always on needs no door.

**The cost, stated plainly:** `.checked(:never)` turns off sorbet-runtime's
check of `execute`'s arguments and return. The arguments are covered by
coercion, which is stricter and better-messaged than the sorbet `TypeError` it
replaces. The return isn't checked, but the `Response`/`Result` it builds are
`T::Struct`s whose props are still validated one by one.

## `:in_process` names its schema per example, not per suite

**Considered, and both built and reverted in one session:** first splitting
`config.schema` in two, since it serves two masters — the schema fakes are
fabricated against, and the live class `:in_process` runs — then instead
*refusing* a federation subgraph class, so the one setting meant one thing
again.

**Rejected because** neither answers the case that motivated them. A federated
app has several subgraphs, and a suite tests more than one; a suite-wide
setting cannot say "Catalog here, Reviews there" whichever way it is spelled.
The split was a second knob *and* still insufficient; the refusal was one
concept fewer *and* removed a capability worth having — testing one subgraph's
resolvers directly is a real question, distinct from testing the graph
stitched.

`graphql_in_process(Catalog::Schema)` says it where it varies, and
`config.schema` keeps one meaning: what a response is shaped like, which is
also the live class when it happens to be one. The general form is now a
design principle in `CLAUDE.md` — don't answer a varying question with a
global setting.

## The `graphql:` tag names a mode; a client is built in the example

**Considered:** letting the tag carry a client — `graphql: Failure.throttled`,
or `graphql: FakeClient.new(overrides: …)` — which reads well and would make
the tag's value a description rather than the cleanup marker it had become.

**Rejected because** metadata is evaluated when the file loads: one client
object would be shared by every example in the group, built before
`Testing.configure` had run. Spooky at a distance, and stateful — `#requests`
would accumulate across examples.

What the reading was right about was the leak underneath, and that is fixed
elsewhere: `GraphWeaver.client` is snapshotted and restored around *every*
example, so the tag no longer earns its keep as a cleanup marker, and building
a client is a plain assignment in a `before` block. `graphql_fake(**options)`
exists only because a fake needs the schema derivation the tag was doing.

## `Internal` is a name, not a `private_constant`

**Considered:** `private_constant :Internal` under `GraphWeaver`, so the
namespace holding the gem's cross-file helpers is unreachable from outside and
Ruby enforces the rule instead of a convention.

**Rejected because** most of this gem opens its classes compactly — `class
GraphWeaver::Codegen`, `class GraphWeaver::Transport`, `class
GraphWeaver::Testing::FakeClient` — which puts `GraphWeaver` outside their
lexical scope. A private constant is reachable only by its bare name from
inside the defining module, so `private_constant` would break exactly the files
that need `Internal`, and buying it back means renesting seven files (one of
them 1,300 lines) for a runtime guard.

The enforcement lives in `spec/public_surface_spec.rb` instead, which is
strictly better: it skips `Internal`, diffs everything else against a
checked-in list, and fails in CI with the two things you can do about it —
rather than at a user's runtime with a `NameError`. The rule stays one
sentence: anything under `GraphWeaver::Internal` is not API.

## The settings are the default graph, not a graph beside the others

**Considered:** `GraphWeaver.graphs` as a list an app fills, with the top-level
`schema_path`/`queries_paths`/`generated_paths` left as what a single-schema app
uses and generation walking both.

**Rejected because** it is two configurations for one question, and every entry
point would have to say which it meant. `GraphWeaver.graph` declaring one
*replaces* the implicit graph instead, so the rule is one sentence — an app has
graphs, and by default it has the one its settings describe — and a
single-schema app's behavior is not "a special case that happens to work" but
literally the same code path.

The same reasoning keeps `generate!(schema:, queries:, ...)`: those arguments
have always described one generation, and they now build one graph inline. There
is no third thing.

Top-level registrations still reach every graph, on top of which each graph's
block adds its own. The alternative — a graph starts empty — would silently drop
the `register_scalar` an app already had in an initializer the moment it declared
a second schema, which is precisely the failure mode graphs exist to remove.

## A graph is declared, not constructed

**Considered:** a public `GraphWeaver::Graph.new(...)` users build and push onto
a list, or a per-schema registry object (`registry = GraphWeaver::Registry.new;
registry.register_scalar(...)`) passed to `generate!`.

**Rejected because** both make the user hold a thing whose only purpose is to be
handed straight back. `GraphWeaver.graph :billing do ... end` says the same
thing once, and the block is what scopes the registrations — no object to name,
no second call to remember to make. `Codegen::Registry` still exists, because the
scoping has to live somewhere, but an app never names it.

The registry is threaded to codegen rather than swapped in around each graph.
Swapping is the smaller diff, and it was rejected on "no spooky action at a
distance": a `register_scalar` in an initializer must reach the default graph and
nothing else, and that is a guarantee about *when* a global is set rather than
about what the code in front of you says. A `Codegen` instance is handed the
registry it generates with, so there is no window in which the answer depends on
what ran first.

## `namespace:` nests a graph's constants; a collision otherwise refuses

**Considered:** requiring `namespace:` whenever more than one graph exists, and
at the other end leaving it out entirely and refusing every cross-graph collision
by name.

**Rejected because** requiring it taxes the app that has two schemas with no
overlapping file names, and leaving it out has no fix to offer the app that does:
"rename one of these files" is poor advice when the two belong to different
vendors. So `namespace:` is optional, an un-namespaced collision refuses naming
both files *and* the graphs, and the message names `namespace:` as the fix.

The shared types module settles it either way: two schemas both hoisting an enum
into `::GraphQLTypes` is a certainty, not a chance, so `namespace:` carries that
too (`Billing::GraphQLTypes`) rather than being a second knob beside
`types_module:`.

Generated files open each outer segment on its own line (`module Billing; end`)
rather than nesting the body, so adding `namespace:` to an existing graph diffs
as one added line per file instead of reindenting everything.

## A graph's name is its identity, and `schema:` takes a lambda

Both of these come from driving a scratch Rails app, and neither was visible to
the suite — it is not a Rails app and it does not re-run an initializer.

**Considered:** `GraphWeaver.graph` appending unconditionally, with the docs
telling a Rails app to declare its graphs from a `to_prepare` block (which is
where `register_enum` and `GraphWeaver.client =` are already told to go, since
an autoloaded constant doesn't resolve while `config/initializers` run).

**Rejected because** `to_prepare` re-runs on every dev reload, so appending
turned two graphs into six and the next regeneration refused on a graph
colliding with *itself* — after which the dev server served 500s permanently,
because the failed `generate!` meant `reload_generated!` never ran. And
`to_prepare` is too late for two things that need the graph list earlier:
`Railtie.watch!` (which must register a reloader before the finisher that reads
`app.reloaders`) and the Zeitwerk ignore. A graph declared there is invisible to
watch mode, so editing its `.graphql` silently never regenerates.

So the name is the identity — re-declaring replaces in place — which makes
`to_prepare` safe, and `schema` accepts a callable, which makes it unnecessary:
`schema -> { Billing::Schema }` at the top of the initializer resolves when
generation asks. That is not a second way to say the same thing. A lambda is
*more* correct than a captured class either way: Zeitwerk replaces the class
object on reload, so a graph holding one holds a stale object.

## A graph is declared in a block, and the block runs there

**Considered:** keeping the keyword form beside the block (`GraphWeaver.graph
:billing, schema: …, queries: … do … end`), and keeping the registrations
deferred to the first read of a graph's registry so a Rails initializer could
name an autoloaded constant.

**Rejected because** two spellings for one declaration is one more thing to
know, and the deferral was a timing rule you could not see in the code in front
of you. It also could not survive the settings moving into the block: Zeitwerk's
ignore list is built from every graph's `output` at
`after: :load_config_initializers, before: :setup_main_autoloader`, so a graph's
settings must be readable *before* autoloading exists — which means the block
cannot wait for it.

So the block runs where it is written, registrations included, and a
registration naming one of your own constants stands exactly where a top-level
one does: the answer is `to_prepare`, and the refusal says so. What the block
gives back is a DSL object that answers the six settings and the three
registrations and refuses everything else, so `schmea "x"` is a message rather
than a call that vanishes — which the keyword form got from Ruby for free and a
bare `instance_eval` on the `Graph` would have lost. There is no `schema =` form
for the same reason: `instance_eval` makes it a local variable that silently
does nothing, so the one spelling is the call, as in graphql-ruby's `field :x`.

## A namespaced graph reloads; an un-namespaced one requires

**Considered:** leaving the railtie's `to_prepare` on `load_generated!` for
every app, since `require` is idempotent and that is exactly what you want on a
dev reload — and, at the other end, switching every app to
`reload_generated!` so there is one path.

**Rejected because** neither is right for both. `namespace: "Accounts"` is
normally a module *Zeitwerk owns* — `app/graphql/accounts/` implies `Accounts`
whether or not the generated subdirectory is ignored — so unloading it on a
reload takes the generated module nested inside it with it. `require`, having
read the file once, then restores nothing: every request 500s on
`uninitialized constant Accounts::PersonQuery` and never recovers, because only
a `.graphql` edit reaches the watcher that would have reloaded. An
un-namespaced module defines a top-level constant Zeitwerk never manages, so it
survives the unload and re-requiring it every reload would be pure cost — and
would swap out struct classes that live objects are instances of.

So the branch is on `namespace:`, which is the fact that decides it. The wider
version of this is worth remembering: **a constant we `require` into a namespace
Rails autoloads is not ours to keep.** Ignoring the generated directory stops
Zeitwerk trying to *define* what is in it; it does not stop Zeitwerk removing
the parent.

## `rake -T` can't name the graphs

**Considered:** interpolating the configured graphs into the `desc` of
`graph_weaver:generate`, so `rake -T` shows what a run would cover.

**Rejected because** it is not knowable there. A `desc` is baked when `tasks.rb`
loads, which in Rails is inside a railtie's `rake_tasks` block — before
`:environment`, so before the initializer that declares the graphs has run.
Interpolating would print the defaults as though they were the configuration,
which is the same trap the generate task's `desc` already sidesteps.
`rake graph_weaver:graphs` runs after `:environment` and can answer honestly.

## What the locked surface is allowed to contain

**The rule.** A name is public if the docs name it, if generated code calls it,
or if it is the duck-typed `execute(query, variables:)` slot. Everything else is
`private`, `private_class_method`, `private_constant`, or lives under
`GraphWeaver::Internal`.

Three corollaries the passes kept running into:

- **A cross-file caller is not a reason to be public.** It is the *only* reason
  most of the remainder was, and the fix is a home, not a keyword: a helper two
  files share belongs under `Internal`, not on whichever class one of them
  happens to be.
- **Ruby's names count.** `Struct.new` hands the world a writer per member plus
  `.[]`/`.members`/`.keyword_init?`; a record built once and read is `Data`,
  which promises only what it means to. The lock deliberately does *not* filter
  what Ruby adds — the moment it subtracts, a reader has to know what.
- **Visibility is a load-time fact.** `private_constant` inside a method body
  runs on every call, so what the gem exposes would depend on what a suite had
  reset. `spec/registry_spec.rb` guards the one that happened.

**Roads not taken, and why they stay public:**

- **`SchemaLoader.{locate, locate_path, provenance, source_transport,
  sdl_content?, federation_sdl?, refresh!}`.** Each is a real question about a
  schema source, and each is entangled with the file's private detection tables
  and cache-candidate logic — extracting them means dragging those out too, or a
  delegating shim that hides nothing. Seven names is not worth shredding a
  1,200-line file.
- **`Codegen.{scalar_registry, enum_registry, type_registry, registry,
  normalize_requires!}`.** Reached across `codegen/*.rb`, which all reopen
  `class GraphWeaver::Codegen` compactly. Fixing it means either renesting four
  files or a `Registries` module that is only a name change. `registry` returns
  the default graph's `Registry`, whose class is private — so it is a handle the
  gem passes around, not a type anyone can name.
- **`Codegen.{clear_scalars!, reset_enums!, reset_type_helpers!}`.** Documented
  in `docs/scalars.md` beside `reset_scalars!` — a big suite isolating one
  registry is a real use, and the rule's first clause settles it.
- **`Testing::Config#{explicit_schema, schema_class!, reference_schema!,
  built_router}`.** The seam between the config object and the rspec
  integration. The state lives on `Config`, so `Internal` can't hold them and a
  public method is the only way one object answers another — an honest limit of
  Ruby, not an accident of layout.
- **`Testing::RSpecIntegration.{mode_for, client_for, context!, set_context}`.**
  "Which client does this mode run against" is the only door a non-rspec harness
  has to the tag system's derivations.
- **`Graph#{described, generated_names, dump_path, named_schema?, live_schema}`.**
  The declarative half of `Graph` (`name`, `schema`, `queries`, `output`,
  `client`, `namespace`, `types_module`, `registry`) is genuinely public — it is
  every setting a graph block says, read back, and `rake graph_weaver:graphs`
  prints four of them. These five
  are mechanism `GraphWeaver` asks of a graph from another file, and the same
  limit applies as to `Testing::Config`: the state lives on the object, so a
  public method is the only way one object answers another.
**`Codegen::Registry` is a private constant.** It landed public — the class plus
thirteen instance methods — which said the opposite of what the graph decision
above intends ("an app never names it"). A graph block reaches the same methods
through the builder it is `instance_eval`'d against, and a top-level
`register_scalar` by delegation, so both documented doors keep working with the
name shut. It stays *inside* `Codegen`
rather than moving under `Internal`: its methods build a `ScalarType` and an
`EnumType`, which are private constants there, so only a lexical child can see
them. `GraphWeaver.registry_for` went with it, to `Internal::Util` — the fakes
were its only callers.
