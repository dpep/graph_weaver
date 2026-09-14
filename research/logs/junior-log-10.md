# Junior dev log — graph_weaver exploration

## 2026-09-12 19:30
Starting task. Never used graph_weaver before. Used GraphQL a little from JS, never from Ruby.
Plan: read README.md at gem root, follow links into docs/, then build a Rails app that uses it.
Told docs/errors.md, docs/transports.md, docs/testing.md are relevant.

## 2026-09-12 19:32
Read README.md. Key takeaways:
- Generates typed: strict Ruby from .graphql query files, checked against schema.
- rake graph_weaver:generate is the codegen command; rails g graph_weaver:install for Rails setup.
- Testing: graphql: :fake, :in_process, :router, :wire tags mentioned. Failure simulation and cassettes in docs/testing.md.
- Also in box: Retry with backoff/jitter (transports), structured errors (errors.md).
- Links to follow: getting_started.md, generated_modules.md, testing.md, federation.md, transports.md, errors.md, i18n.md, scalars.md, cassettes.md, editors.md, real_world.md, logging.md, upgrading.md, alternatives.md.
Plan: read getting_started.md first (production Rails setup), then generated_modules.md, then the 3 assigned docs (errors, transports, testing).

## 2026-09-12 19:36
Read docs/getting_started.md in full. Key notes for my task:
- `rails g graph_weaver:install MyApp::Schema` for in-process own-schema setup.
- Must set `GraphWeaver.client = GraphWeaver.new(MyApp::Schema)` inside `Rails.application.config.to_prepare` block (autoloading timing).
- Query files go in app/graphql/queries/*.graphql, generated code in app/graphql/generated/.
- `rake graph_weaver:generate` does codegen. `rake graph_weaver:verify` checks freshness.
- Mutations not mentioned explicitly here — need generated_modules.md for mutation variable/input struct handling.
- Testing tags mentioned: graphql: :fake, :in_process, :router, :wire — details in testing.md.
- No mention yet of controller failure handling pattern — expect that in errors.md.
Next: read docs/generated_modules.md (mutations, naming) then errors.md, transports.md, testing.md (the 3 assigned).

## 2026-09-12 19:42
Read docs/generated_modules.md (used grep to jump to mutation section, then read the naming/variables section in full — file is 33KB, didn't read every section, focused on Naming and Variables/Input objects).
Key facts:
- mutation file `place_order.graphql` -> `PlaceOrderMutation` in `place_order_mutation.rb`.
- `AdoptMutation.execute!(input: {...})` — input objects take a hash or generated T::Struct.
- `execute!` raises on error (bang version); `execute` returns a Response envelope presumably (need errors.md for this).
- InputError raised for bad coercion of a variable (client-side validation, not what I need for GraphQL-level errors).
- Didn't read the whole doc (33KB) — skipped "Fragments", "Unions/interfaces", "Dynamic mode", "abstract types" etc since not obviously relevant to failure/testing task. Will come back if needed.
Next: docs/errors.md (assigned, most relevant to failure cases 1-3).

## 2026-09-12 19:50
Read docs/errors.md in full (assigned doc). Big one. Key facts for my failure cases:
- execute vs execute!: execute returns Response envelope (data, errors, extensions); execute! raises QueryError on top-level errors, returns Result on success.
- Error hierarchy: TransportError (no response - DNS/timeout/etc), ServerError (non-2xx, #status/#body/#retry_after/#throttled?), QueryError (200 body w/ top-level errors, #errors/#data/#extensions/#codes/#throttled?), CastError, InputError, QueryValidationError.
- userErrors (Shopify style) are NOT errors here -- "Business/validation failures returned as data ... aren't errors here — they're just fields you selected" -> deserialize onto response.data normally. This matches my case 1 (out-of-stock via userErrors).
- Case 2 (bad quantity via validates:) -- graphql-ruby validates: rule failure comes back as an EXECUTION error: response.data present with field NULLED, path is response path (e.g. ["placeOrder"]), NO extensions key at all. "A validates: failure is not claimed" -- input_errors is empty for this! So my expectation that #input_errors would catch this is wrong -- must render response.errors directly. IMPORTANT / non-obvious finding.
- Case 3 (errors alongside partial data) -- this is exactly QueryError's territory: response.data present, response.errors present too. success? is false but data still there.
- Retry policy default mentioned in errors.md preview: "Retry wraps any client and already defaults to exactly the policy above: transport failures always, ServerError on 5xx plus 408/429, and GraphQL error codes you name." -- need transports.md for exact mutation-retry wording and idempotencyKey claims (task says docs say something SPECIFIC about mutations+retries).
- #throttled? unifies 429 status and THROTTLED-style GraphQL error codes.
- Nothing in errors.md yet about idempotencyKey or mutation-specific retry caveats -- expect that in transports.md.
Next: docs/transports.md (assigned doc, critical for cases 4/5/6).

## 2026-09-12 19:58
Read docs/transports.md in full (assigned doc). CRITICAL section for case 4 (mutations + retries):
Verbatim: "A mutation gets one attempt. A failure with no answer — a read timeout, a 502, a reset socket — does not say whether the server applied it, and a second `charge` is worse than a failed one. `retry_mutations: true` opts an idempotent API back in; the skipped retry says so on the logger."
So: by default mutations are NEVER retried on transport-level failures (retries: N only applies to queries unless retry_mutations: true). idempotencyKey is NOT mentioned anywhere in transports.md -- the gem does nothing with it. It's purely a field I (the app author) put in my schema/input and would have to dedupe server-side myself. The doc's "idempotent API" language matches the task's hint: "the gem may not enforce idempotency itself."
Other notes:
- Client resolution order: execute(client:) > module client= > test mode stand-in (graphql: tag) > baked constant > GraphWeaver.client=.
- Retry defaults: transport failures always retry (for non-mutations, or with retry_mutations:true); ServerError on 5xx + 408/429; retry_codes: for GraphQL-level throttle codes.
- Retry-After header from server wins over backoff, clamped to max_delay.
- ServerError has #throttled?, #retry_after, #headers.
- In-process client: "a resolver raise becomes a ServerError, status 500, with the original as #cause" -- relevant for case 3! Wait, case 3 is resolver raising AFTER creating an order, need to think about how graphql-ruby actually surfaces that. Actually re-check: that quote is about the IN-PROCESS TRANSPORT WRAPPER re-raising if the whole schema.execute() call raises (not caught by graphql-ruby's own rescue_from). But graphql-ruby normally catches resolver errors and turns them into top-level `errors` in the response (which is what I want for case 3 -- a QueryError, not a ServerError). Need to be careful in my mutation resolver: to produce case 3 I should let graphql-ruby's normal error handling turn a raised StandardError into a top-level GraphQL error (which requires NOT rescuing it away). By default graphql-ruby schema.execute rescues application errors and adds them to top-level errors unless it's totally unhandled by graphql-ruby engine itself (only re-raises for certain internal issues). Will need to verify in practice.
Next: docs/testing.md (assigned, critical for the RSpec harness -- :fake/:in_process/:wire tags, failure simulation, cassettes).

## 2026-09-12 20:05
Read docs/testing.md in full (assigned doc, 553 lines). Key facts:
- One require: `require "graph_weaver/rspec"`. Tag: `graphql: :fake | :in_process | :router | :wire | :live` (untagged defaults to :live).
- `graphql_in_process(Schema)` — helper, no tag needed, installs real-resolver client for a schema, restored after example.
- `graphql_context(...)` sets per-request context seen by resolvers; refused under :fake.
- Failure simulation (GraphWeaver::Testing::Failure) — module with .transport, .server(status:, headers:), .throttled, .stale_schema, .graphql("boom"), and GraphWeaver::Testing::Sequence.new(...) for testing retries (clients run in sequence, last one repeats). These plug in via `client:` kwarg on execute or GraphWeaver.client= — works for :fake/:in_process modes and generic execute calls, NOT specific to :wire.
- CRITICAL for the wire-mode spec: `:wire` tag decides what's behind each endpoint per graph using the SAME derivation as the other tags (router > in-process schema > fake) — no documented option to substitute a Failure client behind a `:wire`-tag-managed endpoint. There is NO documented `graphql_wire(fail: ...)` helper or similar. This looks like a real gap for my task (need to inject a 503 into the wire-mode server).
- However: `GraphWeaver::Testing::Endpoint` is described as "an ordinary Rack app wrapping anything that satisfies the client contract" and the docs explicitly show mounting it yourself: `run GraphWeaver::Testing::Endpoint.new(router)`. Since `Failure.server(status: 503)` is itself a valid "client", in principle `GraphWeaver::Testing::Endpoint.new(Failure.server(status: 503))` should also be a legal Rack app. PLAN: don't rely on the :wire tag's automatic derivation (it has no hook for failure injection); instead manually wrap Testing::Endpoint.new(Failure.server(status: 503)) via webmock's to_rack, point a real GraphWeaver::Client (Transport::HTTP, retries: N) at the stubbed URL, and assert retry attempts happen (or don't, for a mutation) against the REAL transport/retry code. This uses the gem's own test server building block but not the `:wire` tag macro itself. Will note this explicitly as a partial gap in the report — the docs don't show a first-class "make :wire's endpoint fail" story.
- Also noted: GraphWeaver::Testing::FakeClient.new(schema:, fail_at: {path:, code:}) for field-level partial failure with null propagation — could be relevant, but for case 3 I'm using :in_process with a raising resolver (real resolver code), which is more faithful to "resolver raises after creating the order" as instructed.
- `:wire` needs `webmock` (require "webmock/rspec") AND `rack` gems.
Done reading all 3 assigned docs. Not reading errors.md/i18n.md/scalars.md/cassettes.md/federation.md further — not directly needed for this task's 6 cases + wire spec, per task scope. Will peek at more docs only if I get stuck.
Next: set up the Rails app.

## 2026-09-12 20:08
rvm-wrapped ruby 3.4.9 works. bundler 4.0.10 default-ish, rails gem 8.1.3.1 available globally. No friction here (rails gem already installed globally, didn't need `gem install rails`).
Deleted stale /tmp/claude/graph_weaver/junior-app-10 (didn't exist yet, no-op).
Running `rails new` with --api, skipping test framework (will add rspec myself).

## 2026-09-12 20:15
`bundle install` succeeded first try, no friction (112 gems). Now running the generator per getting_started.md: `rails g graph_weaver:install Shop::Schema` since I'm doing in-process own-schema. Need to define Shop::Schema first? Docs example shows running install BEFORE the schema class exists (MyApp::Schema) -- generator just writes initializer referencing it. Will run generator first, then write the actual schema.

## 2026-09-12 20:17
SURPRISE / friction: `rails g graph_weaver:install Shop::Schema` failed immediately:
  "uninitialized constant Shop::Schema — pass your graphql-ruby schema class (rails g graphql:install writes app/graphql/<app>_schema.rb), an endpoint url, or a path to a schema dump"
The getting_started.md doc's "in-process" section shows the exact same command (`rails g graph_weaver:install MyApp::Schema`) without calling out that the schema class must ALREADY be defined and loadable before running the generator. Doc implies "an app that serves GraphQL" already has the class, which is true for me eventually, but nothing said "write your schema first, THEN run this". Minor gap — makes sense in hindsight but cost me a failed command.
Guess: I need to build the Shop::Schema graphql-ruby class by hand first (schema, types, mutation), then re-run the generator. Doing that now.

## 2026-09-12 20:35
Built Shop::Schema by hand (graphql-ruby, no ActiveRecord): Shop::Types::{BaseObject,BaseInputObject,QueryType,UserErrorType,OrderType,PlaceOrderInput,MutationType}, Shop::Mutations::PlaceOrder, Shop::Store (in-memory order array), Shop::Schema.
Design choices:
- Out-of-stock sku "OUT-OF-STOCK" (stock 0) -> mutation returns userErrors, order: nil, no order created.
- Bad quantity -> `validates: { numericality: { greater_than: 0 } }` on the quantity argument inside PlaceOrderInput -- rejected at GraphQL level, distinct from userErrors.
- "Resolver raises after creating order" -> Order#total field method raises GraphQL::ExecutionError when sku == "RAISE-AFTER-CREATE"; the mutation resolver itself has already appended the order to Shop::Store by the time graphql-ruby resolves the nested `total` field, so this reproduces "errors alongside partial data" (order.id/status intact, order.total nulled, one order actually created) without extra plumbing.
Verified directly against Shop::Schema.execute (bypassing graph_weaver entirely first, to make sure MY schema does what I think before layering the gem on):
- out-of-stock: data.placeOrder = {order: nil, userErrors: [...]}, orders.size == 0. Matches errors.md's claim that userErrors are "just fields you selected" -- no top-level `errors` key at all.
- bad quantity: {"errors" => [{"message"=>"quantity must be greater than 0", "path"=>["placeOrder"]}], "data" => {"placeOrder" => nil}} -- NO extensions key, matches errors.md's validates: table exactly ("an execution error ... no extensions key at all"). orders.size == 0.
- raise-after-create: {"errors" => [{"message"=>"pricing service unavailable after order was created", "path"=>["placeOrder","order","total"]}], "data" => {"placeOrder" => {"order" => {"id"=>"order-1","total"=>nil,"status"=>"PLACED"}, "userErrors"=>[]}}} -- genuine partial data, orders.size == 1. Confirms the docs' description of validates:-failures vs a deeper partial-nullification are structurally distinguishable, which is exactly what I wanted case 2 vs case 3 to demonstrate.
No friction here -- graphql-ruby behaved exactly as I expected from having used GraphQL from JS before.
Next: wire up graph_weaver -- run `rails g graph_weaver:install Shop::Schema` now that the class exists and loads.

## 2026-09-12 20:40
`rails g graph_weaver:install Shop::Schema` succeeded once the schema class existed. Wrote config/initializers/graph_weaver.rb (GraphWeaver.client = GraphWeaver.new(Shop::Schema) inside to_prepare, exactly as docs promised), app/graphql/schema.json (introspection dump), graphql.config.yml, appended AllCops exclude to .rubocop.yml.
Wrote app/graphql/queries/place_order.graphql, ran `rake graph_weaver:generate` -> wrote generated/types/place_order_input.rb, generated/types.rb, generated/place_order_mutation.rb. Inspected place_order_mutation.rb -- matches generated_modules.md's description exactly: PlaceOrderMutation module, Result::PlaceOrder::Order/UserErrors structs, execute/execute!/from_response/from_response!.
No friction here -- codegen "just worked" first try given a valid query file.
Next: smoke-test PlaceOrderMutation.execute!/execute against the live Shop::Schema via `rails runner` before writing the controller/specs.

## 2026-09-12 20:44
First real error hit, verbatim:
```
/Users/dpepper/code/lib/ruby/graph_weaver/lib/graph_weaver/hints.rb:45:in 'GraphWeaver::Hints.validate_keys!': unknown key(s) for GraphQLTypes::PlaceOrderInput: idempotencyKey (did you mean 'idempotency_key'?) (GraphWeaver::InputError)
```
Cause: I passed `input: { sku:, quantity:, idempotencyKey: }` (camelCase, matching the GraphQL wire field name) as a plain hash to `PlaceOrderMutation.execute`. generated_modules.md DID say this ("`.coerce` normalizes underscored Symbol/String keys") but I skimmed past it and reflexively used camelCase since that's the wire/GraphQL convention I'm used to from JS. My mistake, not a doc gap — the error message itself is excellent though: it names the bad key AND suggests the fix ("did you mean 'idempotency_key'?"), so I immediately knew what to change without re-reading docs. This is exactly the InputError described in errors.md.
Fixing my rails runner smoke test to use idempotency_key (snake_case).

## 2026-09-12 20:50
Confirmed via rails runner (not specs yet -- allowed per Prefer TDD guidance I'll switch to specs shortly, this was just exploration to understand the gem's actual behavior before committing to a controller design, per the task's own encouragement to explore):
- Case 1 (userErrors): PlaceOrderMutation.execute! returns Result normally (no raise) with place_order.user_errors populated. orders created: 0.
- Case 2 (bad quantity via validates:): execute! raises GraphWeaver::QueryError. e.input_errors == [] (confirms errors.md: "A validates: failure is not claimed"). e.message: "GraphQL query failed: quantity must be greater than 0 at 2:3 (path: placeOrder)". orders: 0.
- Case 3 (raise after create): execute! ALSO raises GraphWeaver::QueryError (not something gentler) even though data is partially present -- but the raised QueryError itself carries e.data with the partial struct (order.id/status intact, total nil), so partial data is NOT lost, just requires a rescue to reach it. orders created: 1. This means my controller needs to rescue QueryError and check e.data to distinguish "totally rejected" (case 2, e.data.place_order nil) from "partially succeeded" (case 3, e.data.place_order.order present).
Design for controller:
- rescue GraphWeaver::QueryError => e: check e.data&.place_order&.order to tell "partial success, needs support followup" from "flatly rejected".
- rescue GraphWeaver::ServerError => e: check e.throttled? for 429/503+Retry-After vs generic 5xx.
- rescue GraphWeaver::TransportError => e: network/timeout message.
- userErrors handled on the happy path of execute! (no exception).
Writing controller + routes now.

## 2026-09-12 21:05
Wrote spec/requests/orders_controller_graphql_failures_spec.rb (cases 1-3) using `graphql: :in_process` at describe level. All 3 green first try (after fixing a Rails 8 deprecation: `:unprocessable_entity` -> `:unprocessable_content`, unrelated to graph_weaver, just Rack's own renaming -- noticed via a `warning:` in test output, not an error).
Writing controller + specs for cases 4-6 next (transport failures) using GraphWeaver::Testing::Failure. These need the example UNTAGGED (default :live) so my `GraphWeaver.client = Failure...` assignment actually takes effect -- if tagged :in_process/:fake, testing.md says "the tag wins" and overrides a plain assignment. This is a real "gotcha you could trip on" -- had I copy-pasted the :in_process tag onto these specs out of habit, `GraphWeaver.client = Failure.transport` would have silently been ignored and the example would hit my real resolver instead of the simulated failure. Caught it from re-reading testing.md's "Both at once and the tag wins" section, not by trial and error.

## 2026-09-12 21:10
spec/requests/orders_controller_transport_failures_spec.rb (cases 5 + 6) all green first try: Failure.server(status: 502) -> bad_gateway; Failure.server(status: 429, headers: {"retry-after"=>"2"}) -> e.throttled? true -> service_unavailable w/ throttled message; Failure.transport -> service_unavailable w/ "Couldn't reach" message. All 0 orders created (makes sense -- these fakes never touch my resolver/store at all).
Now writing the more involved case 4 spec: does a mutation actually get retried by default, and what happens with retry_mutations: true. Need a client that ACTUALLY runs the real in-process resolver (so an order really gets created) but then raises TransportError as if the response never arrived -- simulating "the request succeeded server-side but I never heard back". This isn't a documented Failure helper (Failure.transport never touches real resolvers) so I'm writing my own small test double for this, wrapping GraphWeaver::InProcess.new(Shop::Schema). Docs don't give a canned way to do "run resolver for real, then still fail" -- had to build it myself. This is different from GraphWeaver::Testing::Sequence, which chains whole canned/real CLIENTS but each one is all-or-nothing (either fully fails or fully succeeds), not "succeeds but then the failure happens anyway".

## 2026-09-12 21:20
spec/requests/orders_controller_retry_spec.rb: all 3 examples GREEN FIRST TRY. This directly confirms transports.md's claim in practice:
- Default (no retry_mutations:): FlakyOnceClient.calls == 1 (no second attempt), Shop::Store.orders.size == 1 -- the mutation genuinely succeeded on the wire's far side but the caller never found out, and got a 503 anyway. The order silently exists despite the user seeing "couldn't reach the order service" -- this is a real UX gap worth flagging (my controller has no way to know the order WAS placed in this scenario, since all it has is a raised TransportError with no data).
- retry_mutations: true: FlakyOnceClient.calls == 2, Shop::Store.orders.size == 2 -- literally created two orders for one user click, exactly the "second `charge` is worse than a failed one" risk the docs warn about, reproduced with a real (non-fake) resolver run twice.
- idempotencyKey: confirmed by inspection that the SAME key was sent both times and nothing in graph_weaver or my resolver deduped on it -- it bought nothing on its own, as the task hinted. Dedup is entirely on the app/server side to implement, and I did NOT implement it (per instructions, exploring what the gem claims vs. doesn't).
This was the single most important/informative exploration in the whole exercise -- it's the one place the docs' claim and reality lined up exactly, and it surfaced a real design gap (retry_mutations: true silently doubles orders; the gem provides the on/off switch and nothing else -- no dedup logic, no idempotency-key awareness at all).
Next: docs/errors.md described case 6 (timeout) as folded into TransportError with no separate Failure.timeout helper -- already covered. Now writing the :wire mode spec, the hardest part (task explicitly says to investigate whether the endpoint can be made to fail).

## 2026-09-12 21:30
Got stuck on the wire-mode spec. What I was trying: tag an example `graphql: :wire`, then set `GraphWeaver.client = GraphWeaver.new(url)` so the tag has an endpoint to serve Shop::Schema behind. Tried both inline-in-`it` and in a `before` block; both hit the same error VERBATIM:
```
GraphWeaver::Error: graphql: :wire runs your own transport against your resolvers, so it needs the endpoint that transport posts to — and GraphWeaver.client is GraphWeaver::Client, which posts to none. There is nothing to serve. Point the client at a url (GraphWeaver.new("https://api.example.com/graphql")), or tag the example graphql: :in_process or graphql: :router — they run above the wire.
```
Root cause (worked out from RSpec hook-ordering, not from docs -- docs/testing.md never mentions hook timing for this): graph_weaver's own `graphql: :wire` setup runs as a `before(:each)` hook registered globally (via `require "graph_weaver/rspec"`), which always fires before a `before` block written inside my own `describe`/`it` (RSpec runs outer/global before-hooks before inner ones, and mine is inner). So by the time the gem checks "does this graph have a URL to serve", my app's REAL default client (the in-process one from config/initializers/graph_weaver.rb, correct and intentional for cases 1-3) is still what's active -- an in-process client has no URL, so :wire has nothing to stub.
At this point I grepped lib/graph_weaver/rspec.rb (ONE line: `grep -n "graphql_wire\|def wire\|TAG = "`) to check whether an undocumented `graphql_wire` helper exists analogous to `graphql_fake`/`graphql_in_process`/`graphql_router` -- testing.md's :wire section never shows a bare helper call, only the tag, so I wanted to rule out that I'd simply missed one. Confirmed: no `graphql_wire` method exists, only an internal `wire?` predicate. So there genuinely is no documented (or even undocumented) helper to install a URL client early enough / to inject a failing response under this tag. This is the one and only line of gem source I read in this whole exercise.
Trying `prepend_before` next (an RSpec mechanism, not a graph_weaver one) to see if I can beat the gem's own hook to the punch.

## 2026-09-12 21:45
Wire mode: SOLVED, all 3 examples green.
1. `graphql: :wire`'s own hook runs as a global before(:each) fired at "let's find out what this graph's client resolves to" time, which is EARLIER than any `before` block written in the spec file itself (RSpec: outer/global hooks run before inner/group hooks). A plain `before { GraphWeaver.client = GraphWeaver.new(url) }` was too late -- the tag still saw my app's real in-process default and raised (see error logged above). Fix: `prepend_before` (an RSpec mechanism, not documented by graph_weaver at all) to jump the assignment ahead of the tag's own hook.
2. Even with the URL client in place early enough, :wire STILL served fabricated data ("status-2") instead of my real Shop::Schema resolvers -- the "else the loaded class that defines everything the schema declares" derivation (testing.md) didn't find Shop::Schema on its own (tried forcing autoload by referencing `Shop::Schema` first -- did NOT help). Fix: explicit `GraphWeaver::Testing.configure { |c| c.schema = Shop::Schema }` in spec/rails_helper.rb (in the same file as the `require "graph_weaver/rspec"`, per testing.md's own instruction on where suite-wide Testing config belongs) -- once that's set, :wire correctly serves my real schema/resolvers.
3. For the REQUIRED "inject a 503 into wire mode's own server" part: confirmed there is NO documented (or, per my one lib/ grep, undocumented) way to make `graphql: :wire`'s own auto-derived endpoint fail -- it always serves whatever the graph "is" (router > live schema > fake), all success-shaped, with no `graphql_wire(fail: ...)` analogous to graphql_fake's/graphql_router's fail-injection options. WORKAROUND: `GraphWeaver::Testing::Endpoint` is documented as "an ordinary Rack app wrapping anything that satisfies the client contract" (testing.md literally shows `run GraphWeaver::Testing::Endpoint.new(router)`), and `GraphWeaver::Testing::Failure.server(status: 503)` IS such a client -- so `GraphWeaver::Testing::Endpoint.new(Failure.server(status: 503))` is a valid Rack app. Stubbed it in myself with plain WebMock (`stub_request(:post, url).to_rack(failing_endpoint)`, the exact mechanism testing.md says :wire itself uses under the hood), registered AFTER the tag's own stub for the same URL so mine wins. This is genuinely "the gem's own local test server" (Testing::Endpoint) with an injected 503, exercising the REAL Transport::HTTP + Retry code end-to-end over a real (webmock-intercepted) socket -- just assembled by hand rather than through a first-class `:wire` failure-injection feature, because none exists.
Verified with real request counts: default (`retries: 2`, no retry_mutations:) -> exactly 1 request (no retry for the mutation), raises ServerError. `retry_mutations: true` -> exactly 3 requests (1 + 2 retries), still eventually raises ServerError once retries exhaust (Failure.server always returns 503, so exhausting retries re-raises the last error, per transports.md). This matches transports.md's retry-policy description exactly, now demonstrated over a genuinely served HTTP response rather than a canned client swap.
Running the full suite next.

## 2026-09-12 21:50
Full suite green: 12 examples, 0 failures, on default order plus --order rand:1 and rand:2. No order-dependent flakiness observed (Shop::Store.reset! before every example via a global config.before, plus GraphWeaver's own client snapshot/restore, seem to fully isolate examples from each other).
Running `rake graph_weaver:verify` as a final sanity check (generated code still matches schema+queries).

## 2026-09-12 21:55
Final targeted doc searches (rg over docs/) for the report's "search terms that found nothing" section:
- `rg -i "failure\.timeout|def timeout" docs/` -> NOTHING. Confirms no dedicated timeout-simulation helper is documented; timeouts are just one more thing folded into `Failure.transport`/TransportError.
- `rg -i "graphql_wire" docs/` -> NOTHING. Confirms no bare helper (analogous to graphql_fake/graphql_in_process/graphql_router) exists for :wire.
- `rg -i "double.?charge|double.?order|duplicate order" docs/` -> NOTHING (transports.md uses "charge" once, in the sentence I already quoted, as a generic example, not "double charge" as a phrase).
- `rg -i "dedup" docs/` -> NOTHING. The gem's docs never use the word "dedup" or describe any deduplication behavior anywhere — confirms idempotencyKey is purely an app-level/server-level concern the gem is silent on.
- `rg -i "idempoten" docs/` -> 3 hits, ALL about the `retry_mutations:` transport option describing what kind of API you need before flipping it on (upgrading.md, transports.md x2) — never about an `idempotencyKey` GraphQL field or the gem reading/using one. Confirms: the gem's only "idempotency" concept is the retry_mutations: boolean; it has zero opinion about idempotency keys in your schema.

## 2026-09-12 22:00
All specs green (12/12, 3 seeds), `rake graph_weaver:verify` clean, `srb tc` not run (this is a plain-Ruby app, no Sorbet in the Gemfile — the task didn't ask me to add Sorbet to the consuming app, and the gem's docs are explicit that Sorbet is optional for consumers: "Everything works without Sorbet"). Writing final report now.

## 2026-09-12 22:05
Final run: 12 examples, 0 failures (documentation format captured for the report). Task complete. Writing final report now.
