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

## Coercion says *whether*, never *how*

**Considered:** keeping `coerce: <Symbol>` (`register_scalar("ID", String, coerce: :to_s)`),
which let a registration name the conversion as well as opt into it.

**Rejected because** it asked the user to answer a question the library already
answers — the conversion for every scalar that has one is derived from the
scalar itself, and a custom scalar's conversion is its `cast:`/`serialize:`
pair. Its documented showcase existed only to re-enable something deliberately
removed from the auto path: the feature arguing for its own removal.

**Also considered:** dropping the `Int`/`Float` conversion entirely, leaving
parse as the single coercion mechanism. **Rejected because** `first: params[:page_size]`
arriving as a String is the most common real coercion in a Rails app, and
without it `auto_coerce` would loosen nothing among the built-ins but `Date` —
capability loss wearing simplicity's clothes.

`coerce:` and `auto_coerce` both survive because they are one question at two
scopes — a global default with a local override, the standard shape.

## `config.schema` refuses a subgraph rather than splitting in two

**Considered:** splitting the setting, since it serves two masters — the schema
fakes are fabricated against, and the live class `:in_process` runs. In a
federated app you can't have both, and setting one to make `:in_process` work
silently repointed `:fake` at a fraction of the graph.

**Rejected because** the split is a second knob plus a rule about which one
applies, and it buys a capability nothing lost: `:router` runs a subgraph's
real resolvers too, stitched. The two masters only want different objects in a
federated app, so refusing a subgraph class is the smaller change that makes
`config.schema` mean one thing again — and the refusal `:in_process` already
raises ("a federated graph has no one schema class — tag those examples
`graphql: :router`") becomes the whole story instead of half of it.

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
