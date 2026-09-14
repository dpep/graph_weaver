# hunt 3 — the last look before graph_weaver is published

Baseline: the brief named `ff656af`. **`main` moved during the hunt** to `34970d0`
("Cut the first hour down to the single-schema path"), which touched only
`docs/getting_started.md` and `docs/testing.md` — the scribe's two files, no
`lib/` change. Every finding below was re-checked against `34970d0` and stands.
Repo clean throughout; nothing committed; all scratch under
`/tmp/claude/graph_weaver/hunt3-*`.

Six hunters ran: reserved-name props, module-owned dispatch + `:graph`,
`rake graph_weaver:unused`, observability, a fresh Rails 8.1.3.1 adopter run,
and the property harness. **I reproduced every top-ranked finding myself**
before ranking it; where I did, the repro is mine and is marked so.

Ranked by harm: silent wrong answer > crash > refusal that misdirects > paper
cut. Hunches are in their own section and are never ranked.

**Headline:** the round found no defect in what the gem *computes*. The three
new surfaces (the dispatch redesign, `:graph`, `check_input_props!`) are
essentially sound. What it found is a cluster of things that **look fine and
aren't** — an observability seam with a hole in the documented spelling, a
documented off-switch that does nothing, a lint that confidently tells you to
delete code you use, and a safety net that cannot see the release's headline
feature. Two of those five are one-line fixes.

---

## A. Silent wrong answers

### A1. The documented multi-graph client spelling emits **no instrumentation at all** — no APM event, no log line, not even at debug

**Harm: silent wrong answer, in exactly the feature `:graph` was built for.**

`Internal::Log.instrument` has exactly two production call sites —
`lib/graph_weaver/transport.rb:61` and `lib/graph_weaver/in_process.rb:56`. A
bare graphql-ruby schema class in the duck-typed client slot is neither, so it
has no instrumentation seam.

My repro, outside Rails, no railtie
(`/tmp/claude/graph_weaver/hunt3_bareschema.rb`):

```
$ ~/.rvm/wrappers/ruby-3.4.9/bundle exec ruby /tmp/claude/graph_weaver/hunt3_bareschema.rb
A. bare graphql-ruby Schema class in the client slot (the documented `client "Billing::Schema"`):
   result={"data" => {"hi" => "there"}}  events=0
B. the same schema wrapped by GraphWeaver.new:
   result={"data" => {"hi" => "there"}}  events=1 graph=[:billing]
```

What makes this the finding of the round rather than a curiosity:
`docs/getting_started.md:443-453` is **one fenced example declaring two
graphs** — `client "Billing::Schema"` and `client "GITHUB"`. The github one is
instrumented; the billing one is silent. The in-process half of the canonical
multi-graph example is invisible.

Confirmed in a real Rails 8.1.3.1 app, two graphs side by side, identical but
for the client, `GraphWeaver.logger` at DEBUG:

```
events: [[:github, "ViewerQuery"]]
=== LOG (debug level) ===
D, [...] DEBUG -- graph_weaver: in-process PetshopSchema [req 1 ViewerQuery] variables={}
D, [...] DEBUG -- graph_weaver: in-process PetshopSchema [req 1 ViewerQuery] completed (0ms)
I, [...]  INFO -- graph_weaver: GraphWeaver github/ViewerQuery (0.7ms) ok
```

`Billing::InvoicesQuery.execute!` ran immediately before that and produced **not
one line** — not the info summary, not the debug wire lines, not the `[req N]`
tag. So the standard escalation ("turn the logger up and look") shows the broken
graph as one that *never ran*.

**And the app cannot tell.** `rake graph_weaver:graphs` doesn't print the client
at all; boot just counts modules (`loaded 6 generated module(s)`); `verify` is
green. The only way anyone discovers this is noticing a dashboard that was never
going to have the data. That is why it would survive a release.

Three documented claims are false at once:
- `docs/logging.md` — "One callable wrapping **every** request GraphWeaver makes
  — over the wire **or in-process**"
- `docs/logging.md` payload table — `:graph | always`
- `lib/graph_weaver/log_subscriber.rb`'s header — `GraphWeaver billing/InvoicesQuery (12.3ms) ok`

Same hole for a hand-written `GraphWeaver.client = MyApp::Schema` (confirmed in
the app: `instrumentation events: 0`, `log lines: 0`) — and
`GraphWeaver.client=`'s own docstring in `lib/graph_weaver.rb` lists "a schema
class" as valid. One asymmetry worth keeping: `rails g graph_weaver:install
PetshopSchema` writes the **wrapped** `GraphWeaver.new(PetshopSchema)`, which is
instrumented, so the generator never leads anyone into the app-default version.
The graph version is worse precisely because the docs hand it to you.

**Fix:** wrap a bare schema class in `graph#client` the way `GraphWeaver.new`
does. Cheap interim that makes it self-diagnosing today: print each graph's
client in `rake graph_weaver:graphs` and mark an unwrapped one.
**Files:** `lib/graph_weaver/graph.rb`, `lib/graph_weaver/client.rb`,
`lib/graph_weaver/tasks.rb`, `docs/getting_started.md`, `docs/logging.md`.

### A2. Declaring a graph orphans the default query directory — and `queries:check` says the orphan validates

**Harm: silent wrong answer; the safety net lies.**

`GraphWeaver.queries_paths` defaults to `app/graphql/queries`. Declaring any
graph replaces the implicit one, and nothing then covers that directory — but
its previously generated modules keep loading in production.

My repro (`/tmp/claude/graph_weaver/hunt3_orphan.rb`), with
`app/graphql/queries/person.graphql` containing
`query($id: ID!) { person(id: $id) { nmae thisFieldDoesNotExist } }`:

```
== default queries_paths: ["app/graphql/queries"]
== after declaring :billing, graphs = [:billing]
== generate!: returned without refusing the orphaned app/graphql/queries/person.graphql
== files under app/graphql/queries still present: ["person.graphql"]
== generated for billing: ["invoices_query.rb"]
== generated for the orphan: []
```

In the Rails app, all four gates report success about that same broken file:

```
$ rake graph_weaver:generate        → 1 already up to date
$ rake graph_weaver:verify          → generated queries up to date
$ rake graph_weaver:queries:check   → every query validates against the schema
$ SECRET_KEY_BASE_DUMMY=1 bin/rails runner -e production 'puts PersonQuery.name'
  loaded 5 generated module(s) from app/graphql/generated, app/graphql/*/generated
  PersonQuery
```

`queries:check` claiming "every query validates" about a file containing `nmae`
is the sharp edge. `docs/getting_started.md` asserts an app "either has graphs or
has settings, **never a silent third thing**" — this is that third thing.

**Fix:** refuse at generation when `.graphql` files or generated output sit under
a directory no declared graph covers.
**Files:** `lib/graph_weaver/graph.rb`, `lib/graph_weaver/codegen.rb`,
`lib/graph_weaver/tasks.rb`.

### A3. `GraphWeaver.logger = nil` — the documented opt-out — does nothing

**Harm: silent wrong behaviour, with a PII consequence.** Found independently by
two agents; I reproduced it myself in real Rails 8.1.3.1.

```
$ BUNDLE_GEMFILE=/tmp/claude/graph_weaver/hunt3-obs-app/Gemfile \
  ~/.rvm/wrappers/ruby-3.4.9/ruby /tmp/claude/graph_weaver/hunt3-obs-optout.rb
config/initializers said `GraphWeaver.logger = nil` and `GraphWeaver.instrumenter = nil`
after boot:  GraphWeaver.logger     = #<ActiveSupport::BroadcastLogger:0x000000012636...
after boot:  GraphWeaver.instrumenter = #<Proc:0x0000000126447128 .../graph_weaver/rail...
```

Mechanism, from `Rails.application.initializers.tsort.map(&:name)`:

```
241..252  load_config_initializers   (x12, one per engine incl. the app)
253       graph_weaver.ignore_generated
254       graph_weaver.logger
255       graph_weaver.instrumentation
```

`graph_weaver.ignore_generated` declares `after: :load_config_initializers`;
Rails' TSort therefore emits every `load_config_initializers` node first, and the
railtie's siblings that follow it in the same collection inherit that position.
So `GraphWeaver.logger = Rails.logger if GraphWeaver.logger.nil?` runs **after**
the app said nil, and wins. Deterministic, not Gemfile-order dependent (verified
by moving the gem to the top of the Gemfile: identical relative order).

`railtie.rb:201-203`'s own comment — *"assigned after (in config/initializers,
which run later) it wins on its own"* — has the ordering exactly backwards. The
set-a-non-nil-instrumenter case only survives because of the `nil?` guard, not
because it ran later.

Why it matters beyond tidiness: the docs' PII guidance is "keep production
loggers at info or above", but an app whose `Rails.logger` is at debug (staging,
an incident) and that tries to opt graph_weaver out **cannot** — queries and
variables keep landing in the shared log.

False claims: `docs/logging.md:6`, `docs/logging.md:145`,
`lib/graph_weaver/railtie.rb:189`, `lib/graph_weaver/log_subscriber.rb:24`,
`lib/graph_weaver/railtie.rb:201-203`, `CHANGELOG.md:548`.

Good news, checked and banked: this is **not** a crash. Real
activesupport-8.1.3.1 `log_subscriber.rb:147` is `super if logger`, so a nil
logger is skipped cleanly. Working escape hatch today:
`Rails.application.config.after_initialize { GraphWeaver.logger = nil }`.

**Fix:** order `graph_weaver.logger` / `.instrumentation` before
`load_config_initializers`, or make the opt-out a sentinel rather than `nil`.
**Files:** `lib/graph_weaver/railtie.rb`, `docs/logging.md`.

### A4. `rake graph_weaver:unused` tells you to delete fields you are using — three ways

**Harm: silent wrong answer, and under `STRICT=1` a red CI build demanding it.**

**(a) A typo in `PATHS=` sweeps nothing and accuses everything.** `collect`
rescues `SystemCallError` and returns `[]`; the constructor guards the *empty*
`PATHS=` case but not the *wrong* one. Verified by me:

```
$ bundle exec rake -f .../Rakefile graph_weaver:unused PATHS=ap STRICT=1
app/graphql/queries/person.graphql: Person.name — selected, never read (...)
... (5 accusations) ...
5 selections, 5 unread — 1 query, 0 files swept under ap
5 selections nothing reads — drop them from the query and regenerate
```

`app/models/greeter.rb` in that tree *does* read `.name`. The only tell is
`0 files swept`, buried under five accusations.

**(b) The idiomatic two-line Rails controller.** The serializer excuse is
line-scoped, so assigning to a local first — the normal way anyone writes this —
breaks it. Verified by me:

```ruby
result = PersonQuery.execute!(id: params[:id])
render json: result.person
```
```
app/graphql/queries/person.graphql: Person.birthday — selected, never read
app/graphql/queries/person.graphql: Person.name — selected, never read
app/graphql/queries/person.graphql: Person.nickname — selected, never read
app/graphql/queries/person.graphql: Person.sku — selected, never read
5 selections, 4 unread — 1 query, 1 files swept under .
```

The passing spec (`rake_tasks_spec.rb:732`) uses the same code collapsed onto one
line. Same semantics, different line breaks, opposite verdict. The footer does
disclose this class of miss — but four confident per-field accusations are louder
than one clause in a footer.

**(c) `GraphQL::Schema::Resolver` / `Mutation` files are skipped whole.**
`SCHEMA = /^\s*class \w+ < GraphQL::Schema::/` was meant to exclude *type*
definitions; it also excludes the files that hold application logic, which in a
BFF is exactly where an upstream graph is read.

**Fixes:** `Dir.exist?` each resolved root and refuse; suppress-with-a-reason
rather than accuse when a file holds both the module name and a sink; narrow
`SCHEMA` to `Object|Interface|Union|Enum|Scalar|InputObject`.
**Files:** `lib/graph_weaver/internal/unused.rb`, `lib/graph_weaver/tasks.rb`.

### A5. `Response#report` walks a **server-supplied** error path with `public_send` — wrong entity ids, and stray stdout

**Harm: silent wrong answer + crash (B1 is the same line).** Found by me and,
independently and from the opposite direction, by the reserved-name hunter.

`lib/graph_weaver/errors.rb:430-431`:

```ruby
prop = GraphWeaver::Inflect.underscore(segment.to_s).to_sym
node.respond_to?(prop) ? node.public_send(prop) : nil
```

`segment` comes off the network. `respond_to?` is true for every `Object`
method, so the walk calls Ruby's own method instead of the struct's prop — and it
never applies v0.7.0's reserved-prop rename, so `class`/`hash`/`display` can
*never* resolve correctly.

My repro on an **entirely ordinary schema** — `type Person { id: ID!, email:
String }`, no reserved names anywhere (`/tmp/claude/graph_weaver/hunt3_entity3.rb`):

```
"method": RAISED ArgumentError: wrong number of arguments (given 0, expected 1)
"extend": RAISED ArgumentError: wrong number of arguments (given 0, expected 1+)
"send":   RAISED ArgumentError: no method name given
"tap":    RAISED LocalJumpError: no block given (yield)
#<Q::Result::People:0x0000000120d85b00>"display": report=[[]] person.frozen?=false
"freeze": report=[["7"]] person.frozen?=true
"clone":  report=[["7"]] person.frozen?=false
"bogus":  report=[[]] person.frozen?=false
```

Read that carefully:
- `freeze` / `clone` / `itself` / `dup` return `self`, so the walk lands on the
  wrong record and reports **id "7" for a path that doesn't exist** — a
  confidently wrong id in an error rollup.
- `freeze` **silently freezes the caller's result struct** (`person.frozen? = true`).
- `display` **prints your struct to stdout** (the `#<Q::Result::People:0x...>`
  above is real output).

`report` is public, documented in `docs/errors.md:363`, and on both `Response`
and `QueryError` — `rescue GraphWeaver::QueryError => e; render json: e.report`
is the documented shape. Coverage today is one happy-path assertion
(`spec/error_handling_spec.rb:333`).

I checked: this is the **only** place in `lib/` that `public_send`s a name that
came off the network. Every other `public_send` iterates declared props or guards
the owner.

**Fix:** resolve the segment against `node.class.props` using the same prop rule
the emitter used, and bail when it isn't one — never `respond_to?` +
`public_send` on a server-supplied name.
**Files:** `lib/graph_weaver/errors.rb` (+ whatever exposes the prop rule, see E1).

---

## B. Crashes

### B1. The same line, in its crash form

`method` / `send` / `extend` / `tap` as an intermediate path segment raise
`ArgumentError` / `LocalJumpError` out of `Response#report` — inside error
handling, where an app is least able to cope. A field named `method` (payment
method, shipping method) is an ordinary thing to have, and **v0.7.0 is what made
it reachable**: before the reserved-prop rename, a result key named `method` was
refused at generation, so you could never have such a query. Same fix as A5.

### B2. `:in_process` / `:wire` cannot serve an input argument named `class` — the exact schema shape v0.7.0 shipped for

**Harm: crash, with a message that names nothing.** Root cause is upstream
graphql-ruby 2.6.10, but the gem sells this case.

My scoping (`/tmp/claude/graph_weaver/hunt3_classarg.rb`):

```
graphql-ruby 2.6.10
1. from_definition: LOADED ok
2. codegen: GENERATED ok  Filter props=[:class_, :name]
   serialize -> {"class" => "x", "name" => "y"}
3. graphql-ruby execute: RAISED NoMethodError: undefined method 'arguments' for an instance of String
```

So the good news is real and worth stating: **codegen works and the wire bytes
are correct**, so an app talking to a real Hasura endpoint over HTTP is fine.
`argument :class` defines `#class` on the `GraphQL::Schema::InputObject`
subclass, so `warden.arguments(self.class)` in `InputObject#initialize` receives
the field's *value*. The whole input type is poisoned — sibling fields fail too.

Blast radius inside graph_weaver: every mode that runs the schema in-process
(`:in_process`, `:wire`, `:router`, `graphql_in_process`), where it surfaces as
`GraphWeaver::ServerError: HTTP 500: NoMethodError: undefined method 'arguments'
for an instance of String`. `:fake` is unaffected.

**Fix:** detect an input type declaring `class` when a graphql-ruby schema goes
in the client slot and refuse naming the field and pointing at `:fake`, rather
than letting an upstream `NoMethodError` arrive as an unbranded 500.
**Files:** `lib/graph_weaver/in_process.rb`, `lib/graph_weaver/rspec.rb`,
`lib/graph_weaver/schema_loader.rb`.

### B3. A raising `ActiveSupport::Notifications` subscriber takes the request down

```ruby
ActiveSupport::Notifications.subscribe("execute.graph_weaver") { raise "boom" }
# => execute RAISED RuntimeError: boom
```

The response was computed successfully and thrown away. This is ActiveSupport's
own semantics (identical on `sql.active_record`), and a `LogSubscriber` subclass
*is* protected (`log_subscriber.rb:183` rescues). But the railtie auto-installs
the notifications instrumenter for every Rails app, so `subscribe(EXECUTE_EVENT)`
looks like the obvious integration point, and `docs/logging.md` warns about the
instrumenter's contract while saying nothing about subscribers. **Docs gap, one
sentence.** Files: `docs/logging.md`.

---

## C. Refusals that misdirect

### C1. `check_input_props!`'s advice names a type the user never declared a variable of — and sometimes has no writable form at all

The refusal itself is right; the advice is the problem. My repros
(`/tmp/claude/graph_weaver/hunt3_collide.rb`, `hunt3_deadend.rb`):

```
nested-collision-as-variable: input fields "nameWithOwner" and "name_with_owner" on Inner
  both map to the prop 'name_with_owner' — pass Inner as a literal in the query, with a
  variable per field, instead of declaring a variable of that type
```

The user declared `$outer: Outer`. They never declared a variable of type
`Inner`. It also fires when the query **never sets the colliding field** —
`collision-in-a-field-we-never-set` above refuses a query that only ever touches
`Outer.ok`.

Worse, when the colliding type is reachable only through a list, the advice has
no writable form — you cannot spell a literal list of runtime-determined length:

```
list-of-colliding-input: input fields "nameWithOwner" and "name_with_owner" on Row both
  map to the prop 'name_with_owner' — pass Row as a literal in the query, ...
```
(for `input Bulk { rows: [Row!]! }`, `mutation($bulk: Bulk!)`). That query is
simply unexpressible, and the message doesn't say so.

Calibration, and it is reassuring: **I verified the CHANGELOG's own
measurement.** Sweeping every input field of the three real schemas
(`/tmp/claude/graph_weaver/hunt3_sweep.rb`):

```
countries: 4 input types, 11 input fields, 0 input collisions
pokeapi:   2262 input types, 11205 input fields, 0 input collisions
github:    402 input types, 1468 input fields, 0 input collisions
```

11 + 11205 + 1468 = **12,684, exactly as claimed, and zero collisions.** So
likelihood is low; only the message needs work.

**Fix:** name the variable and its declared type, and when the type is reachable
only through a list, say plainly that no literal form exists.
**Files:** `lib/graph_weaver/codegen.rb` (`check_input_props!`).

### C2. `graphql: :wire` refuses in `:in_process`'s voice

A url client with no `Testing.config.schema`, tagged `graphql: :wire`, gets a
refusal in which **the word `:wire` never appears** — it talks entirely about
`:in_process`. (The *other* wire refusal, for an in-process client with no url,
is excellent and names the tag.) Files: `lib/graph_weaver/testing.rb:253`,
`lib/graph_weaver/internal/test_clients.rb`.

### C3. Shape drift is blamed on the wrong struct, with a "got" type that is false

**The error a real user meets during a schema migration, pointing at the wrong
field.** My repro (`/tmp/claude/graph_weaver/hunt3_shape.rb`), query
`{ person(id: "1") { id pets { id } } }`, server sends `pets` as an object:

```
object where a list belongs: GraphWeaver::CastError
  failed to cast response into Q::Result::Person: Parameter 'data': Expected type T::Hash[String, T.untyped], got T::Array[String]
list with a null element: ... got type NilClass
list with a scalar element: ... got type String with value "p1"
```

Three things wrong: the word **`pets` never appears**; the struct named is
`Person`, not `Person::Pets` (the callee whose sig actually failed); and
`got T::Array[String]` is **false** — the server sent an *object*, which Ruby's
`Hash#map` silently turned into `[key, value]` pairs on the way in.

Mechanism: `codegen/emit.rb:389-402` gives the emitted `from_h(data)` a
`sig { params(data: T::Hash[String, T.untyped]) }`; sorbet-runtime raises in the
*caller's* frame, so the parent's `rescue StandardError` brands it with
`struct: self`. Compare the leaf path, which is well-named: *"Parameter 'name':
Can't set ...Person.name to {"first" => "Ada"} - need a String"*.

This is the drift case the library exists for, and the harness can never generate
it — its response oracle only builds responses the schema permits. Not a silent
wrong answer: every case refuses, branded, with no data loss.
**Fix:** next to the existing precedent in `Hints.cast_message`
(`lib/graph_weaver/hints.rb:92`), which already inspects `data` to improve a
message — name the key whose value has the wrong shape.
**Files:** `lib/graph_weaver/hints.rb`, `lib/graph_weaver/codegen/emit.rb`.

### C4. Federation `@key` on a reserved field: refused with no way out, or a kwarg that disagrees with the prop

`@key` on `class` → *"Room @key field "class" would become the kwarg 'class:',
which generated code can't declare (a Ruby keyword)"*, with no escape named —
and a subgraph's `@key` field is even less yours to rename than a schema's field
name. `@key` on `hash` generates `def self.slot(hash:)` next to `const :hash_`,
so reading `slot.hash_` and writing it back is a bare `ArgumentError: missing
keyword: :hash`. Files: `lib/graph_weaver/codegen.rb` (`key_params`,
`representation_node`), `lib/graph_weaver/codegen/emit.rb`, `docs/federation.md`.

---

## D. False doc claims (each verified against the code)

1. **`:code`** — `docs/logging.md:102` says "the first GraphQL error's `code`".
   The code is `errors.grep(Hash).filter_map { … }.first`, i.e. the first
   *non-nil* code across all errors. With errors `[{no code}, {code:
   THROTTLED}]` the payload carries `THROTTLED`. **Change the docs, not the
   code** — for alert grouping, a code that exists beats the absence of one at
   position 0. Second half: on the `:errors` path with no codes anywhere, `:code`
   is present with value `nil`, contradicting "when there is one".
2. **`:schema`** — promised as "the schema class's name". `GraphQL::Schema.from_definition`
   returns an **anonymous class**, so `@schema.to_s` is `"#<Class:0x...>"` —
   verified. Both APM samples tag on it verbatim, so that lands in OTel/Datadog
   as a per-process tag value: unbounded cardinality. Fix: `@schema.name || "anonymous"`.
   File: `lib/graph_weaver/in_process.rb:53`.
3. **`:duration_ms`** — "start to parsed response" reads as *the* latency. Under
   `Retry` it is **per attempt and excludes the backoff sleep**: measured
   `duration_ms=[10.93, 10.52, 12.71]` summing to 34ms against **645.9ms** of
   wall clock. No event ever reports what the caller experienced.
4. **`#to_h` / pattern matching on input structs** — the CHANGELOG's v0.7.0
   entry, `docs/generated_modules.md:431-433` and `docs/upgrading.md:118` all say
   `#to_h` and pattern matching use the renamed prop "in results and input types
   alike". `InputStruct#to_h` is `alias_method :to_h, :serialize`, so it emits
   **wire** keys, and an input struct answers no `deconstruct_keys` at all.
5. **`docs/alternatives.md`** — "28 breaking-change notes in the changelog so
   far"; `grep -c breaking CHANGELOG.md` is **30**. (I re-verified the rest of
   that file's checkable claims and they hold, including the subscription refusal
   message.)
6. **`docs/getting_started.md:49`** — "Re-running is safe — every file goes
   through the usual Rails conflict prompt." False for `app/graphql/schema.json`:
   `install_generator.rb#fetch_schema` writes it via `SchemaLoader.refresh!` /
   `introspect` directly, bypassing Thor's conflict machinery. Declining every
   prompt still replaced the dump, and dropped its recorded source url so
   `schema:diff` / `:refresh` lose the endpoint they were pinned to.
7. **README's `:fake` sample** shows `person.name # => "Shakita Stark"`. `faker`
   is a *development* dependency, so an adopter gets `"name-1"`. The headline
   sample reflects the gem's own bundle, not a user's.

---

## The property harness: green, and worth more than last round

All runs on `34970d0`, `~/.rvm/wrappers/ruby-3.4.9/bundle exec`:

| run | wall clock | result |
|---|---|---|
| `bin/round-trip -c 5000` | 238 s | 29,131 round trips across 3 schemas, **0 failures** |
| `bin/round-trip --hostile -c 3000` | 131 s | 14,649 round trips across 3 schemas, **0 failures** |
| `bin/round-trip examples/github/schema.json -c 1500` | 19 s | 2,905 round trips, **0 failures** |
| PokeAPI dump, **`-c 100`** | 69 s | 200 round trips, **0 failures** |
| `bundle exec rspec` | 15.8 s | **1618 examples, 0 failures** |
| `--order rand:1` / `rand:7` | — | 1618 examples, 0 failures each — no order dependence |

**On PokeAPI I ran `-c 100`, not `-c 1000`**, and the reason is itself a finding.
The `-c 1000` background run was killed at **617 s with zero output**: RSS climbed
4.1 → 5.8 → 6.0 GB while system swap sat at 13.6 / 14.3 GB. The tool is
**superlinear in `-c`** (exponent ≈ 1.86 — `-c 100` 69 s, `-c 200` 250 s, peak
4.8 GB), because sorbet-runtime retains every `T::Struct` a parse defines, so the
cost is per-case-times-history. Chunking by seed is *exactly* equivalent
(`seed = options[:seed] + i`, `bin/round-trip:120`) and much cheaper: `-c 100 -s 1`
plus `-c 100 -s 101` covers the same 200 seeds in 132 s instead of 250 s, with RSS
capped. CLAUDE.md's advice for large schemas should become "chunk it by seed"
rather than "lower `-c`".

**Hunt 2's blind spot is mostly closed, and closed properly.** Its complaint was
precise — "nothing feeds a bad input value and asks whether the `InputError`
describes it correctly". `check_hostile_input` now does exactly that, failing a
case four ways (`unbranded`, `mispathed` including list indices, `miskinded`,
`accepted`). That is the right assertion rather than a weaker proxy, so run 2's
6,649 clean input cases are real evidence about error quality in a way hunt 2's
40k were not.

What remains structurally out of reach, stated plainly so nobody over-reads the
green: the response oracle only builds responses the **schema permits**, so a
server that lies about shape is unreachable (that is C4); `errors` alongside
non-nil `data` never occurs; input hostility stops at the five builtin scalars
and enums, so the custom scalars `register_scalars!` bothers to register are the
ones never corrupted; `srb tc` over the emitted source and the cross-query shared
types manifest are untouched, since a fuzzed query is always a population of one;
and the oracle is one-directional — a value the struct *invents* is never checked,
and the last-resort comparison is `object.to_s == wire.to_s`, which accepts a type
change that preserves the printed form.

Two probes into those gaps came back **clean**: an omitted key refuses branded and
names the key (`key not found: "name"`) or is treated as null when nullable, and
an unselected extra key is ignored.

## E. The safety net itself

### E1. The property harness cannot see a renamed prop — so v0.7.0's headline feature has no property coverage

`spec/support/round_trip.rb` uses `GraphWeaver::Inflect.underscore` rather than
the prop rule at six sites (448, 606, 647, 700, 743, 826). Line 647-650 is the
**value-loss check** — `object.class.props.key?(prop)` — so the one net that
would catch a value lost through a renamed prop is exactly the one that cannot
see a renamed prop. Verified by me on a reserved-name schema:

```
$ bundle exec ruby bin/round-trip .../reserved.graphql -c 100
=== 1x ...Result::Row::Nested has no prop for a key the server sent
=== ... GraphWeaver::InputError: unknown key(s): each (did you mean 'each_'?), supplied (…)
```
(at `-c 800`: **5042 failures**, all false). The message is the harness's own,
`spec/support/round_trip.rb:649`.

**The runtime is fine** — I checked separately
(`/tmp/claude/graph_weaver/hunt3_noloss.rb`):

```
props:  [:class_, :hash_, :display_, :to_json_, :each_, :id]
values: {class_: "c", hash_: "h", display_: "d", to_json_: "j", each_: "e", id: "1"}
keys with no prop: []
```

So: no bug in the gem, but the coverage the harness implies **does not exist**,
and CLAUDE.md's mandated pre-commit gate goes red on any schema with a reserved
column. Compounding it: my sweep found **zero** reserved-named fields across
GitHub, PokeAPI and countries, so no real schema in the repo exercises the rename
either. The release's headline feature is covered by hand-written unit specs
alone.

**Fix:** expose the prop rule (`Codegen.prop_name` or `Inflect.prop_name`) and
use it at those six sites.
**Files:** `lib/graph_weaver/codegen.rb` or `lib/graph_weaver/inflect.rb`,
`spec/support/round_trip.rb`.

### E2. ActiveSupport is not in the bundle, and the stand-in cannot model what broke

`require "active_support"` fails under `bundle exec`. `LogSubscriber` and the
railtie are tested against `spec/support/active_support_stand_in.rb`, which is
honest about being a mirror. What it cannot model, and nothing else covers:
Rails' initializer TSort (**the entire mechanism of A3**);
`ActiveSupport::LogSubscriber#call`'s `rescue`; and the `:exception` /
`:exception_object` keys real `Notifications.instrument` adds to the payload.
`spec/railtie_spec.rb` calls the initializer blocks out of a hash and asserts
their declared *names* in order — TSort is never involved.

Worth banking: the two assumptions the stand-in **does** make were checked
against real activesupport-8.1.3.1 and **both hold** — `attach_to(:graph_weaver)`
really does route `execute.graph_weaver` to `#execute`, and `call` really does
skip a nil logger.

**Fix:** add `activesupport` as a development dependency and give the railtie one
real-boot spec. Files: `graph_weaver.gemspec`, `Gemfile.lock`, `spec/railtie_spec.rb`.

### E3. `rake graph_weaver:unused`'s false-negative rate, measured

Probe 1 of the brief, answered with a number. On the repo's own dogfood app,
**4 of 8 truly-unread selections are reported — 50% unreportable**, all
suppressed by one unrelated one-line file
(`CatalogProduct = Struct.new(:id, :name, :price, :kind)`). Scaled against real
corpora:

| swept corpus | files | unreportable |
|---|---|---|
| actionview 8.1.3 `lib` | 122 | 11/20 (55%) |
| activesupport 8.1.3 `lib` | 289 | 10/20 (50%) |
| graphql 2.6.10 `lib` | 422 | 9/20 (45%) |
| 6 Rails gems + graphql | 1655 | **13/20 (65%)** |

Monotone in corpus size; a real app is bigger and adds ERB. And `name` and `type`
are unreportable in **every stock Rails 8 app with one file in it**, because
`app/views/pwa/manifest.json.erb` — generated verbatim by `rails new` — contains
`"name":` and `"type":`.

This is silence, the safe direction, and the footer discloses it — so it is a
paper cut, not a release blocker. But the docs' worked example is the best case,
not the typical one, and that is worth one honest sentence.

---

## Paper cuts (listed, not argued)

- `STRICT=0` turns strict **on** (`!ENV["STRICT"].to_s.empty?`). `tasks.rb:199`.
- `unused` prints a coordinate you can't find in the file it names — it's the
  Ruby prop (`Person.first_name`) for a camelCase or aliased field.
- `unused` on a repo with zero `.graphql` files advises `rake graph_weaver:generate`;
  the sibling task correctly says `no queries in <dir>`. And `1 files swept`.
- Reads in `.rake` (which *is* Ruby) and `.builder` are invisible to `unused`.
- graphql-ruby's own generator emits `class X < Types::BaseObject`, which the
  `SCHEMA` skip doesn't match — so every `field :x` in a scaffolded type counts
  as a read. `docs/getting_started.md:333` claims otherwise.
- The install generator's output block in the docs omits the `append .rubocop.yml`
  line every Rails 8 app gets (the prose below does mention it).
- One output block mixes absolute and relative spellings of the same path two
  lines apart (`schema:diff` / `:refresh`).
- `gem build` emits the usual open-ended-dependency warnings. `sorbet-runtime`
  unbounded is the only one I'd think twice about.
- `bin/round-trip`'s `refused` counter is shared by the response and input loops,
  and in hostile mode most refusals are "no spoilable leaf" — cases that
  exercised nothing. Run 2 reported "14,649 round trips, 3,351 refused by
  codegen" against an 18,000-case budget: the label blames codegen for ~19% of
  the budget that simply had nothing to poke.
- A registered custom scalar's input refusal leaks Ruby's internals —
  `birthday: no implicit conversion of Integer into String` is `Date.iso8601`'s
  message where *"expected a Date or an ISO-8601 String, got Integer"* is the
  sentence. Branded, right `kind`, right `path`; only the wording is weak.
- `spec/support/round_trip.rb:196` embeds a literal NUL in its legal-String pool,
  so `rg` and `grep` both classify the file as **binary** and find nothing in it.
  `"\0"` is the same string value and keeps the file searchable. (This cost one
  agent three dead searches.)

---

## Hunches — no repro, do not act without one

- **`:graph` doesn't cross a Fiber.** `Thread.current[GRAPH]` is fiber-local by
  definition, and the code says so — but graphql-ruby's `Dataloader` is
  fiber-based, so a dispatch that fans out through one would silently drop its
  label. I could not build a case where a generated module's dispatch actually
  crosses a fiber before reaching `instrument`. Doc line at most.
- **`with_graph` early-returns unless an instrumenter is set**, which `instrument`
  re-reads later. Setting the instrumenter between the two gives `graph: nil`
  with everything else right (reproducible, but I could not find a plausible
  trigger — every real path sets it at boot). A latent shape, not a bug.
- `unused`'s `SKIP` matches directory *names* anywhere, so an app with
  `app/models/generated/` loses those reads.
- `FakeClient#read_fields` uses `underscore` for object-pin readers; `RUBY_OWN`
  stops `object.class` leaking, but an AR model with a real `as_json` column
  would be silently fabricated instead of read.
- `Hints.unquoted_keys` looks up `props[underscore(key)]`, so the
  "server sent it unquoted" hint silently skips any renamed field. Cosmetic.

---

## What I tried that turned up nothing (evidence, so nobody re-runs it)

- **The dispatch redesign is sound.** `spec/query_module_spec.rb` already pins
  per-call > per-module > baked > app client, the nested-dispatch case, and the
  raise case, and they hold. I added: `Retry` preserves `:graph` across every
  attempt (`graph=[:billing, :billing, :billing]`, `retries=[0, 1, 2]`, matching
  the docs); the fiber-local is cleared even by a non-`StandardError` raise
  (`Interrupt` → `leftover=nil`); a 0.6.1-generated module's `client_for(client)`
  body still runs unchanged against the now-private method.
- **The LogSubscriber renders all four documented shapes correctly**, including
  `billing/InvoicesQuery`, `(retry 2)`, `[503]`, a missing `:operation` → `query`,
  and a missing `duration_ms` → `event.duration`. Confirmed again in real Rails:
  exactly one line per attempt, no duplicates.
- **The payload key-set spec is still exhaustive** — `spec/logging_spec.rb:250`
  uses `match_array`, not `include`, so `:graph` was added to a genuinely whole-set
  assertion.
- **`:http_status` is correct** on every path: 200-with-errors → `:errors` + 200;
  a raising 5xx → set alongside `:code`; a `TransportError` → absent.
- **Both APM doc samples run on current gems** — opentelemetry-api 1.11.0 / sdk
  1.13.0 and datadog 2.30.0. No API drift. (First time they've been executed;
  `spec/doc_samples_spec.rb` only parses.)
- **Every `require` a generated file emits resolves in a Gemfile-less process**
  with only `graphql` + `sorbet-runtime`: `ruby -Ilib -e 'require "graph_weaver";
  load "spec/generated/person_query.rb"'` → loads and casts.
- **`gem build` ships the right files** — no stray `.gem`, no `coverage/`, no
  `CLAUDE.md`/`DECISIONS.md`. `Gemfile.lock` pins `graph_weaver (0.7.0)`.
  `required_ruby_version >= 3.3` matches the CI matrix (3.3, 3.4, 4).
- **`docs/alternatives.md` re-verified** against the current tree — nothing it
  says graph_weaver lacks has since landed. Only the "28" is stale.
- **Reserved-name props are correct end to end** where it counts: nested `class`
  fields rename and keep `Filter.class` as the coordinate; `graphql_fake("Thing.class" => …)`
  **does** reach the `class_` prop; the `# wire:` comment is emitted at both
  emitter call sites and `srb tc` accepts the output; `did_you_mean` suggests
  `class_` for the wire spelling; output `class` + `class_` siblings are refused
  symmetrically with the new input check.
- **No value is lost through a renamed prop** (see E1).
- **`:code`'s `filter_map.first`, `:graph`'s extent, and `entity_id`** were each
  found by two agents independently, from different directions.
- **No order-dependent failures.** Three orders, 1618 examples each, all green —
  worth stating because four have hidden behind `:defined` order before.
- **An omitted response key and an unselected extra key are both handled** — the
  first refuses branded and names the key, the second is ignored.

---

## Would I publish this?

**Not today — but the gap is days, not weeks, and nothing here is a design
problem.**

The reassuring half is large and I want it on the record, because it is the part
that would have worried me most. The adopter's first hour works: `rails g
graph_weaver:install` on a fresh Rails 8.1 app is **not** broken, the
getting-started path runs verbatim, `zeitwerk:check` and a production boot both
pass with generated output present, and the historically-buggy registration seam
— `register_scalar` / `register_enum` / `extend_type` from initializers and
`to_prepare` — reaches generated source and executes. Every rake task works.
The whole testing harness works from inside an app's own specs. Codegen is
correct: I verified the CHANGELOG's 12,684-input-field measurement exactly, found
zero collisions and zero value loss, and the three genuinely new surfaces this
round was pointed at all survived contact. The property harness came back
**green everywhere it can see** — 46,885 round trips across the fixture schemas,
the hostile mode in both directions, the GitHub dump and PokeAPI, zero failures —
and the suite is 1618 examples green under three orders. That is a gem that has
been built carefully.

What stops me is not the count of findings but their *shape*. Five of them are
the same failure mode: **something reports success while not working.** A graph
whose requests produce no telemetry at all, in the documented spelling, with
nothing at boot or at debug or in `rake graph_weaver:graphs` to reveal it. A
`queries:check` that says "every query validates" about a file containing `nmae`.
An off-switch for PII-bearing logs that a user sets, reads back as nil inside
their own initializer, and that is then silently reverted. A lint that names four
fields and tells you to delete them when your controller serializes all four. A
property harness that would go red — 5042 false failures — on the first schema
that exercises the release's headline feature. Individually these are ordinary
bugs. Together they are a pattern, and a first GitHub issue from any one of them
is expensive in a way a crash is not, because the reporter will have spent a day
before they suspect the gem.

The publish-blockers, in order, and they are small: **A1** (wrap a bare schema in
`graph#client` — the fix is a few lines and it makes `:graph | always` true
again), **A3** (initializer ordering — a `before:`, or a sentinel), **A2**
(refuse a query directory no graph covers), and **A5/B1** (one line in
`errors.rb`: look the segment up in `props` instead of `public_send`ing a name
off the network). None requires a design decision. E1 I'd fix in the same pass
because it is six mechanical call sites and it is the only thing standing between
the rename feature and real property coverage.

Everything else — the doc claims in D, `:in_process` versus a `class` argument,
the refusal wording, the paper cuts — ships as follow-ups without embarrassment.
And two pieces of process evidence argue for one more short round rather than a
long one: this round's findings are **narrower** than hunt 2's and came largely
out of hunt 2's own changes, which is convergence rather than churn; and three
separate findings (A1, A3, E2) were invisible to the suite for the same
structural reason CLAUDE.md already names — the gem cannot test its relationship
with its host. The cheapest durable fix is not any one of these bugs. It is
putting `activesupport` in the bundle and giving the railtie one spec that
actually boots Rails, so the next A3 fails in CI instead of in someone's
production log.
