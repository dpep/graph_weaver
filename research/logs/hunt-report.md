# hunt — what is still wrong with graph_weaver 0.7.0

Baseline main **e898484** verified green before and after: `rspec` 1268/0, `rspec --order rand:424242` and `--order rand:99` 1268/0, `srb tc` clean, `bin/generate` "already up to date", `bin/federation-diff` matches 3/3 subgraphs, `bin/round-trip -c 2000` 11646 round trips / 0 failures. `git status` clean at finish. Nothing committed.

Findings are ranked by user harm: **silent wrong answer > crash > bad message > paper cut**, and within a class by how likely the shape is. Every numbered finding has a runnable repro. Hunches are in their own list at the bottom.

Out of scope by instruction (another agent owns them): input-error surfacing, i18n keys, header procs, case-insensitive response headers. Findings in `errors.rb` / `coerce.rb` / `input_struct.rb` / `transport/*.rb` on *other* topics are reported and flagged as contested files.

---

## A. Silent wrong answers

### A1. `Transport::HTTP`'s pool is not fork-safe — forked workers share the parent's socket and get each other's responses
**Harm: silent wrong answer, in production.** A connection sitting in `@idle` at `fork` time is inherited by every child. `with_connection` has no notion of which process opened a socket, so N workers interleave requests on one fd and a caller receives a well-formed GraphQL response to *another process's* query. No exception is raised.

The trigger is the documented boot path: Puma `preload_app!` (or Sidekiq) plus an initializer that introspects — `GraphWeaver.new(url, cache: true).schema` — which leaves exactly one warm socket in the pool before the fork.

```
$ bundle exec ruby /tmp/claude/graph_weaver/hunt-thread-1/probe3_fork.rb
parent warmed pool: idle=1
{"pid":13663,"ok":30,"crossed":10,"errs":{}}
{"pid":13664,"ok":31,"crossed":9,"errs":{}}
{"pid":13665,"ok":38,"crossed":2,"errs":{}}
```
21/120 responses crossed. Reproduced independently, fails every run. The control `probe3_cold.rb` (same test, pool *not* warmed before the fork) is `crossed:0` in all three children, which pins it on the inherited socket rather than on in-process threading.

Fix: record `Process.pid` on the pool and, when it differs, abandon `@idle` before leasing — drop the entries *without* `finish`, since closing would kill the fd the parent is still using.
Files: `lib/graph_weaver/transport/http.rb` (contested file, different topic).

### A2. A second `graphql_*` helper in one example silently discards the first graph's pins
**Harm: silent wrong answer, in exactly the multi-graph shape 0.7.0 shipped for.** `claim_mode!` calls `TestClients.install(mode)` unconditionally, and `install` resets `@clients = {}` and `@context = nil` — even when that mode is already installed. So the second helper clears the first one's stand-in.

```
D1 orders.who  => "ADA"                      # one fake: the pin applies
D2 orders.who  => "who-1"   (want "ADA")     # two fakes: orders' pin is gone
D2 billing.bwho => "BOB"    (want "BOB")
```
Repro: `/tmp/claude/graph_weaver/hunt-seams/repro_A2.rb` — copy to `spec/hunt_scratch_spec.rb`, `bundle exec rspec spec/hunt_scratch_spec.rb`. The example asserts on fabricated defaults instead of its pins, with no error and no warning — the test is green and wrong.

Fix: `claim_mode!` should install only when the mode actually changes (or `install` should keep `@clients`/`@context` when `@mode == mode`), so a second helper *adds* a stand-in rather than clearing the table.
Files: `lib/graph_weaver/internal/test_clients.rb`, `lib/graph_weaver/rspec.rb`.

### A3. `graphql_context` set before a mode helper is silently dropped
**Harm: silent wrong answer.** Same root cause as A2 (`install` nils `@context`). Resolvers run unauthenticated and the example never notices.

```
A1 (context after helper)  => "ada"      # ok
A2 (context before helper) => "nobody"   # silently dropped
A4 (context block wrapping the helper call) => "nobody"  # inside AND after
```
Repro: `/tmp/claude/graph_weaver/hunt-seams/repro_A3.rb`. `graphql_context(current_user: alice)` followed by `graphql_in_process(Reviews::Schema)` is a natural spelling — the rspec.rb docstring itself shows the helper being used to pick a subgraph per example.

Fix: as A2. Files: same.

### A4. A top-level `register_scalar` written *after* a graph declaration never reaches that graph
**Harm: silent wrong answer — generated props degrade to `T.untyped`, which is the whole product.** `GraphBuilder#initialize` copies `Codegen.registry` at declaration time. `graph.rb`'s own comment is honest about this; the **v0.7.0 CHANGELOG promises the opposite**:

> Nothing changes for a single-schema app: … top-level registrations still reach every graph, so a `register_scalar` in an initializer can't be dropped by declaring a second schema.

```
$ bundle exec ruby /tmp/claude/graph_weaver/hunt-seams/order.rb
register_scalar BEFORE graph declaration  => const :total, BigDecimal
                                             untyped_scalars: []
register_scalar AFTER graph declaration   => const :total, T.untyped
                                             untyped_scalars: ["Money"]
```
In Rails this is decided by **alphabetical initializer filename order**: scalars in `config/initializers/graph_weaver.rb` and the graph in `config/initializers/billing.rb` gives b-before-g and every registration is dropped. The `untyped_scalars` advisory does fire — but it says "Money is an unregistered custom scalar" to a user who registered it, which misdirects rather than helps.

Fix: resolve a graph's registry lazily (top-level registry + the block's own overlay, read at generation) instead of snapshotting at declaration — or, if the snapshot is deliberate, refuse a top-level registration made after any graph is declared and correct the CHANGELOG.
Files: `lib/graph_weaver/graph.rb`, `lib/graph_weaver/codegen/registry.rb`, `CHANGELOG.md`.

### A5. In a multi-graph app, a non-`:live` tag leaves `GraphWeaver.client` pointing at the real endpoint
**Harm: silent escape — a tagged example can make a live network call.** `rspec.rb` swaps the app client slot only `if GraphWeaver.graphs.one?`. Declare a second graph and `graphql: :fake` — whose entire promise is "fabricated data; no resolvers run" — leaves the production client in place for everything that isn't a generated module.

```
E2 client.execute => {"data" => {"who" => "THE REAL SERVER"}}
E2 real endpoint was hit: 1 time(s)
```
Repro: `/tmp/claude/graph_weaver/hunt-seams/repro_A5.rb` (stubbed so the test can observe; in a suite without webmock this is a real outbound request).

The design choice is defensible — with several graphs there is no one right answer for the app slot — but the failure mode should be a refusal, not a live request. The library's own principle is "refuse rather than guess".

Fix: under a non-`:live` mode in a multi-graph app, put a *refusing* client in `GraphWeaver.client` that raises naming the graphs, rather than leaving the real one.
Files: `lib/graph_weaver/rspec.rb`.

### A6. `Time`/`DateTime` serialize drops sub-second precision — the round trip is lossy
**Harm: silent wrong answer, against servers that write sub-second timestamps.** `STDLIB["Time"]` and `["DateTime"]` use bare `serialize: :iso8601`, which takes no precision argument.

```
server sent      : "2024-01-15T10:20:30.500Z"
parsed Ruby Time : 2024-01-15 10:20:30.5 UTC   (subsec = 1/2)
sent back on wire: "2024-01-15T10:20:30Z"      # 500ms gone
```
**Scope qualification** (worth stating, because it changes who is affected): graphql-ruby's own `ISO8601DateTime` defaults to `time_precision = 0`, so a stock Ruby server round-trips cleanly. It bites against a server that sets `time_precision = 3` and against **any JS/Apollo server**, where `Date#toISOString` always writes milliseconds. That is a large population, and the failure mode — `execute(since: last.updated_at)` silently widening a window, or an `updatedAt` concurrency token no longer matching — is quiet.

Why nothing caught it: `internal/values.rb:125` fabricates timestamps as whole seconds, so `bin/round-trip`, `graphql: :fake` and the property test are structurally blind to it.

Fix: emit `v.iso8601(v.subsec.zero? ? 0 : 6)`, and make `Values#scalar` fabricate a fractional timestamp sometimes so the fuzzer can see it.
Files: `lib/graph_weaver/codegen/scalar_type.rb`, `lib/graph_weaver/internal/values.rb`, `docs/scalars.md`.

### A6b. The `QUERY` heredoc `.rstrip`s every line, silently editing the value of a GraphQL block-string argument
**Harm: silent wrong answer — a different string reaches the server than the one in the `.graphql` file.** `Emit#emit_module` writes the query as `out << "    #{line}".rstrip` (`codegen/emit.rb:248`). Trailing whitespace on a line is *significant* inside a `"""…"""` block string: the spec's BlockStringValue strips only common indentation and leading/trailing blank lines.

```
$ bundle exec ruby /tmp/claude/graph_weaver/hunt-fuzz/repro_block_string.rb
trailing spaces on a line:
  value in the .graphql file      : "keep these   \ntail"
  value the generated QUERY sends : "keep these\ntail"       *** DIFFERENT
a line of only spaces:
  value in the .graphql file      : "a\n   \nb"
  value the generated QUERY sends : "a\n\nb"                  *** DIFFERENT
```
Reproduced independently. Fix: strip only the line's own trailing newline, keeping the existing delimiter-collision guard.
Files: `lib/graph_weaver/codegen/emit.rb`.

### A7. `Coerce.float` turns an overflowing numeric string into `±Infinity` without a word
**Harm: silent wrong answer.** `Kernel#Float("1e400")` returns `Infinity` rather than raising, and `Coerce.float` has no `finite?` guard — unlike `Coerce.integer`'s `whole`, which does. Applies in both directions (variable and response cast).

```
Coerce.float("1e400")   => Infinity
Coerce.float("1e-400")  => 0.0
Coerce.integer(Infinity) => ArgumentError: expected an Int, got Infinity — not a whole number
```
Repro: `/tmp/claude/graph_weaver/hunt-coerce/float_overflow_repro.rb`. Over HTTP it then dies far away as "variables are not JSON-serializable"; through a `JSON` or unregistered scalar it just travels.

Fix: refuse a non-`finite?` parse in `Coerce.float`'s String branch, matching what `whole` already does for `Int`.
Files: `lib/graph_weaver/coerce.rb` (contested file, different topic).

### A8. `Testing::Config#schema` memoizes the located dump for the process and no reset but `Testing.reset!` clears it
**Harm: silent wrong answer, order-dependent across spec files.** `@schema || (@located ||= SchemaLoader.locate)` is not invalidated by `GraphWeaver.schema_path=`, `GraphWeaver.root=`, `reset_graphs!`, or `reset_registrations!`, so `:fake` fabricates the previous schema's shapes.

```
config.schema with schema_path=a: fields=["alpha"]
config.schema with schema_path=b: fields=["alpha"]  (expected ["beta"])
SchemaLoader.locate (no memo):    fields=["beta"]
after reset_graphs! + reset_registrations!: ["alpha"]
after Testing.reset!:                       ["beta"]
```
Repro: `/tmp/claude/graph_weaver/hunt-thread-1/probe8_located.rb` (found independently twice). This is exactly the order-dependence shape CLAUDE.md warns about, and `spec/root_spec.rb` reassigns `GraphWeaver.root` per example.

Fix: key the memo on the resolved path, or drop it — `locate` is a file read.
Files: `lib/graph_weaver/testing.rb`.

### A9. `Internal::Util.composed?` caches per path for the process life and survives every reset
**Harm: silent wrong answer / misleading refusal.** `:wire` picks `:in_process` where it should pick `:router`, and `:router` refuses with "graph :api is in none". The comment justifies the cache with "nothing here rewrites a supergraph mid-process", but nothing enforces it and no reset hook clears it.

Repro: `/tmp/claude/graph_weaver/hunt-thread-1/probe4_memo.rb`. Narrower trigger than A8 — needs a supergraph recomposed at a stable path inside one process (a `before` hook that composes, or chained rake tasks).

Fix: key on path + mtime/size, or clear it from `reset_graphs!`.
Files: `lib/graph_weaver/internal.rb`.

### A10. `docs/testing.md` still describes the 0.6.x tag mechanism — the documented override idiom now silently runs against the fake
**Harm: silent wrong answer in a user's suite.** 0.7.0 moved a mode's client into `Internal::TestClients`, which `QueryModule#default_client` consults *above* `GraphWeaver.client`. `docs/transports.md:190` says this correctly; `docs/testing.md:59-63` still claims the opposite —

> "Both at once and the assignment wins… a tagged example with a `before` of its own runs against the client the `before` built"

```
untagged -> ["THROTTLED"]
tagged   -> GraphWeaver.client=GraphWeaver::Testing::FailureClient errors=[] data="ping-1"
```
`GraphWeaver.client` *reads back* as the FailureClient, so the assignment looks like it took — but the generated module gets the fake. An example written the documented way asserts on a failure path and never exercises one. The tag is usually on an outer `describe` (the doc's own advice), so nobody rereads it.
Repro: `/tmp/claude/graph_weaver/hunt-docs-1/testing_md_40_63_spec.rb`.

Also stale in the same file: `docs/testing.md:41-43` "Generate them **without** a baked `client:` — a module that has one never consults `GraphWeaver.client`" — 0.7.0's headline change is exactly that a baked client no longer escapes the tag.

Fix: say that a mode's stand-in outranks `GraphWeaver.client=`; the escapes are a per-call `client:`, `MyQuery.client =`, or `graphql: :live`. Delete the parenthetical.
Files: `docs/testing.md`.

---

## B. Crashes

### B0. A comment above a single-line anonymous operation corrupts the generated `QUERY` — and `generate!` *and* `verify` both report success
**Harm: crash at runtime for every call of that module, shipped by a green generation.** Arguably A-class: the safety net lies rather than the answer being wrong.

`Codegen#declare_operation_name` (`codegen.rb:371`) splices the module name into the query text at a byte offset computed from graphql-ruby's `operation.line`/`col` — and graphql-ruby reports a **wrong `col`** when an operation's body is on one line and a comment precedes it (`GraphQL.parse("# c\nquery { a { b } }").definitions.first.col` is `5`, not `1`). `@schema.validate` runs *before* the splice (`codegen.rb:333`) and nothing re-validates after.

End-to-end through the normal file path, `/tmp/claude/graph_weaver/hunt-seams/splice_e2e.rb`:
```
generate!         => ["…/out/health_query.rb"]
verify_generated! => true
ruby -c           => true
```
and the file it wrote:
```ruby
QUERY = T.let(<<~'GRAPHQL', String)
  # health check — hit this from the uptime probe
  { thing(s: "x") { v } }query HealthQuery
GRAPHQL
OPERATION_NAME = T.let("HealthQuery", T.nilable(String))
```
`execute` posts a document with **no** operation named `HealthQuery` while sending `operationName: "HealthQuery"`.

**Exact scope** (`/tmp/claude/graph_weaver/hunt-seams/splice_scope.rb`) — narrower than it first looks, which is worth knowing before anyone panics:
```
OK      anonymous, no comment            declares="Health"
BROKEN  anonymous + comment              declares=nil   (operationName still sent)
BROKEN  anonymous `query` + comment      QUERY DOES NOT PARSE
OK      NAMED + comment                  declares="Health"
OK      NAMED, no comment                declares="Health"
OK      anonymous + comment, multiline   declares="Health"
OK      anonymous + blank line           declares="Health"
OK      anonymous + leading spaces       declares="Health"
```
It needs an **anonymous operation whose body is on one line, preceded by a comment**. Named operations, multi-line bodies, blank lines and leading indentation are all safe. That is still a normal thing to write, and the repo's own `examples/github/queries/*.graphql` are anonymous. Every observed variant fails loudly at parse or at operation lookup — no silent-wrong-answer tail found.

Fix: don't trust `operation.line`/`col` for the splice — find the operation start by scanning for the first non-ignored token, or re-validate the spliced query and refuse if it no longer declares the name.
Files: `lib/graph_weaver/codegen.rb` (`declare_operation_name`, ~359-376).

### B1. net/http failures that aren't `Errno`/`IOError`/`Timeout` escape unwrapped, and `Retry` won't retry them
**Harm: crash past `rescue GraphWeaver::Error`, plus a retriable failure treated as fatal.** `Net::HTTPBadResponse` (garbage status line — a misbehaving proxy, or HTTP to a port speaking something else) and `Zlib::DataError` (mangled gzip body) are plain `StandardError`s and go straight through. The bundled Faraday transport wraps the same failure correctly, so the two shipped transports disagree.

```
HTTP   : Net::HTTPBadResponse    (GraphWeaver::Error? false)
Faraday: GraphWeaver::TransportError (GraphWeaver::Error? true)
Retry  : Net::HTTPBadResponse; server saw 1 request(s)   (3 = retried, 1 = not)
Zlib::DataError (GraphWeaver::Error? false) — incorrect header check
```
Repro: `/tmp/claude/graph_weaver/hunt-thread-1/probe5b.rb`, `probe6_gzip.rb`.

Fix: extend the registration in `http.rb` to include `Net::HTTPBadResponse`, `Net::ProtocolError`, `Zlib::Error`.
Files: `lib/graph_weaver/transport/http.rb` (contested file, different topic).

### B2. `Transport::Faraday#url` drops a query string, so `graphql: :wire` stubs the wrong endpoint
**Harm: crash, with a message that blames the user.** Faraday's `url_prefix=` moves a url's query into the connection's default `params` and strips it from `url_prefix`; `@url = @connection.url_prefix.to_s` therefore reports a url that is **not** where requests go.

```
transport.url      : "http://api.test/graphql"
actual POST        : http://api.test/graphql?apiKey=abc
```
Under `:wire` the stub goes on the former and the request goes to the latter:
```
WebMock::NetConnectNotAllowedError: Real HTTP connections are disabled.
  Unregistered request: POST http://api.test/graphql?apiKey=abc
  registered request stubs: stub_request(:post, "http://api.test/graphql")
```
Repro: `/tmp/claude/graph_weaver/hunt-seams/repro_B2.rb` (a table over http/faraday × 8 url shapes; faraday + query string is the only failure — base path, https, trailing slash, explicit port, root path and no-path all pass on both transports).

Beyond `:wire`, `#url` is a public attribute that lies — it is also what the boot log line prints.

Fix: reconstruct from `url_prefix` plus `params` (`uri = conn.url_prefix.dup; uri.query = conn.params.to_query if conn.params.any?`), or keep the caller's url string when one was given.
Files: `lib/graph_weaver/transport/faraday.rb` (contested file, different topic).

### B3. Turning on debug logging changes the exception class for an unserializable variable
**Harm: crash / wrong error class, and a Heisenbug.** `Transport#perform` `JSON.generate`s the variables in its debug log line *before* the guarded encode, so a raw `JSON::GeneratorError` escapes the `GraphWeaver::Error` umbrella whenever a logger is listening at debug.

```
logger off  : GraphWeaver::Error: variables are not JSON-serializable: NaN not allowed in JSON
logger DEBUG: JSON::GeneratorError: NaN not allowed in JSON
rescue GraphWeaver::Error catches it? off=true  debug=false
```
Repro: `/tmp/claude/graph_weaver/hunt-coerce/debug_log_json_repro.rb`. `spec/http_spec.rb:240` covers only the no-logger path. Same shape at `in_process.rb:69` (where without a logger the NaN reaches the schema, so logging changes *behaviour*, not just the class) and via `Internal::RequestKey.normalize_variables`.

Fix: encode once up front and log the already-encoded body, so one rescue covers every caller.
Files: `lib/graph_weaver/transport.rb` (contested, different topic), `lib/graph_weaver/in_process.rb`, `lib/graph_weaver/internal.rb`.

### B4. Two doc samples raise as written
**Harm: crash on copy-paste.**
- `docs/transports.md:187` — `Codegen.generate(..., client: MyApi::CLIENT)` passes the live object; `Codegen#initialize` requires a named constant or String, and the constant a reader actually builds is a `GraphWeaver::Client` instance, not a `Module`. Output: `ArgumentError: client: must be a named constant or String`. Repro: `/tmp/claude/graph_weaver/hunt-docs-1/baked_client.rb`.
- `docs/federation.md:234-239` — the `Federation::Drift` sample omits `require "graph_weaver/federation"`, which nothing but `tasks.rb` requires. Output: `NameError: uninitialized constant GraphWeaver::Federation`. Repro: `/tmp/claude/graph_weaver/hunt-docs-1/drift.rb`.

Files: `docs/transports.md`, `docs/federation.md`.

---

## C. Bad messages (the right thing happens, or nothing does, and the message misdirects)

### C1. `schema -> { nil }` crashes with `undefined method 'validate' for nil`
The lambda form is what the docs *require* in a Rails initializer, and a lambda returns nil easily (`Rails.configuration.x.billing_schema`, a guarded `defined?(…) && …`, a `safe_constantize`). `Graph#schema` passes nil straight through; `dump_path`, `supergraph` and `live_schema` all quietly answer nil too, so a later `:in_process` refusal blames `GraphWeaver.client` instead.
```
RAISE schema -> { nil } then generate!  => NoMethodError: undefined method 'validate' for nil
```
Repro: `/tmp/claude/graph_weaver/hunt-seams/gen.rb`. Fix: refuse a nil/non-schema result in `Graph#schema`, naming the graph and the `schema` setting. Files: `lib/graph_weaver/graph.rb`.

### C2. `GraphWeaver.parse` is unusable under any mode in a multi-graph app, and the advice is impossible
```
E1 GRAPH baked? false
E1 RAISE => GraphWeaver.parse::Who doesn't say which of this app's graphs (:orders, :billing)
           it was generated from, so :fake has nothing to run it against —
           regenerate (rake graph_weaver:generate).
```
`parse` is the runtime API; it generates no file, so `rake graph_weaver:generate` cannot possibly help, and `parse` takes no `graph:` to say which. Dead end. Repro: `/tmp/claude/graph_weaver/hunt-seams/repro_A5.rb`.
Fix: give `parse` a `graph:` keyword that bakes `GRAPH` (and/or fall back to the graph whose schema the module was parsed against). Files: `lib/graph_weaver.rb`, `lib/graph_weaver/codegen.rb`, `lib/graph_weaver/internal/test_clients.rb`.

### C3. Under `:wire` with a `context:` proc, `graphql_context` refuses by telling you to do what you already did
```
G2 RAISE => context: is a proc, so it is answered from a request's headers — and nothing
            here made a request. Tag the example graphql: :wire, …
```
The example *is* tagged `graphql: :wire`. `Util.context!` raises the same sentence for `:in_process`, `:router` and `:wire`, but only the first two can act on it. Even reading the context back (`graphql_context` with no argument) raises. Repro: `/tmp/claude/graph_weaver/hunt-seams/repro_C3.rb`.
Fix: branch the message — under `:wire`, say the proc is answered from the request's headers and point at `GraphWeaver.new(url, headers: …)`. Files: `lib/graph_weaver/internal.rb`, `lib/graph_weaver/rspec.rb`.

### C4. Two graphs baking the same `client:` — `:wire` serves only the first, and blames the second's queries
`wire_targets` does `.uniq(&:first)`, so one graph's schema answers for both.
```
H1 orders  => {"data" => {"who" => "orders-resolver"}}
H1 billing => {"errors":[{"message":"Field 'bwho' doesn't exist on type 'Query' (Did you mean `who`?)"…
```
The comment claims "two graphs on one url get one server, as they would in production" — but production has one schema there serving both graphs' queries, which is not what this does. Repro: `/tmp/claude/graph_weaver/hunt-seams/repro_C4.rb`.
Fix: refuse — "graphs :orders and :billing both post to <url>; `:wire` can serve one schema per endpoint". Files: `lib/graph_weaver/rspec.rb`.

### C5. `WebMock.reset!` inside a `:wire` example fails the example from inside the gem's `after` hook
```
RuntimeError: Request stub  POST http://reset.test/graphql  is not registered.
  webmock/stub_registry.rb:57 … ./lib/graph_weaver/rspec.rb:173 in 'unserve!'
```
`unserve!` is unconditional. A group-level `after { WebMock.reset! }` runs *before* the config-level hook (rspec runs `after` innermost-first), so this is a common shape. When the example also failed for a real reason, this piles a second, unrelated failure on top of it. Repro: `/tmp/claude/graph_weaver/hunt-seams/repro_C5.rb`.
Fix: make `unserve!` tolerant of an already-removed stub. Files: `lib/graph_weaver/rspec.rb`.

### C6. `namespace "::Billing"` is refused with a message that blames the file name
```
RAISE => name: must be a constant name, got "::Billing::PersonQuery" — it comes from the
         file name, so rename the file to one a constant can spell …
```
The file is `person.graphql`, which is fine; the culprit is the `namespace` setting. A leading `::` is how you'd root-anchor a constant in Ruby. (Nested namespaces work correctly — `namespace "Acme::Billing"` generates and loads.) Repro: `/tmp/claude/graph_weaver/hunt-seams/gen.rb`.
Fix: refuse a leading `::` at declaration in `GraphBuilder`, naming `namespace` — or strip it. Files: `lib/graph_weaver/graph.rb`.

### C7. Cross-type date/time variables surface Ruby's raw conversion error
v0.7.0 fixed `DateTime`-for-`Date`; the other three directions still hit `Date.iso8601(aTime)` / `Time.parse(aDate)`. `Time.zone.now` for an `ISO8601Date` argument is a routine Rails call.
```
on: Time.utc(...)       => $on of R: no implicit conversion of Time into String
on: TimeWithZone-alike  => $on of R: no implicit conversion of TimeWithZoneAlike into String
at: Date.new(...)       => $at of R: no implicit conversion of Date into String
```
Repro: `/tmp/claude/graph_weaver/hunt-coerce/datetime_crosstype_repro.rb`. Fix: accept a date-or-time-shaped object (`respond_to?(:to_date)` / `:to_time`) and convert; keep refusing anything else, but as `expected a Date, got a Time`. Files: `lib/graph_weaver/codegen/scalar_type.rb`.

### C8. `GraphWeaver.parse` on an operation named `T` dies with `uninitialized constant …T::Sig`
The generated module `T` shadows Sorbet's `T` inside its own body. Codegen is safe (module names always carry a `Query`/`Mutation` suffix — a `t.graphql` becomes `TQuery`); only `parse` from a raw string, or an explicit `name: "T"`, is exposed. `Struct`, `Module`, `Kernel`, `Class`, `Hash` and `Comparable` all parse fine, so `T` is the single reserved name.
```
$ bundle exec ruby /tmp/claude/graph_weaver/hunt-seams/reserved.rb
T => NameError: uninitialized constant GraphWeaver.parse::T::Sig
```
Fix: refuse `T` as a module name, naming the collision. Files: `lib/graph_weaver/codegen.rb` / `lib/graph_weaver/internal.rb`.

---

**C9.** The struct-method refusal describes an **aliased key** as a field and suggests a query you can't write: for `query P { thing { class: a } }` it says *"Thing.class would become prop 'class' … alias it in the query (`classValue: class`)"*. There is no `Thing.class`, and `classValue: class` is unwritable — the advice should be `classValue: a`. `/tmp/claude/graph_weaver/hunt-fuzz/repro_alias_advice.rb`. `codegen.rb` (`check_output_prop!`).

**C10.** The class-name collision refusal names neither key — *"result keys on Thing both generate the class AB — alias one to a distinct name"* (`codegen.rb:1286`), while the sibling prop-collision message one screen up *does* name both. `hunt-fuzz/p10_classname.rb`. Fix: make `taken` a hash so the message can name both.

## D. Paper cuts and doc staleness

- **D1. `docs/upgrading.md` omits four of v0.7.0's breaking changes** and opens "Small, and almost all of it is the rspec tags." Missing: `client` that isn't a constant now refused at generation; a `cast:`/`serialize:` proc returning a value now refused at registration; a router's `fake:` refuses `seed:`; and the `DateTime`-for-`Date` wire change. The first three turn previously-running code into a raise. Files: `docs/upgrading.md`.
- **D2. `graph :a` and `graph "a"` are two different graphs.** `@graphs.index { |c| c.name == name }` never normalizes, so the name is its identity only per spelling. Contradicts "safe to re-run (the graph's name is its identity)". Files: `lib/graph_weaver.rb`.
- **D3. A `schema:` proc is called once per accessor** — 3 calls for `dump_path` + `supergraph` + `live_schema`, repeated on every `generate!` pass. Fine for a constant lookup, wasteful for anything that loads. Files: `lib/graph_weaver/graph.rb`.
- **D4. A `cast:` that returns `nil` serializes to `""`** rather than being branded, because the serializer is applied outside `Coerce.variable`'s rescue. Needs a badly-written codec. Files: `lib/graph_weaver/codegen/emit.rb`.
- **D5. `README.md:189`** still says upgrading covers "what 0.5.0 moved"; **`docs/getting_started.md:328`** links `[above](#2-what-the-generator-writes)`, a heading that doesn't exist (should be `#2-run-the-generator` — the only broken anchor in the doc set); **`docs/upgrading.md:196`** omits `BigDecimal` from the no-pin-needed scalar list that `docs/testing.md:211` and `docs/scalars.md:161` both include correctly.
- **D6. There is no doc-samples spec.** Zero of the 110 fenced `ruby` samples in README + `docs/` are parsed, executed, or name-checked; the only fenced-code extraction in the suite is `install_generator_spec.rb:113` pulling a `yaml` block out of `docs/editors.md`. Every A10/B4/D1/D5 finding lives in that gap. Ten of the 110 samples don't parse under `ruby -c`, but all ten are deliberate `...` elisions — a future spec needs an allow-list.

---

## Hunches — no repro, do not act without one

- **Non-atomic lazy init of process-global containers**: `@graphs ||= []`, `@composed ||= {}`, `Codegen.registry`'s `@registry ||=`, `Testing.config`'s `@config ||=`. Two threads declaring graphs at boot could lose one side's writes. Narrow (boot is usually single-threaded) but the failure is a whole graph disappearing.
- **A router shared by two graphs is `reset!` by whichever module runs next**, wiping `#trace` — which the docs say specs assert on — and any `fake` pins, mid-example. `testing.rb:171`, `internal/test_clients.rb:81`.
- **The railtie's watch/ignore initializers snapshot `GraphWeaver.graphs` before `to_prepare` runs**, while `graph.rb`'s docs bless declaring graphs from `to_prepare`. That would give a watcher over the default `queries_paths` and a Zeitwerk ignore list missing the graph's `output:` — the production eager-load `NameError` the railtie comments describe. **Needs the throwaway Rails app CLAUDE.md prescribes.** `lib/graph_weaver/railtie.rb:44,96`.
- **`CHANGELOG.md:6-14`** shows `schema Billing::Schema` (bare constant) in a graph block and 20 lines later says a bare constant in an initializer raises under Zeitwerk. The changelog block is what an upgrader copies first.
- **`bin/round-trip -c 2000` reaches a query graphql-ruby says will become an error.** Against the Reviews fixture it logs `GraphQL-Ruby encountered mismatched types in this query: \`ID!\` (at 1:95) vs. \`String!\` (at 1:245). This will return an error in future GraphQL-Ruby versions` — i.e. the fuzzer drafted a document with an unmergeable field conflict, and something in the pipeline let it through. graph_weaver refuses the *simple* form of this (verified below), so the conflict is arriving across fragments; the round trip still reports 0 failures, so nothing is wrong today, but a future graphql-ruby turns it into a hard error. Reproduce with `bundle exec ruby bin/round-trip -c 2000 2>&1 | grep -B2 legacy_invalid`. Worth isolating.
- **`Int` is never range-checked** — `execute(count: 2**200)` goes out as a JSON number for an `Int!` and only the server objects. **`BigDecimal#to_s("F")` expands exponents** — `BigDecimal("1e400")` becomes a 403-character digit string on the wire. Both are "refuse rather than guess" arguments, neither is wrong today.

---

## What I tried that turned up nothing (evidence too)

- **The pool's in-process concurrency is solid.** 32 threads × 8 requests against a server mixing keep-alive 200s, HTML 500s, abrupt closes and slow responses finished with all permits returned, no leaked or dead pooled socket, no deadlock, no thread left alive. A `Connection: close` server produces no bad-state pooled connection. `Client#schema`'s mutex and `Retry`'s per-call state are clean. The fork bug (A1) is genuinely about the inherited fd, not the pool's locking.
- **`reset_graphs!` / `reset_registrations!` cannot half-reset a `generate!` run** — `graphs_for` snapshots the list and `Registry#initialize_copy` deep-copies all three tables, so a graph block cannot reach back into the top-level registry (verified: a graph-scoped `register_scalar` does not leak up). `reload_generated!` fired mid-`execute` did not corrupt anything.
- **The router memo *is* correctly invalidated.** Re-declaring a graph with a different supergraph yields a fresh `Router` (`@built_routers` is keyed by supergraph path), and `config.router=` nils the cache. This was a prime suspect and it is clean.
- **`:wire`'s url handling is right everywhere except faraday + query string** (B2): base path, https, trailing slash, explicit port, root path and bare host all work on both transports, and `WebMock.reset!`-per-example from `webmock/rspec` runs *after* the gem's `after` hook, so a partially-failed `serve!` cannot leak a stub into the next example.
- **Nested namespaces work**: `namespace "Acme::Billing"` emits `module Acme; end / module Acme::Billing; end / module Acme::Billing::PersonQuery`, passes `ruby -c`, and loads. `Pathname` for `output`, `queries` and `schema` all work. `MyQuery.client =` set in `before(:all)` still beats an installed mode, as documented.
- **Every post-0.7.0 drift marker the brief listed is already clean in `docs/`**: no `graphql: false`, no `config.default_mode = nil`, no `module_name:`, no N-`generate!`-with-`reset_registrations!` recipe, no three-keyword stdlib `register_scalar`, no value-returning `cast:` proc, no `client` given a url, no bare initializer constant, no `config.context =` inside an example, no `live_schema` twin, and `SUPERGRAPH=` is correctly described as a one-run override. Every `GraphWeaver::*` constant and `GraphWeaver.*` method named in a doc sample resolves with the arity the sample uses.
- **The property harness is clean at scale**: `bin/round-trip -c 5000` (29,126 trips, 0 failures), `--hostile -c 3000` (7,963, 0), `examples/github/schema.json` at `-c 300` and `-c 1500 -s 90210` (0), plus a purpose-built schema fuzzer over 600 random schemas (2,404 response + 2,254 hostile + 586 input trips, 0 failures). Nested lists (`[[Int]]`, `[[[String!]!]]`, 4-deep), 60-level recursion, 300 sibling fields, literal `@skip`/`@include`, guarded spreads, repeated inline fragments on one type, unions inside interfaces inside fragments, enum values that are keywords / lowercase / `_`-prefixed / digit-leading, module-level shadowing (`T`, `GraphWeaver`, a struct shadowing an enum), `__typename` aliased away under live dispatch, and `Other`/`Result` as union member names all round-trip both directions with no value loss.
- **Reserved and keyword field names are handled correctly** — the strongest single result here. Every name that would shadow a `T::Struct`/`Object` instance method (`class`, `object_id`, `hash`, `to_h`, `serialize`, `method`, `send`, `freeze`, `inspect`, `dup`, `clone`, `tap`, `then`, `itself`, `display`, `extend`, `public_send`, `__send__`, `instance_variable_get`) is refused at generation with a message that names the field and the fix: *"Query.to_h would become prop 'to_h', which every generated struct already defines — alias it in the query"*. Every Ruby **keyword** (`def end if nil self begin do while return yield super`) plus `props`, `from_hash`, `type` and `name` generates fine — `ruby -c` passes, every reader returns its value, and `props`/`from_hash` correctly don't collide because they are class methods. `/tmp/claude/graph_weaver/hunt-seams/keyword_fields.rb`, `field_names.rb`.
- **Alias collisions are handled correctly.** `query C { a: id a: name }` and `{ a: name a: age }` are both refused with a `ValidationError`; an alias colliding with a sibling field name (`{ name id: name }`) generates two correctly-typed props; the same field twice under one alias collapses to one prop. `/tmp/claude/graph_weaver/hunt-seams/alias_conflict.rb`.
- **Custom-codec failures that aren't `ArgumentError` are branded correctly** in both directions, and `-0.0`, `1e308`, bignum `BigInt`, `JSON` pass-through and the unquoted-`ID` hint all behave as documented.
