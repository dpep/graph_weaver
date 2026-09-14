# hunt 2 — the surfaces that landed since hunt 1

Baseline: main `4730ec0`. **Note:** during this hunt the docs agent committed
`62a14ef` and `e773183` directly to `main` in this checkout, not to its own
worktree as the brief assumed. Docs only — `git diff --stat 4730ec0..HEAD --
lib/ spec/ bin/` is empty, so every repro below still stands against unchanged
code. Worth knowing anyway: two agents were writing to one branch.

Suite green here too (`--order rand:20260912`, exit 0,
98.43% line coverage) and `git status` clean throughout. Ranked by harm:
**silent wrong answer > crash > refusal that misdirects > paper cut.** Every
numbered item has a runnable repro. Hunches are in their own list at the end.

Property harness, widened, all clean — so none of the below came from it, and
that is itself a finding (see "the harness's blind spot" at the bottom):

| run | result |
|---|---|
| `bin/round-trip -c 5000` | 29126 round trips / 3 schemas, **0 failures** |
| `bin/round-trip --hostile -c 3000` | 7963 round trips / 3 schemas, **0 failures** |
| `bin/round-trip examples/github/schema.json -c 1500` | 2909 round trips, **0 failures** |

---
## A. Silent wrong answers

### A1. A typo'd filtered key leaks its value — the library names the secret and prints it in the same sentence

`filter_parameters` is substring-matched against the key the caller *supplied*.
An unknown key is, by definition, not the key you meant — so `passwrod` misses
the `password` filter and the value goes out in clear, in `#value` and in
`to_h`. The library has already worked out the intended key: it is sitting in
`details[:suggestion]` in the same error.

```
~/.rvm/wrappers/ruby-3.4.9/bundle exec ruby /tmp/claude/graph_weaver/hunt2-probe6.rb
```
```
message: $creds of T6: unknown key(s) for M::CredsIn: passwrod (did you mean 'password'?)
value:   "hunter2"
details: {suggestion: "password"}
to_h:    {...,"value":"hunter2","details":{"suggestion":"password"},...}
```

Reachable by an ordinary typo — which is the only situation this error exists
for. The warn log line is clean (the message doesn't quote the value); the leak
is in `#value`/`to_h`, i.e. the 422 body and whatever ships to Sentry.

**Fix (one line):** `lib/graph_weaver/hints.rb:45` — redact against the
suggestion as well as the supplied key, or (simpler, and one rule instead of
two) stop attaching `value:` to an unknown-key error at all: the key is the
problem and the value has no slot to belong to.
**Files:** `lib/graph_weaver/hints.rb`, `spec/input_errors_spec.rb`.

### A2. `filter_parameters` scrubs `#value` but not `#message` on every server-side input error

Client-side refusals run the message through `Redact.detail`
(`coerce.rb:122`, `input_struct.rb:67`). `ServerInput.build`
(`internal/server_input.rb:129`) redacts only `value:`. graphql-ruby quotes the
rejected value in its explanation as a matter of course, so the common case
leaks:

```
~/.rvm/wrappers/ruby-3.4.9/bundle exec ruby /tmp/claude/graph_weaver/hunt2-probe4.rb
```
```
== 1. graphql-ruby problems, filtered leaf ==
  kind=:unparseable path=["creds", "password"] value="[FILTERED]"
  msg=Could not coerce value "hunter2" to Int
== 2. BAD_USER_INPUT coded, filtered argument ==
  value="[FILTERED]"   msg=Invalid input: password "hunter2" is too short
== 3. extensions.input convention, filtered ==
  value="[FILTERED]"   msg=password "hunter2" is not acceptable
```

All three shapes. `value` proving it tried is what makes this a broken promise
rather than a gap: the library says it redacts, and half of the surface does.

**Fix:** `ServerInput.build` applies `Redact.detail(path.last, message)`, the
same call the two client-side layers make.
**Files:** `lib/graph_weaver/internal/server_input.rb`, `spec/filtered_messages_spec.rb`.

---

## B. Crashes

### B1. `InputError#to_h` is not JSON-serializable for two of the library's own refusals — `render json: e.to_h` 500s

`docs/errors.md:116` documents `render json: e.to_h, status: :unprocessable_entity`
as *the* idiom. For a non-finite Float or Int — which is precisely what
`Coerce.finite` / `Coerce.whole` exist to refuse — `value` is the raw
`Float::INFINITY`/`NaN`, and JSON has no spelling for either:

```
~/.rvm/wrappers/ruby-3.4.9/bundle exec ruby /tmp/claude/graph_weaver/hunt2-probe9.rb
```
```
InputError raised as designed: $rating of T9: expected a Float, got NaN — not a finite number
now the app renders a 422:
  JSON::GeneratorError: NaN not allowed in JSON

InputError: $count of T9: expected an Int, got Infinity — not a whole number
  JSON::GeneratorError: Infinity not allowed in JSON
```

An average over an empty set, or `(10**400).to_f`, gets you there. The crash is
inside the error handler, so the original diagnosis is lost too, and a 422
becomes a 500. Note the neighbouring `"1e400"` *string* case is fine — `value`
keeps the original String — so the inconsistency is internal to `Coerce`.

**Fix:** in `Coerce.finite`/`Coerce.whole`, put the value's `to_s` (or the
original argument) in `value:` rather than the non-finite Float — `to_h` must
be JSON-clean or the documented idiom is a lie.
**Files:** `lib/graph_weaver/coerce.rb`, `spec/input_errors_spec.rb`.
(Second route, same bug: an `extensions.input.value` of `Infinity` from a
lenient-parsed response — `hunt2-probe4.rb` case 4.)

---

## C. Refusals that misdirect

### C1. `path` silently loses the list index for every list of leaves — the emitter emits the machinery and the runtime never uses it

The emitter wraps each element in `InputStruct.element(i)`:

```ruby
variables["ids"] = ... GraphWeaver::Coerce.variable("ids", OPERATION_NAME, ids) {
  |v| v.map.with_index { |v1, i1| GraphWeaver::InputStruct.element(i1) { GraphWeaver::Coerce.integer(v1) } } }
```

but `InputStruct.element` (`input_struct.rb:42`) only rescues
`GraphWeaver::InputError`, and **no leaf coercer ever raises one** — `Coerce.*`
and `InputStruct.enum` raise a branded plain `ArgumentError`/`TypeError`/
`KeyError` (that is the whole point of `Internal::Refusal`). So the index is
dropped and the refusal reports the variable and the whole list:

```
~/.rvm/wrappers/ruby-3.4.9/bundle exec ruby /tmp/claude/graph_weaver/hunt2-probe3.rb
```
```
list of Int, bad element at index 2:
  kind=:unparseable path=["ids"] field="ids" value=[1, 2, "x"]
  msg=$ids of L: expected an Int, got "x" (got [1, 2, "x"])
list of enum, bad element at index 1:
  kind=:not_a_member path=["kinds"] field="kinds" value=["CAT", "LIZARD"]
list of String, bad element at index 1:
  kind=:type_mismatch path=["names"] field="names" value=["a", 7]
```
Same inside an input object (`hunt2-probe8.rb`): `path=["inp","tags"]`, no index.

`errors.rb:589` documents `#path` as "rooted at the variable and down through
input fields **and list indices**", and the *one* spec that covers indices
(`spec/input_errors_spec.rb:54`) uses a list of **input objects**, where the
element coercer is a generated `.coerce` that does raise `InputError` — so the
suite confirms the contract on the one shape where it holds. That is the
confirmation-bias trap: the passing spec is evidence about input-object lists
only, and it reads as evidence about lists.

**Fix:** give `InputStruct.element` the `rescue StandardError` branch
`InputStruct.field` already has — build an `InputError` with `path: [index]`,
`value: <element>`, `kind: Refusal.kind_of(e)`.
**Files:** `lib/graph_weaver/input_struct.rb`, `spec/input_errors_spec.rb`.
Contained: one emit site (`codegen/nodes.rb:166`) and one runtime method, so the
fix needs no fixture regeneration. It composes — `Coerce.variable` then takes
its `InputError` branch and yields `path: ["ids", 2]`, `value: <the element>`.

### C2. A list-of-lists with a nil or non-list element refuses with a raw Ruby `NoMethodError`

Consequence of C1 — the inner `.map` isn't guarded either:

```
~/.rvm/wrappers/ruby-3.4.9/bundle exec ruby /tmp/claude/graph_weaver/hunt2-probe2.rb
```
```
grid nil inner:      kind=:refused path=["grid"] value=[[1, 2], nil]
   msg=$grid of Probe: undefined method 'map' for nil (got [[1, 2], nil])
grid not a list:     kind=:refused path=["grid"] value=[1, 2]
   msg=$grid of Probe: undefined method 'map' for an instance of Integer (got [1, 2])
```
`kind: :refused` plus a Ruby internals message reads as a graph_weaver bug, not
as "element 1 should have been a list". Same fix as C1 plus a type check on the
element before `.map`.
**Files:** `lib/graph_weaver/codegen/emit.rb` (or `input_struct.rb`), `spec/input_errors_spec.rb`.

### C3. `coordinate` can name a slot that does not exist in the schema

The fifth case the brief asked for — `coordinate` *wrong*, not nil.
`ServerInput.explained`'s `NOT_DEFINED` branch builds `"#{type}.#{path.last}"`,
but `path` is `root + within`; when the problem's own path is empty, `path.last`
is the **variable name**:

```
~/.rvm/wrappers/ruby-3.4.9/bundle exec ruby /tmp/claude/graph_weaver/hunt2-probe7.rb
```
```
path=["creds"] coordinate="CredsIn.creds" field="creds" kind=:unknown
```
`CredsIn.creds` is not a thing. An app keying an i18n label off `coordinate`
gets a miss, or the wrong label if a same-named field happens to exist.

Honesty about likelihood: I synthesised that response. graphql-ruby 2.6.10
always supplies a problem path for this explanation, so I could not get it to
emit the shape itself — this is reachable from a non-graphql-ruby server or a
gateway that rewrites problems, not from the mainline server.

**Fix:** build the coordinate only when the problem's own path is non-empty
(`within.last`, not `path.last`).
**Files:** `lib/graph_weaver/internal/server_input.rb`.

### C4. A `@oneOf` input supplied with exactly one field, explicitly null, is told to supply exactly one field

```
oneOf nil: kind=:refused path=["pick"] coord=nil value={by_id: nil}
   msg=$pick of Probe: M::PickInput is @oneOf — supply exactly one field, non-null, got byId
```
The caller did supply exactly one field. The message should say `byId was null`.
Also: all three `@oneOf` refusals carry `kind: :refused`, empty `path` and no
`coordinate`, so a form has nothing to highlight — `:missing` with
`path: [the-null-field]` is available for the null case.
**Files:** `lib/graph_weaver/input_struct.rb` (`serialize`'s ONE_OF branch).

---

## D. Paper cuts

- **`details` values are type-unchecked from a server.** `DETAILS` closes the
  key set — the comment says so, "a server can't smuggle arbitrary data in" —
  but not the types. `hunt2-probe4.rb` gets `details={members: "not a list",
  min: {"deep" => [1, 2]}}` through. `errors.rb:606` promises "members stays an
  Array"; an app doing `details[:members].join(", ")` raises. One line in
  `ServerInput.convention` to drop a detail whose type doesn't match its key.
- **A wrong-typed *list element* loses its value entirely.** `_and: ["nope"]`
  → `value=nil` while the sibling case `_not: [{...}]` → `value=[{name: "a"}]`.
  `InputStruct.element` doesn't own `value:`; same fix as C1 covers it.
- **`to_h`'s `.compact` can't distinguish "the value was null" from "there was
  no value"** — a server saying `extensions.input.value = null` loses that.
- **`field` returns a stringified index** (`"1"`) for a list-element failure,
  which is not a field a form can highlight.

---

# ResultStruct and the generated structs

### A3. `STRUCT_METHODS` is a load-time snapshot, so whether a field is refused depends on what else is in the Gemfile

`codegen.rb:338` derives the reserved-prop set from `T::Struct.instance_methods`
at *load* time, and the comment states the intent outright — "Derived rather
than listed, so it tracks whatever the Ruby and sorbet-runtime in play actually
define." That intent is the bug: it makes codegen a function of require order,
which CLAUDE.md's **"no spooky action at a distance"** invariant forbids by
name. Three gaps, each proven:

**A3a — load order decides.** `Object#as_json` (ActiveSupport, reachable from an
ordinary `asJson` GraphQL field):
```
~/.rvm/wrappers/ruby-3.4.9/bundle exec ruby /tmp/claude/graph_weaver/hunt2-rs-envdep2.rb
```
```
--- Object#as_json defined BEFORE require graph_weaver ---
as_json: refused -- result key "as_json" ... would become prop 'as_json', which every generated struct already defines
--- Object#as_json defined AFTER  require graph_weaver ---
as_json: GENERATED (no refusal)
```
When it slips through, the prop reader shadows the real `as_json`, so a Rails
`render json: result` serialises the field's string
(`hunt2-rs-shadow.rb`: `struct.as_json => "FIELD-VALUE"`). This also quietly
falsifies `spec/codegen_spec.rb`'s "byte-identical source for the same inputs":
same inputs, different Gemfile, different answer.

**A3b — `deconstruct` is not reserved** although `deconstruct_keys` is
(`docs/upgrading.md:69` records adding that one reactively). `Object` doesn't
define it, so it falls out of a derived set. A prop named `deconstruct` makes
array pattern matching silently destructure the field:
`array pattern MATCHED the struct: x="a" y="b"`.

**A3c — every private `Kernel` method is missing**, because `instance_methods`
returns public + protected only; the comment's claim that "Kernel's methods are
already covered by T::Struct's" is true only of the public ones. `puts`,
`raise`, `format`, `p`, `require`, `load`, `system`, `open` all generate and
load clean (`hunt2-rs-names.rb`). **`raise` detonates** — `Hints#method_missing`
(`hints.rb:122`) calls bare `raise`, which now resolves to the zero-arity prop
reader:
```
~/.rvm/wrappers/ruby-3.4.9/bundle exec ruby /tmp/claude/graph_weaver/hunt2-rs-raise.rb
--- typo access (should be a helpful NoMethodError) ---
ArgumentError: wrong number of arguments (given 2, expected 0)
--- serialize with a missing required prop ---
ArgumentError: wrong number of arguments (given 1, expected 0)
```
**Fix:** union the derived set with an explicit frozen list — `deconstruct`,
`to_a`/`to_ary`/`to_hash`/`to_str`/`to_int`/`to_proc`, `to_json`, `as_json`,
`to_param`, `to_query`, `try`, `presence`, `each`, and
`Kernel.private_instance_methods(false)` — so the refusal set is a property of
the gem, not of the Gemfile.
**Files:** `lib/graph_weaver/codegen.rb`, `lib/graph_weaver/codegen/aliases.rb`
(`ALIAS_RESERVED` reads the same set), `spec/codegen_spec.rb`, `docs/upgrading.md`.

### A4. A registered scalar silently breaks the documented `==` and hash-key guarantee

`docs/generated_modules.md:172` promises value equality and "a result works as a
hash key". `ResultStruct#==` compares props with `Hash#eql?`, which compares
values with `eql?`. A `register_scalar` codec that builds an ordinary Ruby value
object — `==` defined, `eql?`/`hash` left at `Object`'s identity, the most
common value-object idiom in Ruby, and the docs' own headline `Money` example
(`docs/scalars.md:84`) — makes two results parsed from the *same bytes* unequal:
```
~/.rvm/wrappers/ruby-3.4.9/bundle exec ruby /tmp/claude/graph_weaver/hunt2-rs-codec.rb
values equal?            true
docs promise a == b:     false
docs promise hash key:   nil
```
**Fix:** cheapest honest option — have `register_scalar` warn at registration
when the class defines `==` but inherits `Object#eql?`, and say so in
`docs/scalars.md`.
**Files:** `lib/graph_weaver/codegen/registry.rb`, `docs/scalars.md`,
`docs/generated_modules.md`.

### A5. `#to_h` hands back the live object for an untyped/registered scalar

`unwrap_value` copies nested structs and arrays; everything else is the same
object. Mutating what `to_h` returned mutates the `const`-immutable struct and
flips its `==` (`hunt2-rs-leak.rb`): `before {"color"=>"brown"} r==r2: true` →
`after {"color"=>"PINK"} r==r2: false`, `same object? true`.
**Fix:** freeze scalar values at cast time in the generated `from_h`, or `dup`
non-struct `Hash`/`String` in `unwrap_value`.
**Files:** `lib/graph_weaver/result_struct.rb`, `docs/generated_modules.md`.

### A6. YAML round-trip breaks `T::Enum` identity

`YAML.dump`/`safe_load` (Rails' `:yaml` cache coder, some job serializers)
returns a *duplicate* enum instance, so `pet.species == Species::Dog` is false
and the struct no longer equals itself (`hunt2-rs-yaml.rb`). `Marshal`
round-trips fine. Upstream cause is sorbet-runtime, but graph_weaver is what
puts enums inside a user's cacheable object.
**Fix:** emit `encode_with`/`init_with` on generated enum types, or document
"Marshal-safe, not YAML-safe".
**Files:** `lib/graph_weaver/codegen/enum_type.rb`, `docs/generated_modules.md`.

### C5. `respond_to?` answers true for names that don't exist

`Hints#respond_to_missing?` says true for any near-miss, so the standard
duck-typing guard is the thing that breaks:
`obj.pet if obj.respond_to?(:pet)` → `NoMethodError: undefined method 'pet' …
did you mean 'pets'?`. The code comment (`hints.rb:130`) shows the hint is
deliberate; paying for it in `respond_to?` probably isn't.
**Fix:** keep `method_missing`'s hint, let `respond_to_missing?` fall through to
`super`. **Files:** `lib/graph_weaver/hints.rb`, `spec/hints_spec.rb`.

### D5. `JSON.generate(result.to_h)` silently writes non-wire values

A `Time` scalar loses subseconds and stops being ISO 8601; `BigDecimal` becomes
`"0.125e2"`, which the docs themselves call out as "not what any server means by
12.5". Documented as not-the-wire-shape, but the trap is one keystroke from the
documented use. **Fix:** add the counter-example at
`docs/generated_modules.md:189`.

**Cleared on ResultStruct** (don't re-run): `hash`/`eql?`/`==` agree across
`Date`, `DateTime`, `Time` (tz-shifted, subsecond) and `BigDecimal`;
cross-process `hash` instability is Ruby's randomised seed, not a gem bug (a
plain `Hash` and a bare `String` move identically); `Marshal` round-trips `==`
and `hash`; struct-vs-Hash and struct-vs-different-class are correctly `false`
and symmetric; subclassing a `T::Struct` is impossible so there is no
subclass/parent case; `inspect`/`==`/`hash`/`to_h` are all linear to 16k nodes
(`inspect` 0.067s, no stack growth); pattern matching incl. the union catch-all
`Other` behaves; `alias_method :eql?, :==` under a sig costs nothing.

---

# Transport, config, and the install generator

### A7. The install generator's `.rubocop.yml` append deletes the app's existing `AllCops/Exclude`

`lib/generators/graph_weaver/install_generator.rb:76-105` guards with a
*textual* `body.match?(/^AllCops:/)`. RuboCop **overrides** `Exclude` arrays on
merge rather than unioning them, so whenever `AllCops:` doesn't literally appear
in that one file the appended block replaces the effective exclude list —
including RuboCop's own defaults (`vendor`, `node_modules`, `tmp`), and
including an `AllCops/Exclude` that arrived via `inherit_from:` and the
generator can't see. I reproduced this independently:
```
GEM_HOME=/tmp/claude/graph_weaver/hunt2-cfg-1/gems \
  ~/.rvm/wrappers/ruby-3.4.9/ruby /tmp/claude/graph_weaver/hunt2-cfg-1/t5_rubocop_merge.rb
```
```
A1 before generator: count=4  vendor=true node_modules=true tmp=true  generated=false
A2 after  generator: count=1  vendor=false node_modules=false tmp=false generated=true
B1 before: legacy excluded? true
B2 after:  legacy excluded? false  generated excluded? true
```
The day after `rails g graph_weaver:install`, rubocop starts linting vendored
code. **Fix (verified in `t5b_fix.rb`):** scope an `inherit_mode` into the
appended block so `Exclude` unions —
```yaml
AllCops:
  inherit_mode:
    merge:
      - Exclude
  Exclude:
    - "app/graphql/generated/**/*"
```
**Files:** `lib/generators/graph_weaver/install_generator.rb`,
`spec/install_generator_spec.rb:266-271`.

### A8. `Transport::Faraday#url` misreports the endpoint for Array/Hash connection params

`transport/faraday.rb:82-86` encodes with `URI.encode_www_form`, which is not
Faraday's encoder. The method's own comment says "#url is what `graphql: :wire`
stubs and what the boot log line prints", so the wrong string is what the stub
is keyed on:
```
array        reported="?a=1&a=2"                       onwire="a%5B%5D=1&a%5B%5D=2"
nested hash  reported="?a=%7B%22b%22+%3D%3E+%22c%22%7D" onwire="a%5Bb%5D=c"
```
(the second is the Ruby `inspect` of a Hash, in a query string). The `:wire`
stub then misses, and WebMock's re-parse collapses `fields=a&fields=b` to
`fields=b` — wrong twice. Symbols, integers, nil and escaping are all fine.
**Fix:** `connection.build_exclusive_url(nil, connection.params)` — byte-identical
to the wire in every case tested, including the two the existing
`spec/faraday_spec.rb:134-154` pins.
**Files:** `lib/graph_weaver/transport/faraday.rb`.

### C6. A non-String header value escapes as a bare `NoMethodError` from net/http

`transport/http.rb:106-111` resolves callables and drops `nil`, and passes
everything else through: `X-Int → NoMethodError: undefined method 'strip' for an
instance of Integer`. Nothing names graph_weaver, the header, or the value. Not a
transport divergence — Faraday raises identically.
**Fix:** `[name, value.to_s]`, or an `ArgumentError` naming the header.
**Files:** `lib/graph_weaver/transport/http.rb`.

### D6. Minor
- **A multi-document `.rubocop.yml` makes the append a silent no-op** (the block
  lands in the second document; RuboCop reads only the first).
- **A prebuilt `Faraday::Connection` never gets graph_weaver's `User-Agent`** —
  `Faraday::Connection#initialize` pre-fills `user_agent`, so `post`'s `||=`
  never fires and the traffic attributes to `Faraday v2.14.3`. The comment says
  "a prebuilt connection owns its headers", so this may be intended; the UA's
  stated purpose (`transport.rb:36-40`) says otherwise.

**Cleared here** (don't re-run): **callable headers are resolved per request,
not per connection** — 5 requests over 1 socket produced 5 distinct tokens, and
`Retry` re-resolves on every attempt, so there is no stale-token bug;
**duplicate response headers don't diverge** — net/http and Faraday both join
repeats with `", "`, identically; **`GraphWeaver.configure`** survives
re-entrancy, double calls, nesting, unknown keys, nil-restores-default, a raise
inside the block, calls after graphs are declared, and 20x8 concurrent
`generated_paths <<` with nothing lost; **the generator's append is idempotent**
and produces parseable, duplicate-key-free YAML against no-trailing-newline,
empty, CRLF, `---`-marker, commented-`AllCops`, and symlinked configs.

---

# Railtie, Zeitwerk, and the host seam
*(driven from the throwaway Rails app at `/tmp/claude/graph_weaver/dogfood-rails-railtie`, as CLAUDE.md prescribes — the gem's own suite is structurally blind to all of this)*

### A9. A graph output nested two levels under a `generated_paths` glob is silently never ignored **and** never loaded

`Internal::Util.generated_dirs` (`internal.rb:122`) decides an output is
"already covered" with `File.fnmatch?` and **no `FNM_PATHNAME`**, where `*`
crosses `/`. Zeitwerk and `load_generated!` expand the same pattern with
`Dir.glob`, where it does not. So `app/graphql/a/b/generated` is dropped from
`extra` as covered by the default `app/graphql/*/generated` — and is then
neither ignored by Zeitwerk nor globbed for loading. Independently verified:
```
~/.rvm/wrappers/ruby-3.4.9/ruby -e 'puts File.fnmatch?("/r/app/graphql/*/generated", "/r/app/graphql/a/b/generated").inspect'
true
# with File::FNM_PATHNAME -> false, which is what Dir.glob does
```
End to end, graph declared in `config/initializers` (the blessed place),
production boot:
```
cd /tmp/claude/graph_weaver/dogfood-rails-railtie
GW_PROBE=nested SECRET_KEY_BASE=x RAILS_ENV=production \
  ~/.rvm/wrappers/ruby-3.4.9/bundle exec rails runner 'puts "BOOT OK"'
```
```
expected file .../app/graphql/a/b/generated/invoices_query.rb to define constant
A::B::Generated::InvoicesQuery, but didn't (Zeitwerk::NameError)
loaded 4 generated module(s) from app/graphql/generated, app/graphql/*/generated
```
Two tells: the error names a constant the user never wrote, and the log line
omits the graph's output entirely — so it is missing in development too, where
nothing eager-loads and nothing complains. No refusal fires. A realistic shape
is `app/graphql/subgraphs/billing/generated`.

**Fix (one line):** `File.fnmatch?(..., File::FNM_PATHNAME)` at
`internal.rb:122`. Patched into the app, the same command prints `BOOT OK`.
**Files:** `lib/graph_weaver/internal.rb`.

### A10. A symlinked output — or a symlinked ancestor of an absolute one — defeats both the ignore and the refusal

`Util.resolve` is `File.expand_path`, which does not resolve symlinks
(verified at `internal.rb:83`). Zeitwerk walks real directories, so ignoring the
symlink's path hides nothing; and `check_generated_ignored!`'s
`dir.start_with?("#{root}/")` compares the unresolved path against real autoload
roots, so **the refusal that exists precisely to catch this doesn't fire**:
```
GW_PROBE=symlink SECRET_KEY_BASE=x RAILS_ENV=production ... rails runner 'puts "BOOT OK"'
uninitialized constant Billing::InvoicesQuery (NameError)
```
Same failure for an absolute output that merely *passes through* a symlink —
the Capistrano `current/ → releases/<ts>/` shape. And declaring the graph from
`to_prepare`, where a refusal is mandatory, still slips through silently, while
the identical non-symlinked path refuses correctly.
`lib/graph_weaver.rb:695-698` already knows about this exact divergence in
`reload_generated!`. `rake zeitwerk:check` does catch it, which is the only
reason this isn't ranked first.
**Fix (one line):** `File.realpath` when the path exists, in
`Internal::Util.resolve`. Patched in, the initializer case boots and the
`to_prepare` case produces the intended `GraphWeaver::Error`.
**Files:** `lib/graph_weaver/internal.rb`.

All the *other* spellings in the brief are fine — `expand_path` normalizes them.
Confirmed boot-OK and correctly ignored: trailing slash, `..`, `Pathname`,
`Rails.root.join(...)`, absolute, `./`-prefixed, and an output that *is* an
autoload root.

### C7. An output under `autoload_once_paths` gets advice that provably cannot work

Rails sets the `once` autoloader up in **bootstrap**, long before
`:load_config_initializers`, so `graph_weaver.ignore_generated` (which runs
`after:` that) can never hide anything from it. The error tells you to "name it
in `GraphWeaver.generated_paths` from `config/initializers`"; doing exactly that
produces byte-identical output.
**Fix:** detect an output under `config.autoload_once_paths` and say what
actually works. **Files:** `lib/graph_weaver/railtie.rb`, `lib/graph_weaver.rb:646`.

### C8. False-positive refusal when the app has already ignored the directory itself

`check_generated_ignored!` consults only graph_weaver's own `ignored_dirs`,
never Zeitwerk. An app that called `Rails.autoloaders.main.ignore(...)` first is
still refused, and told something untrue ("it can't be hidden from
autoloading"). It is hidden.
**Fix:** `Rails.autoloaders.none? { |l| l.respond_to?(:ignores?) && l.ignores?(dir) }`
at `railtie.rb:104`. **Files:** `lib/graph_weaver/railtie.rb`.

### D7. `config.graph_weaver[:typo] = x` bypasses the refusal

`Options` refuses only through `method_missing`; `[]=` is inherited from `Hash`,
so `o[:nope] = 1` is the exact silent no-op the refusal exists to prevent,
through the other door. Nobody writes that form — one-line `[]=` override.

**Cleared here — hunt 1's railtie hunch is wrong.** The watch/ignore
initializers *do* see a `to_prepare`-declared graph: the app's `to_prepare`
block is registered during `:load_config_initializers` and graph_weaver's runs
`after:` it. The watcher's globs include the graph's queries path, and the
Zeitwerk half produces the intended refusal, not a silent NameError. The
railtie's design comments are accurate; the only hole is the symlink spelling
(A10). Also cleared: **`config.graph_weaver` vs OrderedOptions** — 44 protocol
calls probed (`to_h`, `key?`, `fetch`, `dig`, `[]`, `each`, `merge`, `dup`,
`Marshal`, `as_json`, `inspect`, `blank?`, `slice`, `symbolize_keys`,
`with_indifferent_access`, `Array()`, `config.respond_to?(:graph_weaver)`) — all
pass, and `respond_to_missing?` answering false keeps Ruby's implicit
conversions away from `method_missing`, so no third party's introspection trips
it; **the rake `:environment` seam** (generate/verify/graphs all behave,
including for a `to_prepare` graph; `verify` green, `generate` idempotent);
**`extend_type` from `to_prepare` reaches generated output**.

---

## Ranking, in one place

| # | harm | what | files |
|---|---|---|---|
| A1 | silent leak | typo'd filtered key prints its value | `hints.rb` |
| A2 | silent leak | server input-error `#message` unredacted | `internal/server_input.rb` |
| A3 | silent wrong | `STRUCT_METHODS` is load-order dependent; misses `deconstruct` and private `Kernel` | `codegen.rb` |
| A7 | silent wrong | install generator deletes the app's rubocop excludes | `install_generator.rb` |
| A9 | silent wrong | nested output never ignored **and** never loaded | `internal.rb` |
| A10 | silent wrong | symlinked output defeats ignore **and** refusal | `internal.rb` |
| A4 | silent wrong | registered scalar breaks documented `==` | `registry.rb`, docs |
| A5 | silent wrong | `to_h` leaks the live scalar object | `result_struct.rb` |
| A6 | silent wrong | YAML breaks `T::Enum` identity | `codegen/enum_type.rb` |
| A8 | silent wrong | Faraday `#url` misreports Array/Hash params | `transport/faraday.rb` |
| B1 | crash | `render json: e.to_h` 500s on NaN/Infinity | `coerce.rb` |
| C1 | misdirects | list index dropped for every list of leaves | `input_struct.rb` |
| C2 | misdirects | list-of-lists refuses with raw `NoMethodError` | `input_struct.rb` |
| C5 | crash | `respond_to?` true for names that don't exist | `hints.rb` |
| C6 | crash | non-String header → bare `NoMethodError` | `transport/http.rb` |
| C7 | misdirects | `autoload_once_paths` advice can't work | `railtie.rb` |
| C8 | misdirects | false-positive refusal when the app already ignored | `railtie.rb` |
| C3 | misdirects | `coordinate` names a slot that doesn't exist | `internal/server_input.rb` |
| C4 | misdirects | `@oneOf` with one null field | `input_struct.rb` |
| D* | paper cuts | see above | various |

**Partitioning:** the four clusters touch disjoint files —
input errors (`hints.rb`, `coerce.rb`, `input_struct.rb`, `internal/server_input.rb`) ·
codegen/structs (`codegen.rb`, `result_struct.rb`, `codegen/enum_type.rb`, `codegen/registry.rb`) ·
host seam (`internal.rb`, `railtie.rb`) ·
transport/generator (`transport/*.rb`, `install_generator.rb`).
`hints.rb` is the only file two clusters want (A1 and C5) — a small, real
conflict worth sequencing.

---

## Hunches, resolved

- **Non-atomic `||=` lazy init of process globals — downgrade, don't spend on
  it.** 160,000 forced first-touch races across 8 threads on CRuby 3.4 lost
  **zero** writes (`hunt2-race2.rb`; a second shape, `hunt2-race.rb`, 100×16×200
  pushes, also zero). CRuby gives no yield point between the ivar read and the
  write. It would be real on JRuby/TruffleRuby; nothing here says it is real on
  the runtime this gem targets. Evidence says leave it.
- **The round-trip `legacy_invalid` query — cleared as a correctness bug,
  confirmed as an upgrade break.** Isolated in 8 lines
  (`hunt2-probe5.rb`): an aliased field with different leaf types under one
  response key across two inline fragments —
  `... on Person { v: id }` / `... on Pet { v: name }`. graphql-ruby 2.6.10
  warns; codegen generates per-possible-type structs, so `Person#v` and `Pet#v`
  never collide and nothing is wrong today. What *is* real: when graphql-ruby
  makes this a hard error, `GraphWeaver.parse` starts refusing documents that
  work today, **and the repo's own fuzzer drafts them** — so the graphql-ruby
  bump breaks `bin/round-trip` before it breaks a user. Cheap prophylactic:
  teach the fuzzer in `spec/support/round_trip.rb` not to alias different leaf
  types onto one response key across union members.

---

## What I tried that turned up nothing (evidence too)

- **Client-side redaction is solid.** Symbol keys, String keys, Regexp filters,
  a filtered key nested under a list index (`["many", 2, "password"]`), and a
  filtered variable name all scrub both `#message` and `#value`
  (`hunt2-probe2.rb` sections A–C). This is why A1/A2 are findings rather than
  "redaction is weak": the design is right and two spots miss it.
- **`path` through input objects and input-object lists is correct** at every
  depth I could construct: `["where","_and",0,"_not","species"]`,
  `["where","_and",3,"species"]`, `["many",2,"password"]`, nil and non-Hash
  elements, a list where a hash was expected, a bare String for an input object.
- **Hostile `extensions.input` is handled.** An unknown `kind` falls back to
  `:refused`; a non-Array `path` falls back to the error's own path; junk detail
  keys are dropped; a 2 MB `value` passes through without incident.
- **The `TypeError`/`ValidationError` renames are clean.** No reachable
  `GraphWeaver::TypeError` or `GraphWeaver::ValidationError` anywhere in `lib/`,
  `docs/`, `examples/`, `spec/generated/` or the generator templates — the only
  hits are `docs/upgrading.md` (documenting the rename) and historical
  `CHANGELOG` entries.
- **I did not diff `--hostile` messages against v0.6.1.** It needs a second
  worktree, which the brief's read-only/no-state-change constraint rules out.
  Unexamined, not cleared.
- **The hunt-1 fuzzer was not re-runnable.** `/tmp/claude/graph_weaver/hunt-fuzz/`
  holds 142 numbered one-off probes and no driver. I substituted the widened
  `bin/round-trip` runs in the table above.

### The harness's blind spot (why the 40k clean round trips prove less than they look like)

`--hostile` spoils **response** leaves (`spec/support/round_trip.rb:528-550`) and
checks the response-side refusal. The input side round-trips *legal* drafted
values only. Nothing in the harness feeds a bad input value and asks whether the
resulting `InputError` describes it correctly — which is exactly where C1–C4
live. 40,000 green round trips are strong evidence about response decoding and
close to no evidence about input-error quality. If one thing gets built from
this report, it should be an input-side `--hostile`.
