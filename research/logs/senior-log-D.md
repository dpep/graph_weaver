# GraphWeaver senior-engineer evaluation — session D

Evaluator stance: senior Ruby engineer, second pass on custom scalars —
angle assigned is scalars OUT and at the SEAMS (mutation args/nested
inputs, every test mode, outward serialization, federation @key/@requires,
precision/edge values, post-generation drift, two-name registration).
Read /tmp/claude/graph_weaver/senior-log-A.md first — registration, casting,
Money shapes, and value-object equality are covered there and not repeated.
Working dir: /tmp/claude/graph_weaver/senior-app-D. Gem consumed via `path:`,
never edited. Toolchain: `~/.rvm/wrappers/ruby-3.4.9/bundle exec ...`.

### ~22:55 — read docs/scalars.md, docs/testing.md, docs/cassettes.md in full;
skimmed docs/getting_started.md's "Not Rails?" and "Your app's own schema,
in-process" and "More than one schema" sections; read spec/support/federation's
compose.mjs and recompose.rb and spec/support/federation_router_graph.rb to
learn the apollo-federation-gem DSL this repo's own tests use, since the
brief asks for a real composed two-subgraph supergraph. ~18 min.

### ~22:58 — app scaffold, plain Ruby (no Rails), in-process graphql-ruby
schema, matching senior A's approach. Gemfile: graph_weaver (path), graphql,
apollo-federation, sorbet-runtime/sorbet(-static-and-runtime), money, rspec,
webmock, rack. `bundle install` clean, 42 gems. ~5 min.

### ~23:00–23:33 — built the schema (lib/app/schema.rb) with every scalar the
brief names: `DateTime`/`Date` (built-in convention, `time_precision` bumped
to 6 for sub-second), `Decimal` → `BigDecimal` (stdlib registration),
`Money` → the `money` gem via the **object-shape** cast/serialize
(`{"amount","currency"}`, scalars.md's own recommended recipe), `URL` →
`URI::Generic` with `cast: ->(v) { "URI.parse(#{v})" }` (scalars.md's own
fix for senior A's URI-module finding), `Duration`/`Interval` → the **same**
`IsoDuration` class registered under **two schema names**, `CurrencyCode` →
a small value object (an "enum-like string scalar" — a fixed vocabulary,
declared as a GraphQL *scalar* rather than an enum), and `Vector` → a scalar
whose wire value is a JSON **list**, registered by the type-STRING door
(`"T::Array[Float]"`), nested inside `LineItemInput` inside `OrderInput.items`
(a list of inputs). `OrderInput`/`LineItemInput` cover every scalar as a
mutation argument and nested 2 levels deep inside a list of inputs.
`bundle exec rake graph_weaver:schema:refresh` + `graph_weaver:generate`:
**clean on the first try, no errors, no warnings** — every registration
door landed correctly the first time.

### ~23:25–23:33 — read the generated `place_order_mutation.rb`/`order_query.rb`
directly (not lib/, but worth citing): confirmed `serialize:`/`cast:` are
emitted at **every depth** — `LineItemInput`'s own FIELDS table recurses via
`v.map.with_index { ... GraphWeaver::InputStruct.element(i1, v1) { ... } }`,
and `OrderInput.items`'s serializer is `v.map { |v1| v1.serialize }` —
confirms the brief's "does serialize: run at every depth" with the actual
generated source, not just a runtime probe.

### ~23:34 — spec/scalars_seams_spec.rb: mutation args, nested inputs, wrong
types, nil handling.

**Wrong Ruby type at depth** — `LineItemInput.price: "not-a-decimal"` two
levels deep inside `items[]`:
```
$input of PlaceOrderMutation: price: invalid value for BigDecimal(): "not-a-decimal"
```
`coordinate` = `"LineItemInput.price"`. Clean.

**Nil in a non-null slot, nested inside a list of inputs**
(`LineItemInput.sku: nil`):
```
$input of PlaceOrderMutation: missing required key(s) for GraphQLTypes::LineItemInput: sku
```
`coordinate` = `"LineItemInput.sku"`. Clean, and matches docs' "the message
lists every one; #path names the first."

**Nil in a nullable slot** (`vector: nil, warranty: nil`) — accepted and
skipped correctly (confirmed by reading `lib/graph_weaver/input_struct.rb`'s
`.coerce`: `next [field.prop, raw] if raw.nil? || field.coercer.nil?`), **but
only once I fixed my own schema's custom scalars to guard nil in
`coerce_input`.** With the naive (un-guarded) version I wrote first, a real
finding surfaced:

**Finding (design confirmation, not a graph_weaver bug, but worth knowing
going in): graphql-ruby calls a *nullable* custom scalar's `coerce_input`
even for an explicit `null` argument value** (confirmed directly against
`graphql (2.6.10)`: only a `NonNull`-wrapped type special-cases null and
skips straight to its own error; a plain scalar type does not). So a custom
scalar written the way scalars.md's own examples are written — `IsoDuration.parse(value)`
with no nil guard — raises a bare `ArgumentError` that graphql-ruby does not
catch or turn into a GraphQL-level error; it blows past the whole request.
**`graph_weaver`'s `:in_process` client (`lib/graph_weaver/in_process.rb:87`)
is the one thing that gives it a name** — `GraphWeaver::ServerError: "HTTP
500: ArgumentError: not an ISO-8601 duration: nil"` — faithfully
representing what a real server would do (an unhandled 500), which `:fake`
would never surface since it never runs resolver/scalar code. This is a
**positive** finding about `:in_process`'s fidelity, and a **real,
generalizable footgun for anyone writing a custom scalar** that the docs
could flag with one sentence ("coerce_input runs on an explicit null too —
guard it, or NonNull the argument").

**Finding (real, medium severity): a scalar registered as a bare Sorbet type
STRING (`"T::Array[Float]"`, the list-scalar door) gets a materially worse
`InputError` than every other kind on a type mismatch.** `vector: [1, 2, 3]`
(plain JSON integers — completely normal on the wire) raises:
```
$input of PlaceOrderMutation: items: invalid input for GraphQLTypes::LineItemInput: Parameter 'vector': Can't set GraphQLTypes::LineItemInput.vector to [1, 2, 3] (instance of Array) - need a T::Array[Float]
```
`e.kind` = `:type_mismatch` (fine), but `e.coordinate` = `"OrderInput.items"`
(the containing LIST field, not `"LineItemInput.vector"` — the actual
field), `e.details` = `{}` (empty, not `{type:}` the way every other
type-mismatch carries it), and the message leaks the **generated module
name** (`GraphQLTypes::LineItemInput`) and Sorbet's own wording verbatim —
exactly what docs/errors.md promises never happens ("`type` is the
**schema's** name for the type ... never the Ruby class it maps to").
**Root cause, found by reading `lib/graph_weaver/input_struct.rb`'s
`mistyped` heuristic and testing it directly:** `mistyped` asks
`T::Utils.coerce(T::Array[Float]).valid?([1,2,3])`, and confirmed by hand
that call returns **`true`** — sorbet-runtime's `.valid?` for `T::Array[X]`
is a *shallow* check (container class only, no element check), while the
`T::Struct`'s own prop **setter** validates recursively and raises. Since
`vector` has no cast/serialize (a registration used only for a variable is
untouched, per docs), the field-level `GraphWeaver::InputStruct.field` wrapper
that normally brands each field with its own coordinate never runs for it —
so the exception only reaches the outer, coarser `LineItemInput.coerce`
rescue, whose `mistyped` heuristic can't see the mismatch its own `.valid?`
says isn't there, and falls back to the generic message with no coordinate
of its own. **This is a real gap specific to a scalar registered as a
Sorbet *generic* type string used inside a nested input** — a scalar
registered as a plain class doesn't have this problem, because it always has
a coercer and goes through the field-level wrapper.

### ~23:38 — spec/edge_values_and_outward_spec.rb: precision, edge values, and
outward serialization, using `Order.from_h(wire_hash)` directly (no schema
execution — faster, and gives exact control over the wire bytes for every
edge case).

| edge value | outcome |
|---|---|
| `BigDecimal("0.1")` from a wire string | exact — `.to_s("F") == "0.1"`, no binary-float artifact |
| `DateTime` at a DST boundary, microsecond precision | round-trips exactly (`time_precision = 6`) |
| Negative `Duration` (`-PT1H30M`) | parses to `-5400.0`, round-trips through its own `.to_s` |
| `Date` before 1970 (`1969-07-20`) | `Date.iso8601` — no special-casing needed, works |
| `Money` zero / negative | both cast correctly; `.negative?` reads true |
| `URL` with unicode (`?ref=café`) | **raises** — `URI must be ascii only` |
| `JSON` holding `null`/`[]`/`{}`/a string that looks like JSON | all four exactly right — the string-that-looks-like-JSON is **not** re-parsed |

**Finding (medium, docs gap): the `URL`/`URI::Generic` registration
docs/scalars.md itself recommends** (the exact fix for senior A's earlier
"register `URI` the module, not `URI::Generic`" finding) **is not robust to
literal Unicode in the URL, which JSON permits and real servers do
sometimes emit** (unencoded query params, IDN hosts). `GraphWeaver::CastError:
failed to cast response ...: website: URI must be ascii only
"https://shop.example.com/orders/1?ref=café"`. Not a graph_weaver bug —
it's calling exactly the `cast:` it was told to — but worth one sentence in
the docs' own recipe, since it's the *recommended* fix for a real,
previously-filed finding, and the failure mode (a `CastError` naming the
field) is at least clean and locatable.

**Finding (HIGH severity, silent, and the sharpest one in this session):
`ResultStruct` defines no `#to_json` of its own, and outside Rails/
ActiveSupport (this app's setup, matching docs' own "Not Rails?" path)
calling `.to_json` directly on a result reaches the plain `json` stdlib's
`Object#to_json` fallback (`to_s.to_json`) — every field is silently
dropped, with NO exception and NO warning:**
```ruby
order.to_json  # => "\"#<OrderQuery::Result::Order:0x0000000124fdc760>\""
```
`#serialize` (sorbet-runtime's own, not graph_weaver's — `respond_to?(:serialize)`
is `true` on every result) is not a fix either: it embeds the **raw** Ruby
scalar objects unconverted (confirmed: `s["total"]` is a real `Money`,
`s["items"].first["warranty"]` a real `IsoDuration`), snake_cased, not the
wire's camelCase — so `.serialize.to_json` only "works" by accident, for
whichever scalar classes happen to define their own `#to_json`/inherit a
useful `#to_s`. And even where it "works," **it can silently diverge from
the registered wire contract**: our `Money` registration uses the
object-shaped `serialize:` scalars.md itself recommends
(`{"amount"=>...,"currency"=>...}`), but the `money` gem's own `#to_json`
(which is what a bare `.to_h.to_json` or `.serialize.to_json` reaches) is
**not that** — for EUR it writes a **locale-formatted, comma-decimal
string with the currency dropped entirely**:
```ruby
Money.from_amount(BigDecimal("12.50"), "EUR").to_json   # => "\"12,50\""
# vs. what register_scalar's serialize: actually writes:
{ "amount" => "12.5", "currency" => "EUR" }.to_json      # => '{"amount":"12.5","currency":"EUR"}'
```
Nothing raises, nothing warns anywhere in this chain. `getting_started.md`'s
coverage-lint section lists `to_json` right next to `to_h`/`as_json`/
`render json:` as one of the excuses that count a query "read" — which
reads, on first encounter, as the docs treating `to_json` as a working
serialization path for a result. For a plain-Ruby (non-Rails) app it silently
is not one, and even where a class's own `#to_json` happens to fire, it is
not guaranteed to agree with the wire contract `register_scalar`'s
`serialize:` defines.

`to_h`, `YAML.dump`/`.unsafe_load`, `Marshal.dump`/`.load`, `deconstruct_keys`
in a pattern match, and equality/hash-consistency of two structs holding
equal-but-not-identical scalar objects (two separate `Money`, `IsoDuration`,
`URI::Generic` instances from two separate `.from_h` calls) — **all five
worked correctly on the first try**, no findings. `eql?`/`hash` hold up
end-to-end: `{a => 1}[b] == 1` for `a`/`b` two distinct structs built from
identical wire data.

### ~23:40 — spec/modes_spec.rb: `graphql: :fake` fabrication.

Confirms and **generalizes** a documented rule: `:fake` refuses to fabricate
any scalar registered as your own class (`CurrencyCode` first, by field
order — verbatim message matches docs exactly) **and also any scalar
registered by a type STRING** (`Vector` → `"T::Array[Float]"`) even though
the underlying shape (a plain JSON array) looks exactly as "needs nothing"
as `BigDecimal`/`Time`/`Date` do. This generalizes docs/scalars.md's
"narrowing JSON also opts a field out of fabrication" rule beyond the JSON-
narrowing case specifically.

**Finding (confirms a documented rule, worth having actually checked): pins
are keyed by SCHEMA scalar name, never by the underlying Ruby class.**
Pinning `"Duration"` alone left `"Interval"` refusing fabrication — even
though `register_scalar("Interval", IsoDuration)` is the **exact same Ruby
class** as `Duration`. Each of the two schema names needs its own pin. Once
pinned, both cast through the real registered `cast:` correctly (a pinned
`"PT3H"` becomes a real `IsoDuration.parse("PT3H")`, not a raw string
splatted into the struct).

### ~23:41 — spec/wire_and_cassette_spec.rb.

**`graphql: :wire`**: round-trips every scalar through a real HTTP
request/response body (webmock intercepting the in-process schema behind a
url). One gotcha, confirmed the hard way: **the same "configure before the
tag's own `before` hook, not after" rule docs/testing.md states for
`Testing.configure` also binds `GraphWeaver.client=`** — setting the client
in a plain `before` (after the tag's own setup already inspected the
app-default in-process client) gets:
```
graphql: :wire runs your own transport against your resolvers, so it needs
the endpoint that transport posts to — and GraphWeaver.client is
GraphWeaver::Client, which posts to none.
```
Moving it to `around` (ahead of `example.run`) fixed it immediately. Worth
one line in docs/testing.md's `:wire` section, since the existing warning is
scoped to `Testing.configure` only.

**A cassette** (`GraphWeaver::Testing.cassette`, recorded against a real
in-process `GraphWeaver.new(App::Schema)` client, then replayed): **passed on
the first try**, no findings. `BigDecimal("0.1")` records and replays with
the exact same `.to_s("F")`; a DST-boundary `Time` with microsecond precision
round-trips exactly through the YAML file; a negative `Duration`
(`-PT1H30M`) round-trips exactly. Recorded vs. replayed structs are `==`.

### ~23:42–23:49 — federation: a custom scalar as `@key` and as `@requires`.

Two real subgraphs (`Fed::Pricing`, `Fed::Reporting`, apollo-federation gem,
`lib/app/federation.rb`), composed with the repo's own
`spec/support/federation/compose.mjs` (Apollo's real composition — never
touched the gem's copy, just invoked it via `Open3.capture3` with my own
subgraph SDL on stdin). `Currency.code: CurrencyCode!` is the `@key`;
`Currency.exchangeRate: Decimal!` `@requires(fields: "decimalPlaces")` is
the `@requires` field-set member, both custom scalars this session
registered.

**Composition failed twice before succeeding, informatively both times —
graphql-ruby/apollo-federation-gem tooling friction, not graph_weaver:**
1. `orphan_types Currency` alone was not enough to make `Reporting::Currency`
   appear in `federation_sdl`/`GraphQL::Schema::Printer` at all (confirmed:
   `.types` included it, the printer/SDL still silently dropped it) — fixed
   by giving it a real (non-root) reachability path (`Report.currency`),
   matching this repo's own `spec/support/federation_router_graph.rb` shape.
2. Composition then refused with a precise, actionable error —
   `"cannot move to subgraph pricing using @key(fields: 'code') of
   'Currency', the key field(s) cannot be resolved from subgraph
   reporting"` — because the extending subgraph's type needs the
   `@extends`/`extend_type` marker (`ApolloFederation::Object#extend_type`);
   confirmed by diffing against `RouterGraph::Reviews::Product`'s own
   printed SDL, which carries `@extends` and mine didn't.

Once fixed, **composed cleanly**, and end to end:
- `Testing::Router` executing a raw GraphQL string resolves `currency(code:
  "USD") { code decimalPlaces }` from `pricing` correctly.
- `Report { currency { code decimalPlaces exchangeRate } }` correctly stitches
  across subgraphs: `pricing` resolves the entity by `code` (a `CurrencyCode`
  key), `reporting`'s `exchangeRate` resolver receives the `@requires`'d
  `decimalPlaces` and computes `0.01` correctly.
- **Finding (clarifying, not a graph_weaver issue — a federation-spec fact
  worth having confirmed directly): a `@requires`'d custom-scalar field
  arrives at the resolver already wire-serialized** — `object` is
  `{code: "USD", decimalPlaces: "2.0", __typename: "Currency"}` (`String`,
  camelCase symbol key), **not** the registered Ruby type (`BigDecimal`) and
  not even the schema's own casing convention. Representations travel as
  JSON between subgraphs per the federation spec — `register_scalar` only
  governs the **client** boundary, never inter-subgraph stitching — so a
  resolver handling a `@requires`'d custom scalar must re-parse it itself.
- Generated a real client query (`GraphWeaver.graph`, `schema
  "supergraph.graphql"`, `register_scalar "CurrencyCode"`/`"Decimal"`)
  against the composed supergraph: **`ReportQuery`'s generated struct casts
  both the `@key` field and the `@requires` field correctly** —
  `const :code, CurrencyCode`, `const :exchange_rate, BigDecimal`, both
  populated correctly end to end through `Testing::Router`. Federation
  composes and casts a custom scalar at both seams the brief asked about,
  cleanly, once the (graphql-ruby/apollo-federation, not graph_weaver)
  tooling friction above was worked through. ~22 min total against the
  brief's 20-minute budget for this door — slightly over, entirely spent on
  #1/#2 above (apollo-federation gem plumbing), not on graph_weaver itself.

### ~23:49 — a scalar registered after generation (drift), and re-confirming
two-name registration doesn't confuse `verify`.

Re-registering `Duration` in-process (a different `cast:`, no regenerate),
`GraphWeaver.verify_generated!` catches it immediately and names every
affected file — correctly **three** files this time (`line_item_input.rb`,
`order_query.rb`, `place_order_mutation.rb`), since `Duration` reaches both
an input and two response structs:
```
stale generated queries — regenerate (rake graph_weaver:generate):
app/graphql/generated/types/line_item_input.rb,
app/graphql/generated/order_query.rb,
app/graphql/generated/place_order_mutation.rb
```
No finding — matches senior A's earlier confirmation exactly, generalized to
a scalar reaching multiple files/directions at once.

### Final state

`bundle exec rspec`: **29/29 green** (5 spec files: scalars_seams,
edge_values_and_outward, modes, wire_and_cassette, verify_drift).
Did not wire up `sorbet`/`tapioca` fully for this app (no `sorbet/config`) —
senior A already covered `srb tc` cleanliness for the registration/casting
angle, and this session's angle (seams/modes/precision/federation) didn't
need it; noting rather than skipping silently, per the 15-minute-dead-end
rule.

## Doors named in the brief, not separately reproduced

Every bullet in the brief has a concrete repro above or in the five spec
files. The one thing reasoned about rather than independently re-driven: a
`:router`-tagged rspec example (`graphql: :router`) specifically, as opposed
to `Testing::Router` used directly — the brief's federation ask was answered
end-to-end with the latter, and the tagged-example wiring is exactly the
same mechanism `spec/rspec_spec.rb` in the gem's own suite already covers.
