# Senior R log — checkout engineer (mutations, write path)

Main sha at start: 00038e5 (one commit ahead of b89f8a6, "Brand the union-dispatch
refusal and name its file"). App dir: /tmp/claude/graph_weaver/senior-app-R.
Toolchain: ~/.rvm/wrappers/ruby-3.4.9/bundle exec (no `source rvm` needed with
the wrapper).

## Plan
Build an in-process graphql-ruby schema with a checkout write path: placeOrder
(input object, line items, Money scalar, idempotency key), payment (partial
failure: userErrors + top-level error variant), a union payload mutation
(OrderPayload|ValidationErrors), a mutation with a nested side effect, and an
Upload-arg mutation (known refused, drive for the message). Then hammer
exactly-once (Retry semantics), ambiguity (data+errors, data:null+errors,
transport failure after commit), input-side (InputError path/coordinate,
@oneOf, T::Struct/Hash/kwargs variable spellings, BigDecimal serialize
precision, input struct to_h round trip), test harness for writes (:fake,
cassette replay, Failure.graphql, Sequence), and the log line/APM payload for
a mutation (mutation-ness, operation name, card number redaction).

Skimmed nearest briefs: D (scalars 2nd angle), E (input validation 2nd angle),
M (scalar-heavy migration), N (security). None drove Retry/mutation
exactly-once specifically. followups-post-070.md has no open mutation/retry
items. Proceeding without duplicate risk.

## Timeline

**T+0 to T+40min — setup.** Built senior-app-R (plain Ruby, no Rails — lighter
than the Rails template other seniors used, since nothing here is
Rails-specific): Gemfile pointing `graph_weaver` at the checkout via `path:`,
an in-process graphql-ruby schema (`lib/schema.rb`) with `placeOrder` (input
object, `Money` scalar via BigDecimal, idempotency key), `chargePayment`
(userErrors payload + a `raise-top-level` branch for the other partial-failure
shape), `submitPayment` (union `PaymentResult = PlaceOrderPayload |
ValidationErrors`, and a `@oneOf` `PaymentMethodInput`), `cancelOrder` (nested
side effect: cancelling a PAID order triggers an internal "refund" counter),
and `attachReceipt` (an `Upload!` arg). `Store` module holds server-side
counters (`Store::CALLS`, `Store::REFUND_CALLS`, `Store::IDEMPOTENCY`) so
"exactly-once" can be checked at the resolver, not just at the client.
`bin/generate` (my `generate.rb`) ran clean on the first try — every mutation
shape (input object, `@oneOf`, union payload, Upload scalar) generated without
incident. Read `lib/graph_weaver/retry.rb` and `lib/graph_weaver/transport.rb`
in full to understand the retry/mutation-detection and envelope machinery
before probing it — 15 min, necessary since the brief is entirely about this
seam's exact behavior, not just its public promise.

**T+40 to T+70min — exactly-once.** Built `lib/raw_server.rb`, a real
`TCPServer` harness (adapted the pattern from `/tmp/claude/graph_weaver/transport-probe.rb`,
a prior lane's harness, for full control over socket-level behavior) so
retries are checked against a **real socket** and a **real server-side
counter**, not a fake. `probe_exactly_once.rb`:

- Pure transport failure (socket reset, no bytes back) on a mutation: **not
  retried**, confirmed server-side (`Store::CALLS["placeOrder"] `via
  `server.request_count` == 1). Same failure on a query: retried to the full
  budget (4 requests for `retries: 3`). Matches docs exactly.
- 503 with a GraphQL errors body: this does **not** raise `ServerError` — it
  raises `GraphWeaver::QueryError` (`transport.rb`'s `Envelope` class: a non-2xx
  with a GraphQL `errors` array is deliberately NOT raised as `ServerError`,
  so `Retry` can decide, and `execute!`'s `data!` raises `QueryError` from the
  returned envelope). `retry_mutations: false` -> 1 server request.
  `retry_mutations: true` -> 4 server requests, properly retried. **This is
  correct and matches the docs' claim precisely** ("one rule for both shapes a
  failure arrives in").
- Stale keep-alive socket (server answers once, closes its end, client's pool
  still holds the fd): the client detected this cleanly and reconnected before
  the mutation resolver ran — `place_order_resolver_ran: 1`,
  `tcp_requests_server_saw: 2`. No double-execution. This looks like Ruby's
  own net/http stale-connection detection (peek-before-write), underneath
  GraphWeaver entirely — **correct, not a bug**, but worth naming: this
  reconnect is invisible to `GraphWeaver::Retry` (`:retries` stays 0 in the
  APM payload) since it happens inside net/http before `Retry`'s loop ever
  sees a failure.
- Retry-After on a 429: **found a real bug** — see below.

### FINDING (high severity): `Retry-After` is silently discarded on the
"envelope" failure path (5xx/4xx + a GraphQL errors body — the exact shape
docs use as the motivating Apollo-Router example)

Repro: `/tmp/claude/graph_weaver/senior-app-R/probe_retry_after_envelope.rb`.

A 429 with a GraphQL errors body and `Retry-After: 7` produces `Retry`
backoff delays of `[1.0, 2.0]` (plain `base_delay: 1` exponential, no jitter)
— the header is never read. The **identical** status and header, on a plain
429 with a non-GraphQL body (raises `ServerError` instead), produces
`[7.0, 7.0]` — correctly honored.

Root cause (read, not modified):
`lib/graph_weaver/transport.rb`'s `Envelope` class
(`class Envelope < Hash; attr_reader :http_status; def initialize(parsed,
http_status); ...; end; end`) is built from `(parsed, status)` only —
**headers are never passed to it**, even though `headers` is in scope right
where `Envelope.new(parsed, status)` is constructed. `lib/graph_weaver/retry.rb#delay`
only ever reads `failure.retry_after`, and `failure` is only set in the
`rescue *@retry_on => e` branch — the envelope path returns a response
(no exception), so `failure` stays `nil` and `delay` falls through to the
configured backoff.

Docs (`transports.md`) promise: *"That's one rule for both shapes a failure
arrives in: raised as a ServerError, or returned in the envelope..."* — true
for the retry/no-retry decision (confirmed above), **false for the delay**:
only the raised shape honors `Retry-After`.

Why this matters for checkout specifically: Apollo Router's real rate-limit
shape *is* the envelope path (503 + `REQUEST_RATE_LIMITED` body, per
`errors.md`'s own example). A payments engineer configuring `retry_mutations:
true` for an idempotent checkout retry, expecting the documented
`Retry-After`-wins behavior, gets exponential-backoff-against-the-router's-
own-instruction instead — the thing the docs explicitly warn a checkout
should NOT do to a rate limiter that just asked for a specific delay.

Fix shape: thread `headers` into `Envelope.new(parsed, status, headers)`,
give it a `#retry_after` (reusing `GraphWeaver::Internal::Headers` /
`ServerError`'s own parsing), and have `Retry#delay` check the response's
`retry_after` the same way it checks a raised failure's.

**T+70 to T+100min — ambiguity.** `probe_ambiguity.rb`. Set
`GraphWeaver.client = GraphWeaver::InProcess.new(Schema)` for these (no
network needed except the one dedicated commit-then-drop repro).

### FINDING (high severity, docs vs reality): `QueryError#data` does NOT
carry the order when the mutation payload field is `null: false` — which is
the standard Shopify/Relay convention this whole brief assumes

`docs/errors.md` says, unqualified: *"a mutation that created the order and
then failed on the way out still raises, with the data hanging off
`QueryError#data`."* Built `chargePayment(ChargePayload!)` (the field itself
`null: false`, the conventional Shopify shape — a payload wrapper is declared
non-null specifically so `userErrors` is reliably reachable) that creates/
mutates the order, then on a second, distinguishable failure mode (a raised
`GraphQL::ExecutionError`, simulating "gateway timeout after the order row
was touched") errors out instead of returning a `userErrors` value:

- `execute` -> `response.data` is **nil** (`data_present: false`), not
  partial. `response.errors.first.code == "GATEWAY_TIMEOUT"`.
- `execute!` -> raises `QueryError`, and **`e.data` is nil** — the doc's own
  named accessor comes back empty.

Why: GraphQL null-propagation bubbles a non-null field's error to the nearest
*nullable* ancestor, and the root selection set has none above it — so an
error on any `null: false` root mutation field nulls the **entire** `data`,
not just that field. This is graphql-ruby/spec behavior, not something
graph_weaver decided, but the docs' claim is written with no caveat and reads
as a graph_weaver-level guarantee.

Contrast tested (`chargePaymentNullable`, same resolver, field declared
`null: true`): `response.data` **is** present (`{"chargePaymentNullable":
null}`), but the erroring field itself is still null — so the order id is
*still* unreachable from this response either way. The only way nullability
matters is whether *sibling* selections in the same request survive; it can
never resurrect data inside the field that raised.

**The honest general answer the docs should give**: if a mutation resolver
*raises* instead of *returning* a `userErrors`-shaped value, the order id is
never recoverable from that response, full stop, regardless of nullability —
recovery means a separate query (`order(id:)`) or putting the id on the error
`extensions` yourself. `QueryError#data` only carries something when the
schema returns a value (however partial) rather than raising — which is a
schema-authoring discipline the checkout/payments docs never state as a
requirement, and the doc's own worked example (a non-null payload, the
convention this brief and most real Shopify-style checkouts use) contradicts
it.

Repro: `/tmp/claude/graph_weaver/senior-app-R/probe_ambiguity.rb`
(`charge_payment: top-level error...` probes + the `charge_payment_nullable`
contrast at the bottom). Fix shape: either reword `errors.md` to state the
`null: false` caveat explicitly (cheapest, since this is not graph_weaver's
to fix), or add a worked "getting the order back after a raised mutation
error" recipe (requery, or attach the id to `extensions`) next to the
existing `userErrors` guidance.

**Other ambiguity results, all matching docs, no surprises:**
- `Failure.graphql("msg")` (no `data:`) -> `response.data.nil? == true`.
  `Failure.graphql("msg", data: {...})` -> both present, order id readable
  from the partial data. Exactly as `testing.md` describes.
- A raw envelope with literally no `"data"` key (request-level failure, e.g.
  variable coercion) and one with `"data" => nil` (execution-level failure)
  both collapse to `response.data.inspect == "nil"` — `Response#data` doesn't
  distinguish "never executed" from "executed and nulled". Minor: the GraphQL
  spec treats these as meaningfully different signals (the first means your
  *request* was malformed and nothing ran; the second means it ran and
  something failed), and nothing on `Response`/`QueryError` recovers which one
  happened. Low severity — I didn't find a checkout-relevant use for the
  distinction, flagging for completeness only.
- **Transport failure after the server actually committed** (`RawServer`
  runs the mutation for real — `Store::ORDERS.size == 1`,
  `Store::CALLS["placeOrder"] == 1` — then closes the socket before writing a
  single byte): client raises `TransportError` ("EOFError: end of file
  reached"). **No hook, no reconciliation id, nothing** —
  `e.respond_to?(:reconcile)` is false and there is no idempotency-aware
  callback anywhere in the stack. This is **exactly what `transports.md`
  promises** ("a failed response does not mean nothing happened... Reconcile;
  don't assume") — confirmed by a real repro rather than taken on faith. Not a
  gap; the library is honest about a limitation it can't actually close
  (nothing on the client side of a dead socket can know what the server did).
  Worth restating in the report as the single most load-bearing fact a
  payments engineer needs, correctly documented and now verified.

**T+100 to T+125min — input side.** `probe_input_side.rb`.

- **InputError on the third line item's Money** (`"abc"`, `nil`, and a wrong
  Ruby type `[1,2]`, each as `line_items[2].unit_price`): `#path` correctly
  reads `["input", "lineItems", 2, "unitPrice"]` (the list index in the right
  slot), `#coordinate` is `"LineItemInput.unitPrice"`, `#details` is `{type:
  "Money"}` for the parse/type-mismatch kinds, `{}` for `:missing`. Exactly as
  `errors.md` documents — no surprises, and the *third* element specifically
  (not just index 0) confirmed the index isn't hardcoded or off-by-one.
- **`@oneOf` payment method**: both fields set, neither set, and "one field
  set + the other explicit `nil`" (which should be indistinguishable from
  "one field set" per GraphQL's `@oneOf` semantics — confirmed: same
  `:refused`, "got cardToken, walletId" message, i.e. an explicit `nil` counts
  as "supplied" the same as a real value, matching the spec's non-null
  requirement). All three raise `GraphWeaver::InputError` client-side, never
  reaching the server. Correct.
- **Three variable spellings** — a `T::Struct` built directly
  (`GraphQLTypes::PlaceOrderInput.new(...)`), a Hash with symbol keys, and a
  Hash with **string** keys (what a Rails `params` hash looks like after
  `deep_transform_keys(&:underscore)`, per `errors.md`) — all three worked
  identically, same order created. Confirmed as documented.
- **`serialize:` on the BigDecimal `Money`** — three things worth the report:
  1. A Ruby `Float` (`12.5`) is accepted silently for a `Money` field with no
     complaint — `register_scalar("Money", BigDecimal)` has no scalar-level
     guard against the classic "money as float" anti-pattern. It happens to
     round-trip cleanly today because Ruby's modern `BigDecimal(Float)`
     converts via the float's shortest round-tripping decimal string rather
     than its raw binary expansion (verified directly:
     `BigDecimal(0.1 + 0.2).to_s("F") == "0.3"`, not `"0.30000000000000004"`)
     — but that is Ruby's behavior graph_weaver happens to inherit, not a
     guarantee the library states anywhere. A checkout schema that wants to
     *refuse* a Float for Money entirely (forcing callers to spell an exact
     decimal string) has no registration knob for that — `cast:`/`serialize:`
     only shape a value already accepted as one Ruby object; there's no
     "reject this input class" hook. Low severity (nothing broke), but a
     design gap worth naming in the critique.
  2. High-precision decimal strings round-trip exactly:
     `"19.999999999999999999"` in, the identical string back out. Good — no
     precision loss for the case that matters most.
  3. **Trailing-zero precision does NOT survive the round trip**: `unit_price:
     "10.00"` in `PlaceOrderInput.coerce(...).serialize` comes back
     `"unitPrice" => "10.0"` — one zero, not two. This is `BigDecimal#to_s("F")`
     doing exactly what `docs/scalars.md`'s own table says it does
     (`BigDecimal(v)` / `v.to_s("F")`), so it's not a bug, but it is a real
     answer to the brief's "input struct's `to_h` used as a form's params
     round trip" question: **a price a user typed as `$10.00` does not survive
     byte-for-byte through this scalar** — numerically identical, textually
     different. Worth a line in `docs/scalars.md`'s `Money`/`BigDecimal`
     section, since a checkout is exactly the place someone diffs a request
     body or hashes it for a signature and gets bitten by this.
- **The generated input struct genuinely has `#to_h`** (an alias baked in
  alongside `#serialize` — confirmed identical output on `LineItemInput`), so
  "the input struct's `to_h` used as a form's params round trip" works as
  a mechanism; the caveat above is the only wrinkle.

**T+125 to T+155min — test harness for the write path.** `spec/harness_spec.rb`
(full rspec, real `graphql/rspec` tags — `bundle exec rspec spec/harness_spec.rb`
is green, 9 examples).

### FINDING (high severity): `graphql: :fake` fabricates a NON-EMPTY,
random `userErrors` list on an otherwise-successful mutation, by default

Repro: `spec/harness_spec.rb:6` and `:33`. `PlaceOrderPayload { order,
userErrors }` under `:fake` with no pins comes back with **both** a fabricated
`order` (non-nil) **and** a fabricated, non-empty `userErrors` list
(`[{code: "code-5", field: "field-3", message: "message-4"}]` on one run,
different random content next run) — a shape that could never happen for
real (a real success never carries `userErrors`) but that `:fake` produces
routinely, because list fabrication treats `userErrors` as just another
unbounded list (subject to `list_size`, default a random 1..N) with no
domain knowledge that empty is what "no business failure" looks like.

Why this matters specifically for checkout: `userErrors` is the Shopify/Relay
*business*-failure channel — the whole reason to build it is so a happy-path
test can assert `user_errors).to be_empty`. Under `:fake`, that assertion is
flaky (empty on `list_size: 0`, non-empty otherwise) unless the example pins
it explicitly (`graphql_fake("PlaceOrderPayload.userErrors" => [])`, confirmed
working). `docs/testing.md` covers pins and `list_size` at length but never
calls out "a `userErrors`-shaped field will be non-empty by default" as the
one thing worth a single sentence — a payments engineer writing the very
first `:fake` happy-path test for a checkout mutation, the way `testing.md`'s
own examples are written, hits this immediately and either files a false bug
report against their own resolver or (worse) writes a test that doesn't
actually assert on `userErrors` and ships a checkout UI that has never been
tested against an actually-empty error list.

Fix shape: either default a field literally named `userErrors`/matching the
Shopify convention to an empty list (a coordinate-based heuristic, `case
config.list_size.rb` style has one already), or — cheaper and more
honest — a single line in `testing.md`'s list_size section:
"a `[UserError!]!`-shaped list fabricates like any other list; pin it to
`[]` for the happy path."

**Union payload (`PaymentResult = PlaceOrderPayload | ValidationErrors`)
under `:fake`**: picks a member with no pin (varies by seed — saw both
members across runs, not always the first-listed type). A **bare object-type
pin naming the concrete type is refused** with a genuinely good error:
`override key "PaymentResult" names union PaymentResult, and a pin
fabricates a scalar, enum or object: pin the concrete type —
"PlaceOrderPayload", "ValidationErrors"` — but naming the concrete type alone
(`graphql_fake("ValidationErrors" => {...})`) does **not** force the union to
resolve to it (it only shapes values IF that member gets chosen) — you have
to pin the **field**, with `__typename` inside
(`graphql_fake("submitPayment" => {"__typename" => "ValidationErrors", ...})`),
exactly as `testing.md`'s "at a union or interface, name the member with
`__typename`" line says. This is documented correctly; my first attempt
without re-reading closely enough got the genuinely-helpful refusal message
first, which is the right outcome for a wrong-pin call.

**Cassette recording + replaying a mutation** (`spec/harness_spec.rb`, the
"cassette recording + replaying" group): recorded a real `placeOrder` against
a live raw server, replayed it via `GraphWeaver::Testing.cassette` with no
server at all — replay succeeds and returns the exact recorded order id.
Confirmed **`cassettes.md`'s own warning holds**: the cassette file has the
idempotency key (`cassette1`) sitting in plaintext in the variables block —
`cassettes.md` already says this explicitly ("a mutation's input is often the
sensitive part... record with placeholder variables, or don't record that
request"), so this is a correctly-documented risk, not a silent one. The
"is a replayed mutation a lie" question the brief poses: **yes, in a sense
the docs don't spell out** — replaying `placeOrder` with `idempotency_key:
"cassette1"` a year later, against a schema where that key's real order was
long since cancelled/refunded, still returns "success, order created" from
the cassette, because the cassette is a pure request/response cache keyed on
query+variables with **no** awareness that a mutation's real-world
result is time-and-state-dependent in a way a query's usually isn't. Nothing
in `cassettes.md` calls out "a mutation cassette freezes not just a response
but a fictional world where this action always succeeds" — worth a line
next to the existing "record with placeholders" advice. Low-to-medium
severity: it's the same risk any HTTP-cassette library carries (VCR has the
identical property), so this isn't a graph_weaver-specific defect, but it's
squarely the kind of thing this brief asked to surface.

**Confirmed directly: `retry_mutations: true` + an idempotency key "works" —
but does exactly what the docs say and no more.** `probe_idempotency_retry.rb`:
a real schema executes `placeOrder` (creating an order and recording
`idempotency_key -> order_id`), attempt 1's response is dropped
(TransportError), `retry_mutations: true` resends the **identical**
variables (same idempotency key) on attempt 2. Resolver ran twice
(`Store::CALLS["placeOrder"] == 2`), but because *my* schema's resolver
dedupes on the key, exactly one order exists server-side and the client gets
that order back — clean. Then, same scenario against a second schema that
accepts an `idempotencyKey` argument but never checks it (the realistic
mistake — an app adds the argument for logging/tracing and assumes
graph_weaver "handles" it): **two real orders get created.**
`GraphWeaver::Retry` never reads or interprets the key at all — confirmed by
inspection of `retry.rb` (no reference to any input field) and by this
repro. `transports.md`'s "Idempotency is the server's" section is exactly
right and is not oversold anywhere I could find — no finding here beyond
"this is real, and it is exactly as documented, including the failure mode
of forgetting to implement it."

**T+155 to T+175min — the log line and APM payload.** `probe_logging.rb`,
against `GraphWeaver.instrumenter` and `GraphWeaver.logger` directly (no
Rails railtie in this scratch app, so I read the raw `execute.graph_weaver`
payload and the debug wire lines by hand rather than the `LogSubscriber`
one-liner).

### FINDING (medium severity): the `execute.graph_weaver` payload never says
whether the call was a mutation

Payload captured for `PlaceOrderMutation`: `{url: nil, schema: "Schema",
operation: "PlaceOrderMutation", client: GraphWeaver::InProcess, graph: nil,
status: :ok, duration_ms: 14.95}` — no `:mutation` key, matching
`docs/logging.md`'s own payload table (which doesn't list one either). The
only way to tell a mutation from a query in a subscriber is to pattern-match
`:operation` against a naming convention ("ends in Mutation") that
**graph_weaver itself does not enforce or guarantee** — a raw
`client.execute("mutation Pay(...) { ... }", operation_name: "PayWithCard")`
call (which I also drove, simulating a hand-rolled call or a resolver
forwarding to a downstream API) carries an operation name with no
"Mutation" in it at all, and the payload still doesn't say.

Why this matters for a payments/checkout system specifically: an SLO like
"mutation error rate" or "checkout write failure rate" (the natural
alerting split from a reliability standpoint, since a failed *read* and a
failed *write* are very different pages) cannot be computed from the
payload alone — exactly the gap senior S's brief independently asks whether
"an SLO of 5xx-equivalent rate is computable from the payload alone" for
errors in general; this is the mutation-specific instance of the same
question, and the answer is no.

The library already computes this internally —
`GraphWeaver::Internal::Wire.mutation?(query)` is exactly what
`Retry#mutation?` uses to decide whether to cap attempts at 1 — so exposing
it on the payload is a cheap, well-scoped fix: add
`payload[:mutation] = GraphWeaver::Internal::Wire.mutation?(query)`
alongside the existing `payload[:operation]` assignment in
`Transport#execute`/wherever `EXECUTE_EVENT` is instrumented, using
machinery that already exists and is already trusted for a
correctness-critical decision (retry safety).

**Confirmed working, no findings:**
- The card number redaction path: `GraphWeaver.filter_parameters = [:password,
  :token, /card_?number/i]` correctly turned a raw `client.execute` call's
  `cardNumber` variable into `[FILTERED]` in the debug wire log
  (`variables={"cardNumber":"[FILTERED]"}`), and the literal digits
  `4242424242424242` do not appear anywhere in the captured log output.
  Confirmed by direct string search, not by reading the code and trusting it.
- `:operation` reaches the payload/subscriber correctly for both a generated
  module's mutation and a raw hand-written one.
- `require "graph_weaver/log_subscriber"` standalone raises `LoadError:
  cannot load such file -- active_support/log_subscriber` without Rails/
  ActiveSupport loaded first — reproduced, but this is **already tracked**
  (`followups-post-070.md`, "(junior 15)... a one-line require inside makes
  it standalone-safe") — not re-reporting as new, just confirming it's still
  present on current main.

**T+175 to T+195min — the two remaining schema shapes.** `probe_nested_and_upload.rb`.

**`cancelOrder` (the "nested mutation-ish side effect" mutation)**: cancelling
a `PAID` order fires an internal "refund" side effect
(`Store::REFUND_CALLS`), separate from `cancelOrder`'s own counter, and
`cancelOrder` itself carries **no idempotency key at all** (only `placeOrder`
does, in this schema — realistically, most checkout schemas I've seen add
idempotency to the "charge" mutation and stop there). Retried
`cancelOrder` after a dropped response (`retry_mutations: true`, same as
above): 2 real HTTP attempts reached the server, and the refund fired
**exactly once** — but only because my resolver happens to guard on
`order[:status] == "PAID"` before refunding, so attempt 2 (order already
`CANCELLED` from attempt 1) skips it. That guard is *my* schema's discipline,
not anything graph_weaver provides — a `cancelOrder` written to
unconditionally issue a refund on every call would double-refund under the
exact same retry, and nothing in the client stack would notice or warn. Not
a graph_weaver defect (idempotency is explicitly "the server's," per docs),
but a concrete illustration for the design critique: the library's docs and
example (`retry_mutations:`) center on one mutation with one obvious
idempotency key; a real checkout has several write mutations chained
together (`placeOrder` -> `chargePayment` -> `cancelOrder`/refund), and
nothing here helps a team notice that idempotency has to be re-earned on
*each* one independently.

### FINDING (medium severity): `Upload!` is refused over the wire with a
good message, but silently accepted (and forwarded to the resolver) under
`graphql: :in_process`

Repro: `probe_nested_and_upload.rb`, last three probes.

- Real transport, a genuine `File` variable: refused with an exact, good
  message (verbatim): `$file is a File — graph_weaver posts application/json
  and doesn't implement the GraphQL multipart request spec, so a file can't
  ride along; send what the server expects as JSON, or POST the upload with
  your own transport`. Matches `transports.md`'s description precisely.
- The identical call through `GraphWeaver::InProcess.new(Schema)` (no
  `client:` override, no tag): **succeeds**. The raw `File` object (and,
  separately confirmed, a `Pathname`) sails straight through to the resolver
  untouched — no refusal, no warning, nothing. Root cause: the File/IO/
  Pathname check lives in `Transport#perform`'s JSON-encoding path
  (`GraphWeaver::Internal::Wire.check_variables!`), which only a real
  transport ever calls; `InProcess` hands variables straight to
  `Schema.execute` with no such check.

Why this matters: `docs/testing.md` recommends `graphql: :in_process`
specifically for "the point of the test is that your resolver logic works" —
exactly the tag a checkout team would reach for to test an `attachReceipt`-
style mutation's resolver. A test written that way for an `Upload!` argument
will pass locally and in CI under `:in_process`, and then fail — or worse,
silently misbehave — the first time it runs for real (or under `:wire`),
because the one thing that behaves differently between the two modes is
exactly the thing the brief flagged as "known refused." This is a genuine
mode-parity gap, not a security issue (nothing unsafe reaches production;
the real transport still refuses) — but it is a real testing blind spot.

Fix shape: either have `InProcess` run the same
`GraphWeaver::Internal::Wire.check_variables!` refusal before dispatching (a
few-line change, keeps behavior uniform across every client-slot filler), or
document the asymmetry next to `testing.md`'s `:in_process` section so a team
knows an `Upload!` argument needs a `:wire` test to be meaningfully covered.

**`Failure.graphql(code:, extensions:)`** and **`Sequence`** both worked
exactly as documented — `Failure.graphql("card declined", code:
"CARD_DECLINED", ...)` reads back through `response.errors.first.code`;
`Sequence.new(declined_fake, accepted_fake)` correctly hands back the
declined response first, the accepted one second, and repeats the last
(accepted) on a third call — a clean way to hand-write an idempotent
application-level retry test (`spec/harness_spec.rb`'s last `describe`
block). No findings here — this is the part of the harness that is exactly
as advertised.

**Skipped, time-boxed**: full `srb tc` over the generated code (would need
`sorbet/config` + tapioca RBI generation for graphql-ruby/sorbet-runtime,
~15+ min of setup unrelated to the mutation/retry questions this brief is
about, and Sorbet coverage of generated code is already the explicit focus
of other lanes). Codegen itself (`bin/generate`-equivalent) ran clean on
every schema shape (input object, `@oneOf`, union payload, `Upload` scalar)
on the first try with no errors, which is the signal that most matters here.

## Final summary

### Matrix: what I drove x outcome

| Surface | Outcome |
|---|---|
| `placeOrder` (input object, Money/BigDecimal, idempotency key) | generates and runs clean |
| `chargePayment` (userErrors payload + top-level `ExecutionError` branch) | generates and runs clean; see ambiguity findings |
| `submitPayment` (union `PlaceOrderPayload \| ValidationErrors`) | generates and runs clean; `:fake` union-member pinning works via field+`__typename` |
| `cancelOrder` (nested refund side effect) | generates and runs clean; no built-in nudge toward per-mutation idempotency |
| `attachReceipt` (`Upload!`) | generates clean; refused over the wire with a good message; **silently accepted under `:in_process`** (finding) |
| `PaymentMethodInput` (`@oneOf`) | enforced correctly client-side in every combination tried |
| Transport failure on a mutation | **not retried**, confirmed server-side — correct |
| Transport failure on a query | retried to the full budget — correct |
| 503 + GraphQL errors body (Apollo-Router shape) | arrives as `QueryError`, not `ServerError`; `retry_mutations:` correctly governs retry/no-retry — correct |
| ...same shape, `Retry-After` header | **silently ignored**, falls back to configured backoff (finding) |
| ...same shape via a raised `ServerError` (no GraphQL body) | `Retry-After` correctly honored — contrast confirms the bug is envelope-specific |
| Stale pooled keep-alive socket | detected and reconnected cleanly before the resolver ran twice — correct |
| 429 + `Retry-After` on a mutation | not retried without `retry_mutations:`; retried (but see above) with it |
| `retry_mutations: true` + idempotency key, server dedupes | exactly one order — correct |
| `retry_mutations: true` + idempotency key, server does NOT dedupe | two real orders — correct (and exactly the documented risk) |
| Mutation field `null: false`, resolver raises after a real side effect | `response.data`/`QueryError#data` is nil — order id unreachable (finding: contradicts an unqualified doc claim) |
| Same, field `null: true` | `response.data` present, but the erroring field itself is still nil — order id still unreachable either way |
| Transport dies after the server actually committed | `TransportError`, zero reconciliation hook — correct and honestly documented |
| `InputError` on the 3rd line item's Money (bad value / nil / wrong type) | path/coordinate/details all correct, including the list index |
| Input as `T::Struct` / symbol Hash / string Hash | all three work identically |
| BigDecimal Money: Float in, high-precision string in, round trip | Float accepted silently (no guard); high-precision string round-trips exactly; trailing zeros do NOT survive round trip (`"10.00"` -> `"10.0"`) |
| `graphql: :fake` for a mutation payload | fabricates a non-empty `userErrors` AND a non-nil `order` simultaneously by default (finding) |
| Cassette record + replay of a mutation | works; variables (idempotency key) recorded in plaintext, as `cassettes.md` warns; replay has no awareness that a mutation's result is time/state-bound |
| `Failure.graphql(code:, extensions:)` | works exactly as documented |
| `Sequence` (declined -> accepted) | works exactly as documented |
| `execute.graph_weaver` payload for a mutation | no `:mutation` flag (finding); operation name present; card-number variable correctly redacted in the debug wire log |
| `graph_weaver/log_subscriber` standalone require | still raises `LoadError` without Rails — already tracked in `followups-post-070.md`, confirmed still present |

### Ranked findings

1. **HIGH — `Retry-After` silently discarded on the envelope failure path**
   (5xx/4xx + GraphQL errors body — the exact Apollo Router rate-limit shape).
   Repro: `probe_retry_after_envelope.rb`. Root cause identified in
   `lib/graph_weaver/transport.rb`'s `Envelope` class (headers never passed
   in) and `lib/graph_weaver/retry.rb#delay` (only reads a raised failure's
   `retry_after`). Fix: thread headers into `Envelope`, add `#retry_after`,
   check it in `delay`.
2. **HIGH — `QueryError#data`/`response.data` do not carry partial data when
   a `null: false` mutation payload field's resolver raises** — contradicts
   `docs/errors.md`'s unqualified claim, for the schema convention (Shopify/
   Relay non-null payloads) this brief itself assumes. Repro:
   `probe_ambiguity.rb`. Fix: caveat the doc, and/or add a worked "recovering
   the id after a raised mutation error" recipe.
3. **HIGH — `graphql: :fake` fabricates a non-empty `userErrors` by default**
   on an otherwise-fabricated success, making the most natural happy-path
   test for a checkout mutation flaky or silently wrong. Repro:
   `spec/harness_spec.rb`. Fix: a doc line, or a coordinate-aware default of
   `[]` for a userErrors-shaped list.
4. **MEDIUM — the `execute.graph_weaver` payload has no `:mutation` key**,
   so a mutation-specific SLO/alert can't be computed from it alone, despite
   the library already computing this internally for `Retry`. Repro:
   `probe_logging.rb`. Fix: expose `Wire.mutation?(query)` on the payload.
5. **MEDIUM — `Upload!` is silently accepted under `graphql: :in_process`**
   (no refusal, unlike the real transport's good message) — a testing-mode
   blind spot for the one thing `testing.md` doesn't caveat. Repro:
   `probe_nested_and_upload.rb`. Fix: run the same `check_variables!` refusal
   in `InProcess`, or document the gap.
6. **LOW — trailing-zero precision doesn't survive a Money/BigDecimal round
   trip** (`"10.00"` -> `"10.0"`) — numerically identical, textually
   different; worth a line in `docs/scalars.md`. Repro: `probe_input_side.rb`.
7. **LOW/design note — no scalar-level guard against a Ruby `Float` for
   Money** — works today by luck of Ruby's modern `BigDecimal(Float)`
   conversion, not by any graph_weaver guarantee.
8. **LOW/info — `Response#data` doesn't distinguish "no data key" (request
   error) from "data: null" (execution error)** — no checkout-relevant harm
   found, flagged for completeness.
9. **Already tracked, confirmed still present** — `graph_weaver/log_subscriber`
   standalone `LoadError` (`followups-post-070.md`).

Everything else driven — the core exactly-once semantics, `@oneOf`
enforcement, `InputError` precision on nested lists, the three variable
spellings, `Failure`/`Sequence`, cassette mechanics, redaction — matched the
documentation exactly, verified by repro rather than by reading and
trusting.

### Design critique, from the checkout/write-path angle

The retry/mutation model (`retries:` counts attempts after the first, a
mutation gets exactly one unless you opt in, `Retry-After` should win over
backoff, idempotency is explicitly "the server's") is the **right shape** —
it correctly refuses to guess at exactly-once for you, which is the honest
answer a client library can give. The one place that model has a real crack
is structural, not philosophical: the `Envelope` type introduced specifically
to let a router's 503-with-errors-body participate in the same retry
decision as a raised `ServerError` didn't carry the one thing that decision
needs most — the header naming *when* to come back. That's a narrow, well-
understood gap, not a design flaw.

The two other high-severity findings are really the same lesson from two
angles: **this library is exactly as good as the schema it's pointed at, and
nothing here teaches or nudges a schema toward the shapes that make ambiguity
recoverable.** A `null: false` mutation payload (the convention this brief
assumes, and the one most real checkout APIs use) throws away the very
partial data `errors.md` promises you'll get; a `:fake` test with no
`list_size`/pin discipline invents a `userErrors` list on a "successful"
mutation nobody asked for. Both are the kind of trap a payments engineer
would only find by being burned once — which is exactly this brief's job to
prevent by finding it first.

Idempotency itself is where I'd push hardest in a design review: the library
correctly refuses to fake owning it, but it also offers zero structural
help — no convention, no generator flag, no lint — for the realistic shape of
a checkout (`placeOrder` -> `chargePayment` -> maybe `cancelOrder`/refund),
where idempotency has to be independently re-earned on *every* write, not
just the first one everyone remembers to protect. That's arguably out of
scope for a GraphQL client (it's a server concern), but the docs could at
least say so where `retry_mutations:` is introduced, rather than only next to
the one example mutation.

### Time accounting

- Setup (schema, codegen, harness scaffolding): ~40 min
- Exactly-once (`Retry`, raw socket harness, the `Retry-After` bug): ~30 min
- Ambiguity (partial data, `data: null`, commit-then-drop): ~30 min
- Input side (`InputError`, `@oneOf`, spellings, BigDecimal): ~25 min
- Test harness for writes (`:fake`, cassette, `Failure`, `Sequence`): ~30 min
- Logging/APM payload: ~20 min
- Nested side effect + `Upload`: ~20 min
- Read `lib/graph_weaver/retry.rb` and `lib/graph_weaver/transport.rb` in
  full (once, up front) specifically because the brief is about this seam's
  exact mechanics, not its public promise — ~15 min, paid for itself
  immediately (found the `Envelope`/headers gap by reading the source, then
  confirmed with a repro rather than guessing from behavior alone). No other
  `lib/` or `spec/` reads.
- Total: ~3h15m wall time.

### Would I ship on this surface?

Yes, with one pre-condition and one habit. The pre-condition: fix or
work around the `Retry-After` gap before turning on `retry_mutations: true`
against a router that rate-limits via the envelope shape (Apollo Router,
notably) — as shipped today, that combination silently replaces the
server's stated backoff with your own, which is close to the opposite of
what a checkout wants under load. The habit: treat `:fake` and `:in_process`
as complementary, not interchangeable, for every write mutation — pin
`userErrors` explicitly in `:fake` tests (don't trust the default), and add
at least one `:wire` test per `Upload`/file-taking mutation, since
`:in_process` will not catch the one thing that mode is known not to
support. Everything else I drove — the actually-hard exactly-once
questions, the ones a payments engineer loses sleep over — held up exactly
as documented, verified by a real socket and a real server-side counter, not
taken on faith.


