# GraphWeaver senior-engineer evaluation — session U

Evaluator stance: I am the graphql-ruby SERVER author for a team that also
consumes its own API through graph_weaver as a client — every custom scalar
therefore has TWO independent definitions (server `coerce_input`/
`coerce_result`, client `register_scalar` cast/serialize) that have to agree,
and nothing forces them to. Central question: does graph_weaver help keep
them in lockstep, or let them drift silently?

Checkout: /Users/dpepper/code/lib/ruby/graph_weaver, read-only. `git rev-parse
HEAD` = df7043b2 at session start; the brief states main is at 00038e5 (one
commit behind HEAD — "Put an object pin's list and its ID on the wire the way
a server would"). Using the checkout as-is (path: Gemfile), noting the
one-commit drift rather than pinning, since the brief's own common rules just
say "the checkout (main, so the 0.7.1 fixes are in)".

Working dir: /tmp/claude/graph_weaver/senior-app-U, plain Ruby (no Rails —
`:in_process` needs no host lifecycle, and the brief's question is about the
scalar registry, not Rails boot order, which senior-log-G already covered).
Toolchain: `~/.rvm/wrappers/ruby-3.4.9/bundle exec ...`.

Skimmed first (per common brief, "nearest two"): senior-log-S.md, senior-log-R.md
(nearest surviving logs below U — T/Q/P briefs exist but no log was produced
for them). Also skimmed senior-log-G.md in full (scalars across multiple
graphs, srb tc, cassette/fake drift from a *client-only* angle — no real
graphql-ruby server scalar coercion) and grepped A/D/M for CoercionError —
none of A/D/G/M defined an actual `GraphQL::Schema::Scalar` with real
`coerce_input`/`coerce_result`; all exercised register_scalar against either
a schema with default/inherited coercion or a stub. This session's angle
(real server-side coercers on both sides, driven in one process) is not yet
covered. senior-log-E (a different brief, input-errors) already drove the
docs/errors.md `EmailScalar`/`CoercionError` example almost verbatim and found
message redaction only covers GraphWeaver-composed text, not the server's own
raise — noted, not re-derived from scratch, but re-verified since this
brief's CoercionError question is more specific (kind/path/redaction across
execute/execute!/input_errors for a scalar built for real coercion, not a
regex demo).

Pre-read in full: docs/scalars.md (registration doors, the "Writing the
scalar on the server too?" section — nullable coerce_input called with nil,
the CoercionError->`:refused` rule, the `extensions.input` convention),
docs/errors.md (CoercionError round-trip section, EmailScalar example,
redaction scope), docs/testing.md (`:fake` scalar pin rules), docs/cassettes.md
(`cassettes:check` semantics). ~20 min.

### setup

`senior-app-U`: plain Ruby, `schema.rb` (8 real `GraphQL::Schema::Scalar`
subclasses — `Money`, `DateTime`, `Decimal`, `URL`, `Slug`, `Email`, `JSON`,
`Duration` — each with a genuine `coerce_input`/`coerce_result`, not a stub),
`registrations.rb` (client `register_scalar` calls), `money.rb` (a small
value object mirroring what a team would actually reach for). `Rakefile`
wires `graph_weaver/tasks` against `ServerSchema` in-process (`GraphWeaver.new(ServerSchema)`
— no HTTP, no separate JSON encode/decode boundary: confirmed by reading
`lib/graph_weaver/in_process.rb`, whose own comment says "no socket, no
serialization" — `@schema.execute(...)` is called directly and its return
value, including whatever a custom scalar's `coerce_result` returned, is
handed to `from_h` as-is). `bundle exec rake graph_weaver:schema:refresh` /
`verify` / `schema:diff` all clean at baseline; `generate!` wrote 10 files,
0 already-up-to-date on the first run, `(10 already up to date)` on a rerun.
~50 min total for schema + registrations + first green generate, most of it
fighting two real Ruby/graphql-ruby gotchas that turned out not to be
graph_weaver bugs (logged below so the repro is honest about what was mine).

**Two non-graph_weaver dead ends (both < 15 min, logged per common brief):**
1. `class Mutation < GraphQL::Schema::Object` at the top level, referenced as
   bare `Mutation` inside `class ServerSchema < GraphQL::Schema ... mutation
   Mutation ... end`, silently resolved to `GraphQL::Schema::Mutation` (graphql-ruby's
   own base class) instead of my class — `NoMethodError: undefined method
   'kind' for class GraphQL::Schema::Mutation`. Ruby's constant lookup checks
   `Module.nesting` (just `[ServerSchema]` here) and then the ancestors of the
   innermost lexical scope (`ServerSchema.ancestors` includes `GraphQL::Schema`,
   which has a nested `Mutation`) *before* falling back to top-level
   constants — so a schema's own root-mutation class can never be bare-named
   `Mutation` inside its `class Schema < GraphQL::Schema` body. Renamed to
   `MutationType`. Pure Ruby constant-resolution trap, not graph_weaver's.
2. `PriceInput.amount`'s `default_value:` had to be the **application-format**
   Ruby value (`{amount: "0", currency: "USD"}`), not the wire string —
   graphql-ruby's own `Argument#validate_default_value` round-trips a default
   through `coerce_result` then `valid_isolated_input?`, which only works if
   `coerce_result`'s output is itself valid `coerce_input` input. For Money's
   genuinely asymmetric wire shape (object out, string in — the brief's own
   spec) that round trip doesn't hold by default, so `coerce_input` had to
   grow a defensive branch accepting the Hash shape too, purely to let a
   default value validate at boot. Not a graph_weaver issue — a graphql-ruby
   mechanic worth knowing before blaming the gem for a boot-time
   `InvalidDefaultValueError`.

### HIGH — the finding this brief exists for: a server-only `coerce_result`
change is invisible to `verify`, `schema:diff`, and `generate!` alike, and
surfaces at runtime as a silently wrong value, not an exception

Repro: `Decimal.coerce_result` changed from `BigDecimal(v).to_s("F")` (string)
to `BigDecimal(v).to_f` (JSON number) — nothing else touched, scalar name
unchanged (`Decimal`), client registration unchanged
(`register_scalar("Decimal", BigDecimal)`, no `serialize:`/`cast:` override).

```
$ bundle exec rake graph_weaver:verify        # generated queries up to date
$ bundle exec rake graph_weaver:schema:diff   # app/graphql/schema.json matches ServerSchema
$ bundle exec ruby generate.rb                # wrote: (10 already up to date)
```

All three exit clean — because a custom scalar's SDL representation is just
its name (plus, optionally, `specifiedByURL`/description — see below); a
`GraphQL::Schema::Scalar`'s `coerce_input`/`coerce_result` bodies are Ruby
methods `to_definition`/introspection never sees, so nothing in the dump this
gem diffs against can move when only they change. Confirmed by reading
`lib/graph_weaver/schema_diff.rb`, which compares `GraphQL::Schema` **type
objects** (`old.to_type_signature`, `possible_types`, `interfaces`,
`deprecation_reason` — never a scalar's coercers) plus a catch-all
`note_unnamed_drift` that only fires when `to_definition` (the printed SDL)
differs at all, which it doesn't here.

Then the actual query, in-process (`ProductQuery.execute!(id: "1")`,
`weight` is the `Decimal` field, real server value `BigDecimal("3.4")`):

```
weight = 0.34e1 (class BigDecimal)
```

**No exception anywhere.** `BigDecimal(a_float)` (bigdecimal gem 4.1.3,
bundled with Ruby 3.4.9) no longer requires a `precision` argument the way
older Ruby did — it silently accepts the Float and builds a `BigDecimal` from
its (already lossy) binary representation. For `3.4` the loss isn't visually
obvious; isolated the actual damage with a value that shows it:

```ruby
orig = BigDecimal("123456789.123456789")
BigDecimal(orig.to_f).to_s("F")   # => "123456789.1234567"  -- last 2 digits gone, rounded
```

**This is the entire reason `Decimal` (string out, never a JSON number) was
worth having as its own scalar in the first place — to keep exactly this
precision out of a `Float`'s hands — and the regression that defeats it is
invisible at every gate this gem runs, both offline (`verify`) and against
the live schema (`schema:diff`), then silent at runtime too**: no
`GraphWeaver::CastError`, no warning, just a `BigDecimal` holding a number
that is quietly wrong past the 7th-ish significant digit, for every response
until someone notices a total is off in production. Repro is deterministic,
3 lines, no flags. Restored `schema.rb` immediately after confirming
(`schema.rb.orig` kept as the diff).

**What a lockstep check would need that nothing reads today**: neither side
records what the OTHER side's coercion actually does — the client's registry
holds `cast:`/`serialize:` source fragments, the server's schema class holds
`coerce_input`/`coerce_result` methods, and nothing in this gem (or in
graphql-ruby) puts a machine-checkable claim about a scalar's wire SHAPE
(`String`, `"12.50 USD"`-format, a JSON number, an object with these keys)
anywhere both sides could compare it against. The closest lever that
exists and isn't used: `:in_process`/`:router`
[cassette recording](cassettes.md) DOES exercise the real `coerce_result` on
every recorded response, so a cassette re-recorded after this regression
would carry the new (wrong) shape — but `cassettes:check` only asks "does the
already-recorded cassette still cast?", not "did today's live response change
shape from what's recorded" (that's what a **re-record + diff of the
cassette file** would show, not something the tooling does for you). See the
cassette-drift test below for the closest thing this gem has to actually
catching this class of change.

### drift #2 — a plausible-but-wrong client registration ("Money as a bare
decimal") is caught only by actually sending a request, never by generation

A second, independently plausible client registration for the same server
Money (docs/scalars.md's own "single-currency API" pattern, the one every
`Money` example that isn't the object/split-string shape uses):

```ruby
GraphWeaver.register_scalar("Money", Money,
  cast: ->(v) { "Money.from_amount(BigDecimal(#{v}), \"USD\")" },
  serialize: ->(v) { "#{v}.amount.to_s(\"F\")" })
```

Generates cleanly (`drift_generated/echo_price_query.rb` — a second
generated-paths dir, kept alongside the real `generated/` as evidence, both
committed to the app dir). `srb tc`-shaped, looks completely normal. Sending
a real `Money` through it:

```ruby
EchoPriceQuery.execute(price: Money.new(BigDecimal("12.50"), "USD"))
# => errors: ["Variable $price of type Money! was provided invalid value"]
# => input_errors: [{"error"=>"GraphWeaver::InputError",
#      "message"=>"\"12.5\" is not a valid Money — expected \"12.50 USD\"",
#      "kind"=>"refused", "path"=>["price"], "field"=>"price",
#      "value"=>"12.5", "details"=>{}}]
```

Exactly as docs/scalars.md itself predicts ("a scalar's own wording arrives
`:refused`, with that wording") — the server's own message survives
verbatim, `path`/`field` land correctly. **Nothing catches the registration
mistake before this.** `generate!` succeeds (there's no way for codegen to
know the server would reject the string it's about to teach the client to
send); there is no schema-side signal at all, since the schema only says the
type is named `Money` — the wire *format* a `Money` string has to match is
private to the server's `coerce_input` body. The only thing that would have
caught this before a real request is a cassette or `:in_process` test that
actually exercises `EchoPriceQuery` with a real `Money` — i.e., exactly the
coverage docs/testing.md already tells you `:fake` cannot give you for a
scalar registered as your own class (see below).

Severity: this isn't a bug — register_scalar has no way to validate itself
against live server behavior, and the docs don't promise it does — but it's
worth stating plainly for this brief's audience (the team that owns both
sides): **the two `register_scalar` patterns in docs/scalars.md for "an
honest hard case" scalar (object, split-string, bare-decimal) are equally
plausible-looking and only one of them is correct for a given server, and
nothing short of a real request against that server tells you which.**

### CoercionError round trip — Email, across `execute`/`execute!`/`#input_errors`,
and where redaction actually applies

Added `echoEmail(email: Email!): Email!` to the server (real `EmailScalar`,
no `extensions.input` convention — a plain `raise GraphQL::CoercionError,
"..."`, the case docs/scalars.md's own "Writing the scalar on the server too?"
section describes: "a scalar's own wording arrives `:refused`, with that
wording"). Sent `"SECRET-TOKEN not-an-email"`:

```ruby
resp = EchoEmailQuery.execute(email: "SECRET-TOKEN not-an-email")
resp.input_errors.map(&:to_h)
# => [{"error"=>"GraphWeaver::InputError",
#      "message"=>"\"SECRET-TOKEN not-an-email\" is not a valid email address",
#      "kind"=>"refused", "path"=>["email"], "field"=>"email",
#      "value"=>"SECRET-TOKEN not-an-email", "details"=>{}}]
```

`kind: :refused`, `path`/`field` land on the argument, and the server's exact
sentence survives verbatim — confirmed, matches the doc claim precisely.

`execute!` raises `GraphWeaver::QueryError` whose own `#message` is graphql-ruby's
generic top-level sentence ("GraphQL query failed: Variable $email of type
Email! was provided invalid value"), **not** the server's specific wording —
but the specific wording isn't lost: `QueryError#input_errors` (delegates to
`#errors.flat_map(&:input_errors)`) hands back the identical hash shown
above. So a bare `rescue GraphWeaver::Error => e; puts e.message` loses the
detail, but `e.input_errors` doesn't — worth stating plainly since it's easy
to assume the exception's own `#message` is the whole story.

**Redaction — the actual scope boundary, more precise than I expected before
testing.** `lib/graph_weaver/internal/server_input.rb#build` (the path every
convention-shaped AND plain-CoercionError-shaped server rejection goes
through) redacts by **field name**, not by content — `redact.detail(path.last,
message)` replaces the **entire message** (not just the value) once the key
the error points at is in `filter_parameters`:

```ruby
GraphWeaver.filter_parameters = [:email]
resp.input_errors.map(&:to_h)
# => [{"message"=>"[FILTERED]", ..., "value"=>"[FILTERED]", ...}]
```

confirmed both message and value flip to `"[FILTERED]"` together, exactly as
`server_input.rb`'s own comment states ("a server quotes the value it
rejected as a matter of course... so redacting only #value would leave half
the promise kept"). **This is more thorough than a quick read of another
session's finding (senior-log-E, a different brief) might suggest**: E found
that an ordinary **resolver-raised free-text `GraphQL::ExecutionError`**
(a custom validator's own string, not the `extensions.input`/CoercionError
convention) is never redacted at all — that's still true and is a *different
code path* (a bare `#errors[].message`, never passed through
`ServerInput.build`). The precise, worth-stating boundary for this brief's
audience: **redaction is real and thorough for anything shaped as a scalar
`CoercionError` or an `extensions.input`-convention validator error — both
run through `ServerInput.build`, which redacts the whole sentence by field
name — but a resolver's own raw raise never reaches that function at all.**
Two rules, not one, and the difference is which Ruby object raised, not
whether the text "looks sensitive."

One real gap, not a bug: `Email` isn't credential-shaped, so it is not in
`DEFAULT_FILTER_PARAMETERS` (`password`, `token`, `secret`, `authorization`)
— a team shipping this exact scalar and wanting emails out of logs/exceptions
by default has to add `:email` to `GraphWeaver.filter_parameters` themselves;
nothing about registering `Email` as a scalar does it for them, nor should
it (the library can't know a scalar carries PII from its name alone). Worth
one sentence in docs/scalars.md's Email-adjacent material, not a design flaw.

### `@oneOf`, list-of-input `validates:`, and a scalar default value — all
confirm the docs exactly; no findings, but worth having actually driven them
with a real asymmetric scalar in the mix

**`@oneOf` (`DiscountInput { percentOff, amountOff: Money }`)**: generated
`GraphQLTypes::DiscountInput` carries `ONE_OF = true` and both fields
nilable; `#serialize`'s `one_of!` enforces "exactly one, non-null" **client-side**,
before anything reaches the wire — confirmed by reading
`lib/graph_weaver/input_struct.rb#one_of!`, not re-derived at runtime (a
different session already drove both-fields/neither-field live). The
generated coercer/serializer for the `Money`-typed oneOf branch is the exact
asymmetric pair from the top-level registration
(`serializer: ->(v) { "#{v.amount.to_s('F')} #{v.currency}" }`, `coercer` reads
the object) — confirms the split-shape registration threads correctly through
a nested input, not just a bare scalar argument.

**A scalar default value (`PriceInput.amount: Money = "0 USD"`, application-format
per graphql-ruby's own default-value validation)**: the generated struct is
`const :amount, T.nilable(Money), default: nil` — **the client's default is
its own `nil`/omit convention, entirely independent of the server's declared
default**. Confirmed empirically, all three cases:

```ruby
PriceInput.new.serialize                    # => {}  (omitted — schema default applies)
EchoPriceInputQuery.execute(price: PriceInput.new).data.echo_price_input
# => #<Money amount=0.0 currency="USD">      -- the SERVER's default, round-tripped correctly

PriceInput.coerce(amount: nil).serialize     # => {"amount" => nil}  (explicit null)
EchoPriceInputQuery.execute(price: PriceInput.coerce(amount: nil)).errors
# => ["Cannot return null for non-nullable field Query.echoPriceInput"]
```

Exactly as generated_modules.md documents ("absent and `null` are different
things... `coerce` remembers which keys the hash had... a struct built with
`.new` can't tell the two apart"): the client never inlines or duplicates the
server's default value anywhere, it only knows omit-vs-null, and gets that
distinction right — verified rather than trusted, including the one case
that actually matters here (an omitted optional `Money` correctly receiving
and round-tripping the server's own default). **No finding** — this is the
part of "lockstep" this gem gets structurally right by not trying to mirror
the server's default at all, just the omit/null protocol GraphQL itself
defines.

**`validates:` on a scalar field inside `[LineItemInput!]!` (`sku`, a plain
graphql-ruby `format:` validator, no `extensions.input` convention)**:
rejects correctly (`"must be a slug at least 3 characters long"`), but the
raw error carries **no `path`, no `extensions`** at all —
`resp.input_errors` is `[]`, `resp.errors.first.message` is the only signal.
Exactly the documented degrade ("a server that follows none of this
[convention]... does not guess") — confirmed with a real list-of-input, not
re-derived; a different brief (senior-log-E) already drove the
`extensions.input` convention's own per-element-vs-list-argument indexing
behavior in depth, not repeated here. No finding.

### `:fake` from the server author's seat — the pin shape question the docs
answer once but a scalar with two different wire shapes makes ambiguous, plus
the gap the brief asked about directly

`spec/fake_spec.rb`, 5 examples, all green (repros, not failures — a red one
would mean I got the API wrong, not a finding). `EchoPriceQuery` used
throughout (one scalar in play — `Money` — rather than `ProductQuery`'s nine,
so a fabrication refusal on an unrelated unfakeable field doesn't mask the
one under test; hit that mask on the first attempt with `ProductQuery`, fixed
by narrowing the fixture rather than pinning everything, ~10 min lost, under
the 15-min budget).

1. **No pin**: refuses exactly as documented — `"can't fabricate a Money at
   echoPrice: ... Pin the type"`.
2. **Pin in the wrong (but equally natural) shape**: `graphql_fake("Money" =>
   "12.50 USD")` — the string a *client* would send, and a very natural first
   guess for "the wire value," since that's the only shape a human ever types
   for a Money by hand. Fails, but only once `from_h` runs — `GraphWeaver::CastError:
   ... can't convert nil into BigDecimal` — because `cast:` reads the
   *object* shape `coerce_result` actually produces, and `"12.50 USD"["amount"]`
   is Ruby's substring-lookup `String#[]`, which returns `nil` rather than
   raising, so the failure surfaces one call later and one layer removed from
   the real mistake (pinning the wrong direction's shape). docs/testing.md's
   own words — "a fake reads the scalar registrations... and invents the
   wire value that graph's generated **cast** expects" — are accurate, but for
   a scalar whose `cast:`/`serialize:` pair (necessarily, given this brief's
   own asymmetric Money) decode *different* wire shapes, "the wire value" is
   genuinely ambiguous prose: which wire, in or out? senior-log-G (a
   different brief) found the sibling mistake — pinning the *Ruby object* a
   cast produces, rather than any wire value at all — for a symmetric scalar.
   Between the two sessions, an asymmetric scalar's pin has **three** plausible
   wrong guesses (the object a cast returns, the string a serialize
   produces, the deserialized Ruby value itself) and exactly one right one,
   and nothing points at which. Additive fix: docs/testing.md's scalar-pin
   paragraph could say "the shape `cast:` reads, which for a result is
   whatever `coerce_result` produces — not what your `serialize:` would send
   back out" for exactly this (rare but real, given the brief's own spec)
   asymmetric case.
3. **Pinned correctly** (`{"amount" => "12.50", "currency" => "USD"}`):
   fabricates and equality-checks clean.
4. **This is the brief's actual question, answered**: `graphql_fake("Money" =>
   { "amount" => "12.50", "currency" => "usd" })` (lowercase currency) —
   `:fake` accepts it without complaint (`cast:` is `Money.from_amount`,
   which validates nothing about currency casing) and the example's own
   assertion on `result.echo_price.currency` passes. **This is exactly a
   value the real server would reject** — confirmed in the next example,
   `graphql: :in_process`, sending the identical (lowercase-currency) `Money`
   for real: `resp.input_errors.first.message` is `"\"12.5 usd\" is not a
   valid Money — expected \"12.50 USD\""`. **`:fake` gave a green test for
   an input the server 422s on**, precisely because `:fake`'s only contract
   is "shape-correct," never "the real coercer's own extra rules" — exactly
   what docs/testing.md's "the other half `:fake` can't reach" paragraph
   already says in general (about `validates:`/custom validators), just not
   phrased in terms of a scalar's own coercer having rules beyond its Ruby
   type. Not a new gap in the library so much as a sharper, scalar-shaped
   instance of a documented one — worth calling out because a scalar
   `cast:` inferred from `.parse`/`Money.from_amount` is easy to mistake for
   "the real validation," when it's only ever "valid enough to build a Ruby
   object," which is a strictly lower bar than what a real `coerce_input`
   enforces.

### cassette recorded against `:in_process`, server tightens `Email`, replay
— the exact scenario the brief names

`spec/cassette_spec.rb` records `EchoEmailQuery` (`email: "a@example.com"`)
through `GraphWeaver::Testing.cassette("echo_email", client: GraphWeaver::InProcess.new(ServerSchema))`
— a genuine `:in_process` recording, real `coerce_input`/`coerce_result` in
the loop, not a stub. Committed `spec/cassettes/echo_email.yml`.

Then tightened `EmailScalar.coerce_input` (a realistic server change —
company-email-only, `@corp.example.com`) and, **as a control, first refreshed
the schema dump and confirmed `verify`/`schema:diff` both clean** (this
scalar's tightening, like `Decimal`'s above, is invisible to both — same
root cause, a coercer body isn't SDL). Then:

```
$ bundle exec rake graph_weaver:cassettes:check
spec/cassettes/echo_email.yml: 0 stale (1 checked)
every recording still casts
```

**Still clean** — because "still casts" asks only "does the stored response
deserialize into today's generated struct," and the stored response is a
plain string (`"a@example.com"`), which any `String`-registered `Email` casts
into trivially regardless of what the live server would now do with that
value as *input*. Confirmed the live server really does reject it, replaying
the identical value directly against a live `:in_process` client:

```ruby
EchoEmailQuery.execute(email: "a@example.com").input_errors
# => [{"message" => "\"a@example.com\" is not a valid email address", "kind" => "refused", ...}]
```

**What does catch it: re-recording.** `GRAPHWEAVER_RECORD=1 bundle exec
rspec spec/cassette_spec.rb` — the one documented repair step for "the API's
real behavior changed" — re-runs the same request against the real (now
tightened) server and this time the request itself fails:

```
GraphWeaver::QueryError: GraphQL query failed: Variable $email of type
Email! was provided invalid value at 1:17
```

the spec's own assertion (`result.echo_email == "a@example.com"`) never even
gets a chance to run, and the cassette file itself changes shape underneath
it — `response: { data: {...} }` becomes `response: { errors: [...] }` —
which is a real, visible diff a reviewer or CI would see on the recording
file itself. **So the honest answer for this brief's audience**: nothing
*offline* (`verify`, `schema:diff`, `cassettes:check` against the old
recording) catches a server-only coercion tightening; the *only* thing that
does is the explicit re-record step, and it catches it hard (a failing spec
plus a changed cassette), not softly. A team that never re-records — because
CI is green and nobody thought to — carries a cassette that has quietly
stopped being true of the live server, with the suite offering zero signal
of that until the day someone actually re-records or ships against the real
API and a real user's request breaks.

### introspection: `specifiedByURL` and description — reach the dump
differently depending on topology, neither reaches generated code, and
`schema:diff` only ever says "something changed" for either one

**`specifiedByURL`** (`Duration`'s `specified_by_url "https://en.wikipedia.org/..."`)
behaves completely differently depending on how the schema is loaded, and
this session is the one topology (in-process) least likely to catch the gap:

- **In-process** (`schema:diff` compares live `GraphQL::Schema` Ruby objects,
  via `to_definition`/SDL): `ServerSchema.to_definition` includes
  `scalar Duration @specifiedBy(url: "...")` — confirmed by printing it — so
  it round-trips fine here.
- **Introspected** (a URL source, `rake graph_weaver:schema:refresh URL=...`
  — the topology most real teams actually use, since the point of
  introspecting is *not* having the schema class locally): **never reaches
  the dump at all.** Read `lib/graph_weaver/schema_loader.rb:761`:

  ```ruby
  def self.ask(transport)
    result = transport.execute(GraphQL::Introspection.query(include_is_one_of: true), variables: {}).to_h
    ...
  ```

  `GraphQL::Introspection.query` (graphql-ruby's own introspection-query
  builder, `lib/graphql/introspection.rb:4`) takes an
  `include_specified_by_url:` kwarg, **default `false`**, that literally
  splices the `specifiedByURL` field into the query template
  (`lib/graphql/introspection.rb:32`) — and graph_weaver's call site never
  passes it. So `app/graphql/schema.json`'s SCALAR type entries carry
  `description` but never `specifiedByURL`, confirmed directly in the dump
  (`{"kind":"SCALAR","name":"Duration","description":"...", ...}` — no
  `specifiedByURL` key present at all, even though `__Type.specifiedByURL`
  is itself a listed meta-field two schema-entries later in the same dump).
  **A `specified_by_url` on a remotely-introspected server is invisible to
  every one of this gem's checks, permanently** — not "not diffed
  specifically," genuinely never fetched. One-line, additive fix:
  `GraphQL::Introspection.query(include_is_one_of: true, include_specified_by_url: true)`.

**Description** (any scalar's `description "..."`) reaches the introspection
dump either way (it's requested by the base query graphql-ruby always
includes) — confirmed present on every scalar in `app/graphql/schema.json`.
**Neither ever reaches generated code**: grepped every file in `generated/`
and `generated/types/` for `description` — zero hits. A scalar's description
is schema documentation an editor's GraphQL plugin would show, never a Ruby
comment graph_weaver emits.

**Does `schema:diff` report a description (or, in-process, a `specifiedByURL`)
change?** Changed both `Money`'s `description` and `Duration`'s
`specified_by_url` in the same probe (in-process, so both are visible to
`to_definition` at all):

```
$ bundle exec rake graph_weaver:schema:diff
app/graphql/schema.json vs ServerSchema: 1 change, none breaking
other:
  (schema)  changed in ways this summary doesn't name — compare the dumps
```

**One generic line for both changes combined** — `schema_diff.rb`'s per-kind
comparisons (`compare_object`, `compare_enum`, etc.) never look at
`description` or `specified_by_url` at all; only the catch-all
`note_unnamed_drift` (fires whenever `to_definition` differs and nothing more
specific already explained it) catches this, and it says neither which type
changed nor which of the two things about it did. Matches the class's own
doc comment exactly ("A description, a directive definition, an argument
default moves the SDL without appearing above — still drift, and a gate that
went green on it would be worse than one that admits it can't name it") —
**not a bug, a documented, deliberate limitation** — but worth restating for
this brief's audience next to the `specifiedByURL`-over-a-URL gap above,
since the two combine badly: a remotely-introspected app can't even fall
back on the generic "something changed" signal for `specifiedByURL`, because
the field was never in either dump to diff in the first place.

## Matrix: what I drove x outcome

| driven | outcome |
|---|---|
| 8 real server scalars (`GraphQL::Schema::Scalar` w/ real `coerce_input`/`coerce_result`) + matching client `register_scalar`, `:in_process`, one process | all 8 generate and round-trip correctly when the registration is chosen correctly; setup itself surfaced 2 real Ruby/graphql-ruby gotchas (constant lookup, default-value validation), neither a graph_weaver bug |
| `Decimal.coerce_result` changed (string -> JSON number), client/scalar name unchanged | **HIGH — invisible to `verify`/`schema:diff`/`generate!`; silent precision loss at runtime, no exception** (finding) |
| a plausible-but-wrong client registration for `Money` ("bare decimal" pattern, a real doc-sanctioned option) | generates clean; only a real request (`:in_process`/`:live`/cassette) catches it — `:refused`, server's own message verbatim (finding, moderate — a gap, not a bug) |
| the asymmetric `Money` scalar's own round trip (`from_h(as_json(x)) == x`) | **breaks** — `cast:`/`serialize:` are necessarily different-shape for this scalar, and `serialize:` feeds both the variable AND `as_json`, so the documented round-trip guarantee doesn't hold here (finding) |
| `DateTime`: server accepts epoch millis in, client never produces them | confirmed non-finding — `srb tc` + `Coerce.time`'s type-based refusal makes it structurally impossible for a graph_weaver client to send millis; the server's extra tolerance is real but unreachable through this gem |
| `Email` `CoercionError`, no `extensions.input` convention, across `execute`/`execute!`/`#input_errors` | `execute` -> `#input_errors` carries the server's exact wording, `kind: :refused`, correct path; `execute!` raises `QueryError` whose bare `#message` is generic but `#input_errors` still has the detail (confirmed, not a gap) |
| redaction of that CoercionError message, `filter_parameters` matching the field name | **whole message + value redacted together**, more thorough than expected from a different session's finding on a *different* code path (resolver-raised free text is never redacted; scalar CoercionError / `extensions.input` messages both go through `ServerInput.build`, which redacts fully) — clarifying non-finding, worth stating precisely |
| `@oneOf` input containing `Money`, list-of-input `validates:` on a scalar field (no convention), a scalar default value | all three confirm the docs exactly — no findings; default-value omit/null semantics correctly independent of the server's own default, verified all three cases (omit -> server default applies and round-trips; explicit null -> server rejects; regular value -> works) |
| `:fake` pin shape for an asymmetric scalar — three plausible wrong guesses vs. one right one | wrong-direction pin (string, what a client sends) fails loudly at `from_h` with a confusing generic message (finding, low-medium, additive doc fix); correctly-shaped pin that skips the server's OWN extra validation (currency casing) fabricates and passes a test the real server would 422 on — **exactly the brief's question, answered** (finding, medium — matches a documented general limitation, sharpened for scalars) |
| cassette recorded `:in_process`, server tightens `Email`, replay | `cassettes:check` on the OLD cassette: clean, 0 stale — the stored value still casts regardless of what the live server would now do with it as input. A live `:in_process` call with the same value: rejected. Re-recording: the spec itself fails and the cassette's `response` shape visibly changes from `data` to `errors` — **the only thing that actually catches this, and it catches it hard** (finding — this is the section title's whole point, answered concretely) |
| `specifiedByURL` on a scalar, in-process vs. introspected | in-process: reaches `to_definition`/SDL, so `schema:diff`'s generic catch-all sees SOME change; introspected (a URL source): **never reaches the dump at all** — graph_weaver's own `SchemaLoader.ask` never passes `include_specified_by_url: true` to `GraphQL::Introspection.query` (finding — small, precise, one-line fix) |
| a scalar `description` | reaches the dump either way, never reaches generated code (no comment, nothing); `schema:diff` only ever fires the same generic unnamed-drift line for it — documented, deliberate, not a bug |

## Ranked findings

1. **HIGH — a server-only `coerce_result` change is invisible to
   `verify`/`schema:diff`/`generate!` and surfaces at runtime as a silently
   wrong value, never an exception.** `Decimal.coerce_result` (string ->
   JSON number, scalar name and client registration both unchanged): all
   three offline/online checks report clean; the actual query returns a
   `BigDecimal` built from a lossy `Float`, silently dropping precision past
   ~7 significant digits, with no `CastError`, no warning. Root cause: a
   custom scalar's `coerce_input`/`coerce_result` bodies are Ruby methods
   with no SDL representation at all, so nothing this gem diffs against can
   move. Not really fixable inside graph_weaver's current architecture
   (there is no schema-level place to record a scalar's serialization
   *shape*) — the realistic mitigation is process, not code: a cassette
   *re-recorded* periodically (not just checked) against `:in_process` would
   surface a shape change as a diff on the cassette file itself, which
   nothing currently prompts a team to do on a schedule.

2. **MEDIUM-HIGH — an asymmetric scalar (a real, brief-specified shape:
   object out, string in) breaks the documented `from_h(as_json(x)) == x`
   round-trip guarantee, because `register_scalar`'s one `serialize:` feeds
   both the outgoing-variable wire AND `#as_json`/`#to_json`, while `cast:`
   only ever decodes the incoming-result wire.** Confirmed: `as_json`
   correctly writes the STRING form (matching the server's `coerce_input`,
   so re-sending it as a variable genuinely works), but reading that same
   string back through `from_h` fails (`can't convert nil into BigDecimal`)
   because `cast:` expects the OBJECT form `coerce_result` actually sends.
   This is a real architectural gap for any scalar whose two directions
   genuinely differ in shape — which is exactly the brief's own `Money`
   spec, chosen because real "object out, string in" APIs exist. Additive
   fix: `register_scalar` could accept an optional `wire_serialize:` distinct
   from `serialize:` for the rare asymmetric case (result-direction
   `serialize:` for `as_json`, defaulting to today's single value); until
   then, docs/scalars.md's round-trip promise should say "unless your
   scalar's input and result shapes genuinely differ."

3. **MEDIUM — `:fake` gives a green test for a `Money` value the real server
   rejects, and the *correct* pin shape for an asymmetric scalar's *result*
   direction is genuinely non-obvious (three wrong guesses, one right one).**
   `cast:`'s inference (`Money.from_amount`, `BigDecimal()`) validates
   nothing the server's own `coerce_input` regex enforces (currency casing,
   in this case) — a `:fake` suite that never runs `:in_process`/a cassette
   for that path has literally zero coverage of that gap. This generalizes
   docs/testing.md's own already-stated limitation ("`:fake` ... zero
   coverage of server-side refusal") to a scalar's *own* coercer having
   rules beyond "parses into the registered Ruby type," which is easy to
   miss precisely because a `cast:` inferred from `.parse` looks like real
   validation. Additive: one sentence in docs/testing.md's scalar-pin
   section.

4. **MEDIUM — `specifiedByURL` never reaches the schema dump at all for an
   introspected (URL) source, only for an in-process one — a one-line,
   high-confidence fix.** `lib/graph_weaver/schema_loader.rb`'s `ask` calls
   `GraphQL::Introspection.query(include_is_one_of: true)`, never passing
   graphql-ruby's own `include_specified_by_url: true` — so a scalar's
   `specified_by_url` (a real, if rare, GraphQL 2021+ feature) is invisible
   to `verify`, `schema:diff`, and codegen for the majority topology (a
   remote/introspected server), even though it happens to survive for an
   in-process one via `to_definition`. Trivial, additive fix; low severity
   only because `specifiedByURL` is rarely load-bearing for a generated
   client (it documents a scalar for humans/tools, not for `graph_weaver`
   itself) — flagged mainly because it's cheap to fix and the asymmetry
   (works in-process, silently doesn't over a URL) is exactly the kind of
   thing nobody notices until they go looking, the way this brief did.

5. **LOW-MEDIUM — a plausible, doc-sanctioned client registration for
   `Money` (the "bare decimal, single-currency API" pattern) can be flatly
   wrong for a given server, and nothing before an actual request says so.**
   Not a bug — `register_scalar` has no way to validate itself against live
   server behavior, and the docs never claim it does — but worth stating
   plainly for this brief's exact audience (a team owning both sides): of
   docs/scalars.md's three registration patterns for "the honest hard case,"
   at most one is correct for any given server, and choosing wrong looks
   identical at generation time to choosing right.

6. **LOW — redaction is real and thorough for a scalar `CoercionError` (and
   for the `extensions.input` convention), but this is worth stating
   precisely rather than assumed from a different code path's behavior.**
   `ServerInput.build` redacts the WHOLE message (not just the value) once
   the field name matches `filter_parameters` — confirmed for a plain
   scalar `CoercionError` with no special convention. A resolver's own raw
   `ExecutionError` text (a different code path, per a different session's
   finding) is never redacted at all. Non-finding, but the two-rule
   distinction is easy to get wrong from either finding read in isolation.

7. **Non-findings worth stating, actively tried to break each**: `@oneOf`
   with a `Money` branch: enforced correctly, client-side, before the wire.
   List-of-input `validates:` on a scalar field with no convention: degrades
   to a bare message exactly as documented, `#input_errors` empty. A scalar
   default value (`PriceInput.amount`): the client never encodes or
   duplicates it, correctly relies on omit-vs-null, and both directions
   (server default applied, server default overridden by explicit null)
   verified live. `DateTime`'s extra input tolerance (epoch millis): real on
   the server, structurally unreachable through a generated graph_weaver
   client. Scalar `description`: reaches the dump, never generated code,
   `schema:diff`'s generic catch-all is a documented, deliberate limit, not
   a bug.

## Design critique

The headline tension this brief was built to surface is real and, I think,
close to unfixable within the gem's current shape: **a custom scalar's wire
CONTRACT lives entirely in two places graph_weaver's own schema-comparison
machinery cannot see — a `coerce_input`/`coerce_result` method body on the
server, and a `cast:`/`serialize:` source fragment on the client — and the
only thing tying them together is a shared string, the scalar's name.**
`schema_diff.rb` is honest about this in its own doc comments (deliberately
naming what it *can't* see, rather than pretending completeness), and
`verify`/`generate!` are honest in a different way — they check the CLIENT's
own internal consistency (does the generated file match what the registry
would emit today), which by construction can never catch the server having
moved underneath an unchanged registration. Neither gap is a bug; both are
the predictable shape of "the schema dump is the only shared truth, and a
scalar's serialization isn't in it." Where I'd push back gently on the
design, rather than just document the gap: **cassette re-recording is the
one mechanism that DOES exercise the real `coerce_result` on both sides at
once, and nothing nudges a team to do it on anything but an ad hoc "the API
changed" basis** — `cassettes:check` answers "does yesterday's recording
still parse," never "is yesterday's recording still what today's server
would actually say," which is a materially different and more valuable
question a periodic (not event-triggered) re-record-and-diff would answer
for free, using machinery that already exists.

The second-order finding — `register_scalar`'s one `cast:`/`serialize:` pair
can't honor its own round-trip promise once a scalar's two directions
genuinely differ in shape — is a sharper, fixable instance of the same
family: the API's mental model (one scalar, one wire shape) is right for the
overwhelming majority of scalars and silently wrong for a specific, real
class (an asymmetric API, chosen for this brief because it happens for real —
Stripe's own money-shaped fields being one). The fix is additive (a second,
optional serializer slot) and wouldn't touch the common case at all.

## Where I read lib/ or spec/, and why

- `lib/graph_weaver/in_process.rb` — to confirm, before trusting any
  coerce_result-shape result, that `:in_process` genuinely has no JSON
  encode/decode boundary (its own doc comment says "no socket, no
  serialization"), so a `coerce_result` bug is visible in its RAW Ruby form
  rather than laundered through a JSON round trip that would coincidentally
  normalize a Float back into something JSON-safe.
- `lib/graph_weaver/schema_diff.rb` — to state precisely, rather than infer
  from behavior alone, exactly what the class compares (type objects: shape,
  nullability, enum values, deprecation, interfaces/unions) and what its
  catch-all `note_unnamed_drift` does and doesn't say, before claiming a
  coercer change or a description change is or isn't caught.
- `lib/graph_weaver/internal/values.rb` (`Values#scalar`, `REGISTERED_SHAPES`)
  — to know, before writing the `:fake` pin-shape probes, exactly which
  Ruby-type registrations `:fake` can invent a value for on its own vs. which
  ones need a pin, and why (the `shape_of` method's own branches).
  the exact `#build` call every server-reported InputError goes through, to
  state the redaction boundary as a rule (which key gets checked, what gets
  replaced) rather than as an observed pattern from two or three probes.
- `lib/graph_weaver/internal/server_input.rb` (`ServerInput.build`) — to find
- `lib/graph_weaver/input_struct.rb` (`#serialize`, `.coerce`, `supplied`) —
  to confirm the omit-vs-explicit-null mechanism (`given&.include?`) as the
  actual reason `.new` and `.coerce` behave differently, rather than
  reporting the difference without its cause.
- `lib/graph_weaver/schema_loader.rb` (`.ask`) + graphql-ruby's own
  `lib/graphql/introspection.rb` — to find the exact, one-line root cause of
  the `specifiedByURL` gap (a kwarg default, not a missing feature) rather
  than reporting "specifiedByURL doesn't show up" without knowing why.

## Time

~20 min: pre-work (skim nearest logs, read scalars.md/errors.md/testing.md/
cassettes.md in full). ~50 min: app setup (schema.rb's 8 scalars, two
non-graph_weaver dead ends — Ruby constant lookup, graphql-ruby default-value
validation — both under 15 min, both logged). ~25 min: the flagship
`Decimal.coerce_result` drift probe (verify/diff/generate!, then the
precision-loss repro). ~20 min: the "Money as bare decimal" second
registration + drift_generated/. ~15 min: DateTime millis (quick, mostly
confirmation). ~20 min: Email CoercionError round trip + redaction
(including reading `server_input.rb` to state the rule precisely). ~20 min:
`@oneOf`/list-`validates:`/default value (three clean confirmations, plus
reading `input_struct.rb`). ~35 min: `:fake` spec (one dead end — first
attempt used `ProductQuery`, whose OTHER unfakeable scalars masked the Money
probe; fixed by narrowing to `EchoPriceQuery`, ~10 min, under budget). ~25
min: cassette record/tighten/replay/re-record cycle. ~20 min: introspection
(`specifiedByURL`/description), including reading graphql-ruby's own
`introspection.rb` to find the exact kwarg. ~15 min: matrix, findings,
write-up. Total: ~4.5 hours. No dead end exceeded the 15-minute budget; the
closest were the two setup-phase Ruby/graphql-ruby gotchas, both resolved
inside the window and both logged as such rather than silently worked
around.

## Would I ship on this surface?

Yes — with the flagship finding communicated as a documented limitation, not
a defect to fix before shipping, because I don't think it's fixable within
this architecture without adding a schema-level concept graphql-ruby itself
doesn't have (a machine-checkable claim about a scalar's serialization
shape). The two-sided-scalar-author angle this brief was built around is a
real and, I'd guess, common blind spot: a team confident in `verify`/
`schema:diff` because CI is green has no idea those checks cannot see a
`coerce_result` change, full stop, and the only thing that actually would
(re-recording a cassette on a schedule, not just checking it) isn't a
workflow this gem nudges anyone toward. That's a documentation and process
gap, not a code defect, and it's cheap to close: a paragraph in
docs/scalars.md's "Writing the scalar on the server too?" section stating
plainly "verify/schema:diff cannot see a coercer body move; the only thing
that can is re-recording a cassette against a live/:in_process client and
diffing the recording" would have told me everything this session spent four
hours re-deriving. The `specifiedByURL` gap is a genuine one-line fix I'd
file upstream before anything else here, precisely because it's that cheap.
Everything else this session found (the asymmetric-scalar round-trip break,
the `:fake` pin-shape ambiguity, the bare-decimal registration mistake) is
real but narrow — each affects only scalars whose wire shape is unusual in a
specific way (asymmetric in/out, or carrying validation rules beyond "parses
into this Ruby type") — and each has a cheap, additive documentation fix
available today.
