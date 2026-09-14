# Mutation testing pass — graph_weaver

Branch `worktree-agent-aea52b1e34abc8cce`, rebased onto main **e800bfa**.
The mutation runs were taken at the lane's original baseline, main **4fd16d2**;
the one re-run for "after" numbers (§2) was taken after the rebase, which is
why two of its subjects have more mutants than they did before.

## 1. Did mutant run? Yes — after fixing the selection that made it lie

`mutant` 0.16.3 + `mutant-rspec` 0.16.3 on Ruby 3.4.9.

- **Ruby 3.4**: `required_ruby_version >= 3.3`, so supported. Its `parser ~>
  3.3.10` dependency prints one warning per run (`parser/current is loading
  parser/ruby34 … you are running 3.4.9`) and is otherwise fine. Its
  `sorbet-runtime ~> 0.6.0` is satisfied by the lock's 0.6.13485.
- **Licence**: mutant is **not** open source — `licenses: ["Nonstandard"]`, and
  the shipped `LICENSE` is a proprietary EULA (Schirp DSO LTD, Malta). Since
  0.12 the separate `mutant-license` gem is gone ("License gem is gone
  entirely"); the usage type is declared in config instead. The **Free Project
  License** covers "any of your projects that are released under an Open Source
  License that is hosted on a public source code repository" — graph_weaver is
  MIT on github.com/dpep/graph_weaver, so `usage: opensource` in `.mutant.yml`
  is the correct, free declaration. It lives in the Gemfile's `:development`
  group, not the gemspec: a proprietary tool has no business in a published
  gem's dependency list.
- **Sorbet was not an obstacle.** No `T::Configuration` switch was needed.
  (One caveat in §1.2.)

### 1.1 The obstacle that was real: mutant's test selection

mutant decides which examples to run against a mutation from the **first word
of each example's description**, parsed as a subject expression. Its grammar is
`fragment = /[A-Za-z][A-Za-z\d_]*/` — lowercase allowed — so `describe "input
errors"` parses as the namespace `input`, which matches no subject. All 992
lines of `spec/input_errors_spec.rb` therefore selected **nothing**, for any
subject.

The other half of the same bug is worse. `Selector::Expression` walks a
subject's match expressions most-specific-first and returns the first that
matches anything: `GraphWeaver::Coerce.integer`, then `GraphWeaver::Coerce*`,
then `GraphWeaver*`. With nothing tagged it fell through to `GraphWeaver*` and
selected the 965 examples of every unrelated `describe GraphWeaver::Foo` in the
suite — which cannot kill a Coerce mutant, but do take ~15s, which exceeds
mutant's default 5s mutation timeout. **A timeout counts as a kill.**

Evidence: the first pass over `GraphWeaver::Coerce` scored **100.00% coverage,
1083/1083 kills — 1023 of them timeouts.** Hand-applying one mutant it called
dead (`def integer(value, scalar = "Int")` → `scalar = ""`) and running
`bundle exec rspec spec/input_errors_spec.rb` failed at line 180. The tool was
calling a killed mutant alive and an unkilled one dead, in the same run.

Fix, in `spec/support/mutant.rb`, active only when `defined?(Mutant)`:

```ruby
config.define_derived_metadata { |metadata| metadata[:mutant_expression] ||= "GraphWeaver*" }
```

That states what is true of this suite — any spec can kill any mutant — and
makes selection 1792 of 1792 for every subject. Runs are narrowed by naming
spec files on the command line, not by an accident of prose. `.mutant.yml`
also raises `mutation.timeout` to 120s, so a timeout now means a mutation that
hangs rather than a suite the mutant is slow to fail.

**Every number below is a full-suite selection (all examples, every subject)
with a 120s timeout.** Roughly 3.4 hours of wall clock across 6107 mutations.

### 1.2 Two caveats left standing

- mutant re-evaluates only the `def` of a mutated method, without the `sig`
  above it, so on the `# typed: strict` subjects (`Response`, `InputError`) the
  mutated method is **unwrapped by sorbet-runtime**. A mutant that only a
  runtime sig would catch can show as alive there. Survivors on those subjects
  were read with that in mind.
- The per-subject `ALIVE` column of `mutant session subject` includes
  **timed-out** mutations, and a timeout is load-dependent. Treat ±1–2 per
  subject as noise; the survivor families below were each read from the diffs,
  not from the counts.

## 2. Score by subject

Mutation score = kills / mutations.

| subject | mutations | killed | survivors | score |
|---|---|---|---|---|
| `GraphWeaver::Coerce` | 1083 | 945 | 138 | **87.3%** |
| `GraphWeaver::InputStruct` | 703 | 631 | 72 | **89.8%** |
| `GraphWeaver::ResultStruct` | 119 | 113 | 6 | **95.0%** |
| `GraphWeaver::Response` | 117 | 111 | 6 | **94.9%** |
| `GraphWeaver::Hints` | 910 | 800 | 110 | **87.9%** |
| `GraphWeaver::Inflect` | 74 | 72 | 2 (both timeouts) | **97.3%** |
| `GraphWeaver::Retry` | 600 | 537 | 63 | **89.5%** |
| `GraphWeaver::Internal::Redact` | 167 | 154 | 13 | **92.2%** |
| `GraphWeaver::InputError` | 317 | 292 | 25 | **92.1%** |
| `GraphWeaver::Internal::ServerInput` | 1129 | 1088 | 41 | **96.4%** |
| **all ten** | **5219** | **4743** | **476** | **90.9%** |

Three significant figures: these are counts in the hundreds, so 87.3% is the
precision the numbers have and a further decimal would be invented.

### Killed after

Three subjects were re-run on the finished branch. The other seven were not
re-measured — each survivor family the new specs target was instead watched
failing with the mutant hand-applied (§4), which is the same evidence one
mutant at a time.

| subject | before | after | note |
|---|---|---|---|
| `ResultStruct` | 113/119 = 95.0% | 116/119 = **97.5%** | `#hash` 6 survivors → 0 |
| `Response` | 111/117 = 94.9% | 110/117 = **94.0%** | `#data!`'s three behavioural survivors are gone; the three that remain are all `GraphWeaver::QueryError` → `QueryError` constant-spelling equivalents. The headline moved the wrong way on timeout noise alone. |
| `Retry` | 537/600 = 89.5% | 626/652 = **96.0%** | 63 survivors → 26. (652 rather than 600 because main grew between the two runs.) |

Per-method survivor counts before, for the subjects with the most:

```
Coerce        cast 38/111  date 16/72  float 15/75  time 11/69  whole 8/64
              finite 8/39  time_like? 7/39  timestamp 6/53  id 5/27
              string 5/30  boolean 4/40  variable 4/186  integer 4/69
              refuse 3/32  cross 2/23  parsing 1/46  mismatch 1/22
InputStruct   .field 36/218  #one_of! 10/132  #serialize 10/146
              .included 5/10  .invalid_enum! 4/48  .element 3/60
              .enum 2/47  .mapped_enum 2/42
Hints         unquoted_keys 29/153  shape_drift 20/200  drifted_shape 14/97
              wire_kind 12/37  #prop_hint 11/83  mapped_enum 7/26
              cast_message 6/51  field 5/28  validate_keys! 4/159
              #method_missing 3/36  drifted! 2/9  enum 2/31
Retry         #execute 27/237  #initialize 14/156  #retryable_response? 11/61
              #delay 5/98  #mutation? 4/30  #url 2/18
ServerInput   .coded 12/131  .convention 11/118  .dig 10/54  (rest ≤1)
InputError    #json_safe 8/63  #within 6/38  #initialize 6/128  #field 4/36
```

## 3. A bug the pass found — `hints.rb`, NOT fixed (corpus lane owns the file)

`Hints.shape_drift`'s first line is meant to say "a null where null is allowed
is not drift":

```ruby
return if value.nil? && type.valid?(nil)
```

but `Hints.drifted_shape` (line 123) hands it `T::Utils.coerce(prop[:type])` —
the type with its nilable-ness **stripped**. `T::Utils.coerce(Pet).valid?(nil)`
is `false`, so the guard can never fire for exactly the case it was written for.
`InputStruct.mistyped` does the same job correctly, using `:type_object`
"because it carries the nilable-ness the prop was declared with".

Consequence: when any prop fails to cast and some *other* nullable object or
list prop is legitimately null, `drifted_shape` takes the **first** message it
finds and blames the innocent null field. Reproduction (watched failing):

```ruby
schema = GraphQL::Schema.from_definition("type Pet { name: String }\ntype Q { a: Pet, b: Pet }\nschema { query: Q }")
mod = GraphWeaver.parse(schema:, query: "query M { a { name } b { name } }")
mod.from_response!("data" => { "a" => nil, "b" => "oops" })
# GraphWeaver::CastError: … a: expected an object, but the server sent null
# wanted:                  … b: expected an object, but the server sent a string
```

Likely fix: `prop[:type_object]` in `drifted_shape` — but that widens what
`shape_drift` sees, so it wants the corpus lane's eye. I wrote the reproducing
example, watched it fail, and did **not** commit it: a red spec for a file I may
not edit is worse than a report. It is also why `shape_drift` has 20 survivors
— mutants 1–9 all sit on a guard that never fires.

## 4. Survivors, by outcome

### (1) Killed by a new spec — each watched failing with the mutant applied

| subject | what lived | the spec |
|---|---|---|
| `Coerce.*` | `mismatch(…, nil)` — `#details[:type]`, the key an app translates, dropped on five rules; and overwriting the caller's scalar with the rule's own, which is the documented `register_scalar("BigInt", Integer)` contract | `spec/builtin_coercion_spec.rb` "refuses under the schema's name for the scalar, whichever rule ran" |
| `Coerce.*` | the default `scalar =` on all seven rules (`"Int"` → `""`/`nil`/no default) | same file, "names the scalar it is the rule for when the caller gives none" |
| `Coerce.date/.time` | the whole `refuse` arm for a value of no temporal kind — never reached | covered by the first, via `Coerce.date(5, "Stamp")` |
| `Coerce.integer/.float` | `.strip` → `.lstrip`/`.rstrip`/nothing | same file, "reads a numeric string with whitespace around it" |
| `Coerce.timestamp` | the DateTime arm (`#sec_fraction`, where Time spells it `#subsec`) — no caller in the suite | same file, "serializes a DateTime as a timestamp, fraction and all" |
| `Coerce.cast` | `type.is_a?(Module)` — a scalar registered by type NAME hands it a `T::Types::TypedHash`, and without the guard every such registration raises "class or module required" at coercion | same file, "casts for a scalar registered by type name, which names no class" |
| `InputStruct.field` | the `e.field && !filtered?` branch: every mutant lived, `if false` included. Path and coordinate come out the same either way; only the message and `#value` tell them apart | `spec/input_errors_spec.rb` "keeps the innermost sentence, and the value at the end of the path" |
| `InputStruct#one_of!` | `struct:` dropped on both @oneOf arms | same file, extended "says which @oneOf field was null…" |
| `ResultStruct#hash` | `[self.class].hash` — a legal `#hash` that puts every result of a query in one bucket | `spec/result_struct_spec.rb` "hashes by the props, not by the class" |
| `Response#data!` | partial data and extensions dropped from the raised `QueryError`, which the docs promise | `spec/error_handling_spec.rb` "hands the partial data and the extensions to the error data! raises" |
| `Response#data!` | the "response carried neither data nor errors" sentence, and its extensions — only the class was ever asserted | same file, extended "raises QueryError (not a bare TypeError)…" |
| `Hints.wire_kind` | three of six arms never ran: a list, a number, a boolean and the Ruby fallback could all return nil | `spec/hints_spec.rb` "names what arrived in the wire's vocabulary, whatever it was" |
| `Hints.shape_drift` | `filter_map` → `map` in the list walk: a drift past element 0 hides behind the nil a good element returns | `spec/hints_spec.rb` "names the index of the element that drifted, not only the first" |
| `Hints.mapped_enum` | the drift arm had no caller — a `register_enum` map missing a wire value could raise `Hash#fetch`'s bare KeyError | `spec/registry_spec.rb` "says which wire value the map has no entry for, and what to do" |
| `Hints.unquoted_keys` | the `type.valid?("")` narrowing — the widest mutant turns every wrong-typed leaf into "the server is out of spec" | `spec/builtin_coercion_spec.rb` "accuses the server only over the props a String passes through" |
| `Hints#prop_hint` | the `if suggestion` guard — "did you mean ''?" for every unknown method | `spec/hints_spec.rb` "leaves a name that resembles no prop to Ruby's own NoMethodError" |
| `Retry#execute` | 19 of its 27 survivors were the info line the retry writes — "a retry is invisible otherwise", and so was its wording, down to rounding the delay where it is built | `spec/retry_spec.rb` "logs which attempt it is retrying, and how long it is waiting" |
| `Retry#execute` | the variables never reached an assertion — only the operation name did | same file, extended "carries the operation name and the variables down…" |
| `Retry#retryable_response?` | `\|\| []`, `dig`, and `intersect?` all lived: every `retry_codes:` example fed it an error that had a code, so a clean answer (NoMethodError), an error with no extensions (KeyError) and "retry everything" all passed | same file, "leaves a response alone when its codes aren't the ones listed" |
| `InputError#json_safe` | the Array arm and the finite-Float arm: nothing read a finite Float back, and the nested example used a Hash | `spec/input_errors_spec.rb` "leaves a finite number alone inside a list, and rewrites the one beside it" |
| `ServerInput.coded` | `value: extensions["value"]` — every coded-error example asserted kind, path and coordinate and stopped | same file, "carries the value a coded error echoed back" |

One further example kills nothing and earns its place anyway:
`spec/input_errors_spec.rb` "lists an enum's accepted values alphabetically,
however the schema wrote them". `invalid_enum!`'s own `.sort` turns out to be
defensive — the emitter already writes enum members alphabetically (verified:
`enum Sp { DOG CAT BIRD }` generates `Bird, Cat, Dog`) — so those two mutants
are equivalent. The order is still what an app renders to a user, and nothing
said so.

### (2) Equivalent mutants

- **Constant spelling** (~25, across `Coerce.variable`, `.refuse`, `.cross`,
  `InputStruct.field`/`.element`/`.invalid_enum!`/`#one_of!`, `Response#data!`,
  `Hints.field`/`#prop_hint`, `InputError#json_safe`): `GraphWeaver::InputError`
  → `InputError`, `Internal::Refusal` → `GraphWeaver::Internal::Refusal`,
  `::TypeError` → `TypeError`. Same constant resolved from inside
  `module GraphWeaver`. This is the single largest survivor family in the whole
  pass and it is pure noise.
- **`"#{e}"` vs `e.message`** (`Coerce.variable` ×2, `InputStruct.field`,
  `Hints.field`): `Exception#to_s` *is* `#message`.
- **`T.unsafe(self.class)` → `self.class`** (`Hints#prop_hint` ×2): `T.unsafe`
  is a runtime no-op.
- **`Coerce.parsing(scalar, value)` → `parsing(scalar)` from `.date`/`.time`**:
  the `value` argument is only read in the `TypeError` branch, and from those
  two rules the block only ever gets a String, which `Date.iso8601` /
  `Time.parse` reject with `ArgumentError`. Reachable only through `.cast`,
  which does pass it.
- **`ResultStruct#hash` `[klass, values]` and `[klass, *hash]`**: a hash
  function's exact value is not API — only that equal objects hash equally and
  unequal ones usually don't, which the new example pins.
- **`InputStruct#one_of!` `.find {…}` → `.first {…}`, and `candidate.wire ==
  name` → `name`**: that arm runs only under `wire.size == 1`, where find and
  first are the same element.
- **`InputStruct.enum` / `.mapped_enum` `is_a?` → `instance_of?`**: `T::Enum`
  members are instances of the enum class itself.
- **`InputStruct.invalid_enum!` `values.sort` ×2**: the emitter sorts (above).
- **`Hints#prop_hint` `prop != name` ×4**: `method_missing` only fires for a
  name the object does *not* answer, so `prop == name && method_defined?(prop)`
  is unreachable. Defensive, not live.
- **`Retry#mutation?` `@retries.positive?` ×3**: with `retries: 0` the two
  branches of `attempts = mutation? ? 1 : @retries + 1` are both 1, and the
  MUTATION_HINT log has its own `.positive?` guard.
- **`Retry#execute` `attempt >= attempts` → `attempt.equal?(attempts)`**:
  `attempt` increases by exactly one.
- **`Redact.filtered?` `!key.nil?` → `!false`, and `== FILTERED` dropped**: the
  guard only saves a `nil.to_s` lookup that answers the same way, and the
  predicate is only ever read for truth.
- **`Coerce.time_like?` conjunct mutants (6)**: telling `respond_to?(:acts_like?)
  && acts_like?(:time) && respond_to?(:to_time)` apart from its weakenings needs
  an object that answers Rails' duck-type checks inconsistently *and* is not
  already caught by the `when Date/Time/DateTime` arms above it. Contrived, so
  recorded here per the brief's own rule.
- **`Coerce.cast`'s widened DateTime guard (mutants 26–32)**: dropping
  `type.equal?(::Date)` from `type.equal?(::Date) && value.is_a?(::DateTime)`.
  Distinguishable only by a registration whose Ruby type is *not* Date being
  handed a DateTime, where both paths refuse and only the sentence differs.
  `Date` vs `::Date` and `DateTime` vs `::DateTime` are equivalent outright.

### (3) Dead or unreachable code — reported, not deleted

| where | line | evidence |
|---|---|---|
| `lib/graph_weaver/input_struct.rb` | 110–112, `def self.included(base); base.extend(ClassMethods); end` | **Dead.** `codegen/emit.rb:633` emits `extend GraphWeaver::InputStruct::ClassMethods` next to every `include`, so the hook never has work to do. Replacing its body with `nil` leaves the **whole suite green** (1782 examples at the time). Both lines arrived in the same commit (`c1f41ab`), so this is duplication by design rather than a leftover — and `GraphWeaver::InputStruct.included` is in `spec/support/public_surface.txt`, so removing it is an API decision. Left in place; the coordinator has since assigned this file to another lane. Two ways to close it: delete the hook and its surface entry, or keep it and pin the include contract with a spec. |
| `lib/graph_weaver/coerce.rb` | 127, `scalar ||= type.is_a?(Module) ? type.name : type.to_s` | **Unreachable.** `Coerce.cast`'s only caller is `codegen/scalar_type.rb:163`, which always passes `#{@graphql_name.inspect}` — a String literal — so `scalar` is never nil. All 24 mutants of this expression live, `nil` included. Corpus lane owns `coerce.rb`: report only. |
| `lib/graph_weaver/input_struct.rb` | 48, `def self.element(index, value = nil)` | The `= nil` default is unreachable: generated code always passes the element. Minor. |
| `lib/graph_weaver/hints.rb` | 133, `return if value.nil? && type.valid?(nil)` | **Never fires** — see §3. A bug, not merely dead code. Corpus lane owns `hints.rb`. |

### Survivors read but left open

`Hints.drifted_shape` (14), `Hints.cast_message` (6), `Hints#method_missing`
(3), `Hints.validate_keys!` (4), `InputStruct#serialize` (10), the rest of
`InputStruct.field` (~20), `Retry#initialize` (14) and `#delay` (5),
`ServerInput.convention` (11) and `.dig` (10), `Redact.cap` (4). They are the
same two families as everything above: an unasserted message, and an unasserted
`#details`/`#struct`/`#value`. Two worth naming:

- **`ServerInput.dig`'s `when Array` arm** (10 survivors) is entirely
  unexercised: no spec has a server echo back a variable containing a **list**
  with a problem path into it, so `#value` for a list element is never read.
- **`Redact.cap`** never has its *content* checked, only its length and its
  "…(N more bytes)" suffix — `byteslice(1, limit)` and `scrub(nil)` both live.

One stale comment noticed in passing: `Hints.validate_keys!`'s docstring
promises `"use …"` for an exact wire-cased mapping, but the code writes
`"did you mean …?"` on both branches (`hints.rb:16–17` vs `:35`).

## 5. Housekeeping

- **Files touched**: `Gemfile`, `Gemfile.lock`, `.gitignore` (`.mutant/`),
  `.mutant.yml`, `spec/support/mutant.rb`, `CLAUDE.md` (one paragraph on how to
  run it), and seven spec files. **Nothing under `lib/`** — every hand-applied
  mutant was reverted and `git diff lib/` is empty. In particular
  `lib/graph_weaver/result_struct.rb` and `lib/graph_weaver/input_struct.rb`
  are untouched, per the coordinator's ownership change.
- **No `CHANGELOG.md` entry**: nothing user-visible changed, so the lane marker
  `<!-- lane: mutant -->` was not added either.
- **Gate**, each its own command, before every commit: `bundle exec rspec`,
  `bundle exec srb tc`, `bundle exec ruby bin/generate` (tree clean). After the
  rebase onto e800bfa: 1848 examples / 0 failures, `--order rand:1` and
  `--order rand:4242` both green, srb clean, `bin/generate` "already up to
  date", and `BUNDLE_FROZEN=true bundle install` complete.

### Shas (rebased onto e800bfa)

```
82c96bc  Add mutation testing, and fix the selection that made it lie
240822d  Spec what Coerce's refusals actually say
11ff3dd  Spec what a nested input refusal carries out with it
5395968  Say how to run the mutation pass
3afac34  Spec the sentences a drifted response gets told
226b7ea  Keep the out-of-spec accusation off the props that cast
4bfd121  Leave a name that resembles nothing to Ruby
fdf4d2f  Name the drifted element wherever it is in the list
66c3c1f  Read back the retry log line, and the responses retry_codes: ignores
955b678  Read back the two values nothing was reading
```
