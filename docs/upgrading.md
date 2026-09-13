# Upgrading

[Regenerate](#regenerate-on-every-upgrade) whichever version you're on, then
read the one section that is yours: from [0.6.1](#upgrading-from-061), from
[0.5.1](#upgrading-from-051), or [to 0.5.0](#upgrading-to-050) from anything
older.

## Regenerate on every upgrade

**Any release can change what codegen emits.** Patch releases included — most of
them are fixes to a generated type, and a fix to a type is a change to the bytes.
0.5.1 was a patch and moved three of them.

So `rake graph_weaver:generate` is part of upgrading the gem, every time, and
`rake graph_weaver:verify` is the detector: it fails when the checked-in Ruby
isn't what this version would write. Nothing beyond that is promised — there is
no "generated output is stable within a minor" rule to lean on. What each release
changed, and whether it needs a regenerate, is in the changelog.

A generated file's header names the release that wrote it, so the first `verify`
after an upgrade reports the tree as stale whether or not codegen actually
moved. That's the reminder working, not a false alarm.

Generation is deterministic, so the diff is exactly what the new version emits
differently and nothing else — worth reading rather than rubber-stamping.

## Upgrading from 0.6.1

Mostly mechanical. Everything that wants your hands, or changes under you, is
one row below; read the left column and skip what isn't yours. A typical app
ticks two or three.

| applies if you… | what changed |
|---|---|
| run a Rails app that configures no logger or instrumenter | **you start logging one info line per GraphQL call** — a production log-volume change, [first bullet below](#behavior-that-changed-under-you) |
| commit a schema dump introspected through a url carrying a token | **refresh it, and rotate the token if that file was pushed** — the dump recorded the url verbatim |
| keep a schema dump deliberately behind your own schema class | `verify` fails on it now |
| use `@oneOf` input types and commit a `.json` dump | `@oneOf` starts being enforced client-side once you regenerate |
| call `result.to_json`, or `render json: result` | it is the wire shape now, not `#inspect` or your prop names |
| pin a lowercase type name in `graphql_fake` | it works now; a near-miss *keyword* raises `ArgumentError` |
| tag specs `graphql: false`, or set `config.default_mode = nil` | both refused — [renames](#renames) |
| `rescue GraphWeaver::TypeError` or `GraphWeaver::ValidationError` | both constants are gone, with no alias — [renames](#renames) |
| subscribe to `"graph_weaver.execute"` | the event is `"execute.graph_weaver"` — [renames](#renames) |
| index a hash by an `InputError`'s `#field` | it names the input field now, not the variable — **nothing raises** |
| read an `InputError`'s `#details[:type]` | it is the GraphQL type now, never a Ruby class — **nothing raises** |
| read `payload[:status]` in an instrumentation subscriber | it is a Symbol; the HTTP status moved to `:http_status` — **nothing raises** |
| call `respond_to?` on a result struct | it stopped answering true for props that don't exist — **nothing raises** |
| generate a module with a baked `client:` | a `graphql:` tag now reaches it |
| set `config.context`, `config.schema` or `config.router` from a `before` hook | all three refused — they are suite setup |
| pass a `DateTime` where the schema says `Date` | refused — pass `.to_date` |
| register a scalar with your own `cast:`/`serialize:` | the same guard as the built-ins, and a proc that returns a value is refused |
| have a field named `class`, `hash`, `display`, `to_json`, `each` or `supplied` | the prop takes a trailing underscore |
| adopt `GraphWeaver.graph` | every queries directory then needs one |
| write `config.graph_weaver.<anything but watch>` | refused at boot |
| pass `seed:` to `graphql_router(fake: …)` | refused |
| require `graph_weaver/rspec` from `spec/support/` | check the glob is uncommented — rspec-rails ships it commented out |
| adopt `graphql: :wire` | it needs `require "webmock/rspec"`, not just the gem |

Then five commands, in order:

```sh
# 1. the two renames your own code holds
grep -rn "GraphWeaver::TypeError\|GraphWeaver::ValidationError" app lib spec
grep -rn "graph_weaver.execute" app lib config spec   # the old event name

# 2. rewrite the dump: it drops a credential the url carried, and picks up
#    isOneOf. Skip only if your dump is SDL and records no source url.
rake graph_weaver:schema:refresh

# 3. regenerate — also the graph name in every module, the underscored
#    reserved props, as_json, and the client: and cast:/serialize: refusals
rake graph_weaver:generate

# 4. the renamed tag, the deleted nil, the seed: refusal
bundle exec rspec

# 5. the gate: red while any checked-in file is still what 0.6.1 wrote
rake graph_weaver:verify
```

**Two kinds of file answer that first grep, and only one needs your hands.**
Hits under your generated directory (`app/graphql/generated/` by default) are the
old names in machine-written code — step 3 rewrites them. Hits anywhere else are
yours: `CastError` and `QueryValidationError`, renamed by hand.

### Renames

| before | after |
|---|---|
| `graphql: false` (rspec tag) | `graphql: :live` — the opt-out is your own client, which is a mode like the other four; `false` is refused, naming it |
| `config.default_mode = nil` | `config.default_mode = :live`, which is now the **default** — every example has exactly one mode, and `nil` is no longer a value it reads back |
| `GraphWeaver::TypeError` | `GraphWeaver::CastError` — the response wouldn't cast into the generated structs; the old name shadowed a core class it doesn't descend from. No alias: the old constant is gone, so a stale `rescue` is a `NameError` |
| `GraphWeaver::ValidationError` | `GraphWeaver::QueryValidationError` — build time, the *query* against the schema. Your input's validation is `InputError`. No alias here either |
| `"graph_weaver.execute"` | `"execute.graph_weaver"` — `<event>.<namespace>`, the way every notification in this ecosystem is spelled, and what `LogSubscriber.attach_to` and an APM's namespace routing key on. Subscribe through `GraphWeaver::EXECUTE_EVENT` and there is nothing to rename; a hardcoded string silently stops matching |

### Behavior that changed under you

The first one reaches every Rails app that never configured logging, and it is
the only one here that shows up in production rather than in your code.

- **A Rails app logs one line per GraphQL call, and emits one notification.**
  The railtie now sets `GraphWeaver.instrumenter` to the
  `ActiveSupport::Notifications` adapter and attaches
  `GraphWeaver::LogSubscriber`, so an app that configured neither gets
  `GraphWeaver billing/InvoicesQuery (12.3ms) ok` at **info** — one line per
  operation, carrying nothing that can hold PII; the query and variables stay
  at debug. An instrumenter you set yourself is never replaced, and **to opt
  out, set `GraphWeaver.logger = nil` or `GraphWeaver.instrumenter = nil` in
  `config/initializers`** — which now takes effect, so an app that worked
  around it with `config.after_initialize { GraphWeaver.logger = nil }` can
  drop that. In-process calls are in scope too: a bare schema class in a client
  slot (`GraphWeaver.client = MyApp::Schema`, `execute!(client: MyApp::Schema)`,
  a graph's `client "Billing::Schema"`) goes through the same wrapper
  `GraphWeaver.new(MyApp::Schema)` always used, so it produces events and log
  lines where it produced none. See [logging](logging.md).
- **`InputError#field` names the input field, not the variable.** It is now
  `#path`'s last *named* segment — the slot that actually held the bad value,
  which is the one a form highlights — where it used to be re-branded on the
  way out with the *variable* name. Nothing raises; the value just differs once
  a refusal happens inside an input object. **Read `error.path.first` wherever
  you wanted the variable**, and `#field` wherever you wanted the field. On a
  refusal that never got past the variable the two are the same, which is why
  this can pass unnoticed until the first nested input fails. An index is a
  position rather than a field, so it never becomes one: `execute(ids: [1, 2,
  "x"])` reports `#path` `["ids", 2]` and `#field` `"ids"`. **Self-check:**
  `grep -rn "\.field" app lib` — every hit that indexes or compares an
  `InputError`'s `#field` is a place to decide which of the two you meant.
- **The instrumentation payload's `:status` is a Symbol, and the HTTP status
  moved to `:http_status`.** `:status` is now `:ok`, `:errors` (the response
  came back carrying GraphQL errors) or `:failed` (it raised) — a 200 carrying
  errors is not a success, and only a symbol says that on both sides of the
  seam. Nothing raises: a subscriber comparing it to an Integer just stops
  matching. **A subscriber that branched on `payload[:status] == 200`, or on a
  4xx/5xx, reads `:http_status` now** — which is nil in-process, where
  `:status` used to be a fabricated 200 so one subscriber could read both
  sides. The whole payload is a documented contract now; see
  [logging](logging.md#the-payload). **Self-check:** nothing subscribing to
  `execute.graph_weaver` means nothing to change — this reaches subscribers
  only.
- **`respond_to?` on a result struct no longer answers true for a name that
  doesn't exist.** It used to say true for any near miss, which broke the
  standard duck-typing guard — `obj.pet if obj.respond_to?(:pet)` raised the
  very `NoMethodError` the hint exists to explain. **A branch that read the old
  answer now takes the other path**, and `struct.method(:nmae)` raises Ruby's
  bare `NameError` rather than a hinted one; `struct.nmae` still hints.
- **A `graphql:` tag reaches a module generated with `client:`.** The baked
  client used to sit above the slot a tag swaps, so a bound module ran against
  its real endpoint under `graphql: :fake`. **If a spec relied on that**, it now
  runs against the fake — pass `client:` on the call, set `MyQuery.client =`, or
  tag the example `graphql: :live`.
- **`config.context`, `config.schema` and `config.router` are suite setup.**
  Setting any of the three once an example is running refuses, naming the
  per-example helper (`graphql_context`, `graphql_fake(schema:)`,
  `graphql_router(fake:)`). The tag builds an example's clients in a `before`
  hook of its own, which rspec runs ahead of any group `before`, so a set there
  was read too late and silently changed nothing — a `config.context` that
  never reached a resolver, a `config.schema` the fake never saw. The refusal
  replaces a line that wasn't working. **Move it to an `around`, or to
  `GraphWeaver::Testing.configure` in the spec helper**; `configure` and
  `around` are unchanged.
- **`result.to_json` is real JSON, and it is the wire shape.** It used to be
  Ruby's `Object#to_json` — the `#inspect` string, quoted — so a log line or a
  cache write stored nothing, with no exception and no warning; under Rails
  `render json: result` instead shipped the *Ruby* prop names, trailing
  underscores included. Both now produce the response keys, each leaf back
  through its scalar registration's `serialize:`, so
  `Result.from_h(JSON.parse(result.to_json)) == result`. `#to_h` is unchanged
  and still the Ruby view. **Anything that parsed the old output, or diffed a
  cached copy of it, is reading something different now** — and `as_json` is
  emitted code, so a struct generated by 0.6.1 raises `GraphWeaver::Error`
  naming this until you regenerate.
- **A schema dump introspected through a credentialed url still holds the
  token.** The provenance stamp wrote the transport's url verbatim, so a url
  carrying userinfo or an `?access_token=` landed in a file that gets
  committed. It records the endpoint bare now — userinfo and any query
  parameter `filter_parameters` filters are dropped — and re-introspection
  still authenticates from the dump's `auth_env`. **Run `rake
  graph_weaver:schema:refresh` once, and rotate the token if that file was ever
  pushed.**
- **`verify` fails when the dump has fallen behind the schema class it was
  built from.** For an app that serves its own schema the dump is an artifact
  derived from code in the same repo, and everything downstream reads it, so
  `generate` and `verify` both called a tree up to date while the live
  resolvers had already moved. **A dump you deliberately keep behind your own
  schema is a red gate now** — `rake graph_weaver:schema:refresh`, or ask about
  no dump at all with `verify_generated!(schema:)`. It costs one in-process
  introspection per graph and never a network call.
- **`@oneOf` starts being enforced if your dump is `.json`.** graphql-ruby's
  introspection query omits `isOneOf` unless asked, and its loader drops the
  field even when it is there, so every dump this gem has written said "not
  @oneOf" for every input object and the enforcing struct was never generated.
  **Regenerate (`rake graph_weaver:schema:refresh && rake
  graph_weaver:generate`) and the emitted `ONE_OF` starts refusing calls that
  set two fields** — which your server was refusing all along, so the failure
  moves from the wire into `execute`. SDL dumps, inline SDL and a live class
  were always correct.
- **A fake pin is told from an option by a schema lookup, not by casing.** The
  rule was "a dot or a leading capital is a pin", so a lowercase type could not
  be pinned at all: `graphql_fake("pokemon_v2_pokemon" => …)` against a Hasura
  API came back as `a fake doesn't take pokemon_v2_pokemon:`. Those pins work
  now. The other side of it: **a keyword that is a near-miss for a pin
  (`Persn: "Ada"`) raises `ArgumentError` from the fake** rather than
  `GraphWeaver::Error` from the override check — the same key written in the
  leading positional hash is unchanged, and is the spelling for a schema whose
  vocabulary collides with an option name.
- **Regenerate**, as ever — generated modules carry a private `GRAPH` naming the
  graph they were generated from, and a [multi-schema](getting_started.md#more-than-one-schema)
  app whose modules predate it refuses rather than guessing which schema a
  module belongs to. A generated `execute` also makes its request through the
  gem now (`from_response(dispatch(variables, client:))`), which is what lets
  an event name the graph; 0.6.1's modules keep working as they are, but `rake
  graph_weaver:verify` reports the tree out of date until you regenerate.
  Result structs also gained `==`/`eql?`/`hash`, `deconstruct_keys`, `#to_h`
  and `#as_json`, and the emitted guard in front of a `cast:` changed (below).
- **Check that your `require "graph_weaver/rspec"` actually runs.** The old
  setup put it in `spec/support/graph_weaver.rb`, and rspec-rails ships the
  `spec/support` glob **commented out** — so if you never uncommented it, the
  tag did nothing and every `graphql: :fake` example has been hitting the real
  client. `rails g graph_weaver:install` now writes the line into
  `spec/rails_helper.rb` instead; **move yours there** if the glob isn't live.
- **`graphql: :wire`, if you adopt it, needs webmock *enabled*** — `require
  "webmock/rspec"` in the spec helper. Having it in the Gemfile is not enough:
  `Bundler.require` loads webmock without installing its adapters, and the tag
  refuses before the first request rather than letting it leave the suite.
- **A `DateTime` given for a `Date` variable is refused.** `DateTime` is a
  `Date` to Ruby, so it used to pass the cast untouched and go on the wire as
  `"2024-01-15T10:20:30+00:00"` where the schema said `ISO8601Date` — a lenient
  server truncated it, a strict one refused it. Truncating it here would be the
  same guess made silently, so it now raises an `InputError` naming the class
  and the fix: `$d of On: expected a Date, got a DateTime — pass .to_date if
  dropping the time of day is what you meant`. **Pass `.to_date` where a
  `DateTime` reaches a `Date` variable.** The pairings that already raised —
  a `Time` for a date, a `Date` for a timestamp — now raise that branded
  `InputError` rather than Ruby's *"no implicit conversion of Time into
  String"*, and a `DateTime` or `Time.zone.now` for a *timestamp* converts
  losslessly where it used to raise.
- **A `cast:` of your own gets the same guard and the same verdict.** A
  registration like `register_scalar("Date", Date, cast: :iso8601, serialize:
  :iso8601)` emitted a bare `value.is_a?(Date)` pass-through, so a `DateTime`
  went by untouched and your `serialize:` wrote a full timestamp into a date
  field — **pass `.to_date` there too**. Anything else wrong used to arrive as
  Ruby's own sentence about an argument you never wrote (`no implicit
  conversion of Integer into String`) under `kind: :unparseable`; the verdict
  is the library's now and splits the way Ruby does — a `TypeError` from a
  codec reads `expected a Date, got 5` under `kind: :type_mismatch`, an
  `ArgumentError` keeps the parser's words under `:unparseable`.
  **`#details[:type]` is the GraphQL type now, never a Ruby class** — a
  `register_scalar("Money", BigDecimal)` field reads `"Money"`, not
  `"BigDecimal"`, and an input object reads its schema name rather than the
  class generated for it; the *message* still names the Ruby you may pass.
  **A spec matching the old
  message, or branching on `:unparseable` for a wrong class, needs updating**
  — and the guard is emitted into your generated files, so a checked-in one
  keeps the old behavior until you regenerate.
- **A field whose name a struct already answers to now generates as `name_`.**
  `class` becomes the prop `class_`, `hash` becomes `hash_`, and so on for
  `display`, `to_json`, `each` and (on an input) `supplied`. Nothing that used
  to work stops working: a key you aliased in the query to get past the old
  *"alias it in the query"* refusal still generates from that alias — **drop
  the alias and regenerate** if you want the field's own name back. Only the
  Ruby name moves; the wire keeps the schema's spelling in both directions, so
  `result.class` is still Ruby's `class` and `result.class_` is the field. The
  prop is the field's one Ruby name, so `.coerce({ class_: … })` and a result's
  `#to_h` and pattern matching all use it. An `InputError`'s structured half is
  the wire's throughout, so a refusal on that field reports `#path` `["class"]`
  and `#coordinate` `"Tricky.class"`. An **input** struct's `#to_h`
  is the wire hash it would send, `{"class" => …}`, and input structs don't
  pattern-match. Input types had no way past the old refusal at all, so a
  schema with a `class` column — a Hasura `bool_exp` has one input field per
  column — generates for the first time. The names that take an underscore are
  a list the gem owns, rather than whatever `T::Struct` answered to in the
  generating process: deriving them made generation depend on require order, so
  with ActiveSupport loaded first a key named `asJson` was refused and loaded
  second it became a prop that shadowed the real `#as_json`. The list is what a
  struct answers — `T::Struct` and `Object`'s public instance methods, the
  hooks Ruby and Rails call on an object that doesn't define one (`initialize`,
  `to_ary`, `to_hash`, `to_json`, `as_json`, `to_param`, `try`, `presence`,
  `each`, `deconstruct_keys`), and the methods the gem's own mixins define — so
  a few more names move than 0.6.1 touched. Kernel's *private* methods are not
  on it: `format`, `select`, `test`, `open`, `load` and `pp` are ordinary
  column names, and the gem's mixins qualify their own calls (`Kernel.raise`)
  so a prop may take one. A federation `@key` on such a field follows the same
  rule instead of being refused: the kwarg takes the underscore
  (`Representations.room(class_: …)`) and `"class"` still goes on the wire, so
  **regenerate if a `@key` of yours names one**. Generated source marks each
  rename on the line above the prop — `# wire: class — reserved as a prop
  name` — so **read the regenerate diff** rather than grepping for the names
  yourself.
- **If you adopt `GraphWeaver.graph`, every queries directory needs a graph.**
  Declaring one replaces the implicit graph your top-level settings describe,
  so an app that declares a graph beside its existing `app/graphql/queries`
  leaves that directory unread — `generate` skipping it, `verify` calling the
  tree up to date. `generate!`, `verify_generated!` and `check_queries` refuse
  instead, naming the stray files. **Name the directory in a graph
  (`queries`/`output`), declare a graph for it, or delete it.** An app that
  declares no graph is unaffected.
- **A `client` that isn't a constant is refused at generation.** Its value is
  spelled into every module the graph generates, so `client` given an endpoint
  url emitted a file that doesn't parse, from a run that reported success.
  Declare the constant and name it — `CLIENT = GraphWeaver.new(url)`, then
  `client "CLIENT"` — which is what the message says.
- **A `cast:` or `serialize:` proc that returns a value is refused at
  registration.** A proc there builds *source* for the generated file, so
  `cast: ->(v) { v.to_sym }` interpolated to nothing and every response failed
  far from the registration, blaming the codec. It is probed once when
  registered now: return the source (`cast: ->(v) { "Money.parse(#{v})" }`) or
  name a method instead (`cast: :parse`).
- **`config.graph_weaver` refuses a key the railtie doesn't read**, at boot. It
  takes `watch`; `config.graph_weaver.queries_paths = …` was taken silently and
  did nothing, so the refusal replaces a line that wasn't working — in every
  spelling of that write, `config.graph_weaver[:queries_paths] = …` included.
  **Move it to `GraphWeaver.queries_paths =`**, which is what the message says.
- **A router's `fake:` refuses `seed:`**, as `graphql_fake` already did. A
  router is built once for the suite, so a seed inside
  `graphql_router(fake: …)` would pin every example to one run — `rspec --seed
  1234` reproduces the fabricated data along with the test order, and
  `GraphWeaver::Testing.config.seed` is the override for a harness that isn't
  rspec.

## Upgrading from 0.5.1

Much smaller than 0.5.0, and mostly mechanical. Three commands find most of it:

```sh
rake graph_weaver:generate   # 1. what codegen emits moved in several places
srb tc                       # 2. kwargs that got narrower are call-site errors
bundle exec rspec            # 3. every deleted knob raises where it's still set
```

The rest of this section is what those three don't catch.

### Loose input coerces, so `coerce:` and `auto_coerce` are gone

`execute(first: params[:first])` converts the String to an `Integer` — for every
variable and every input-object field, with nothing to switch on. The old way of
buying that was `GraphWeaver.auto_coerce` or `register_scalar(…, coerce: true)`,
and both paid for it by **widening the emitted kwarg**, which switched off the
static check at every call site. Delete them:

```ruby
GraphWeaver.auto_coerce = true                             # gone
GraphWeaver.register_scalar("Money", Money, coerce: true)  # drop the coerce:
```

Behavior is unchanged; the kwarg is not. It is now typed exactly as the schema
types it, so a call site passing a **literal** of the wrong type is a new
`srb tc` error — which is the point, since a literal is one you can just spell
right:

```ruby
StargazersQuery.execute(first: "10")            # srb tc error now
StargazersQuery.execute(first: params[:first])  # fine, and "10" becomes 10
```

`cast:` is what a loose value converts through, so a custom scalar needs nothing
beyond the registration it already has. Bad input raises
`GraphWeaver::InputError` naming the variable, the operation and the value.

Two conversions got **stricter** at the same time, and either can bite an app
that was passing. A numeric string is now read as a wire format rather than as
Ruby source, so `"010"` is ten rather than eight and `"0x1f"` and `"1_0"` are
refused. And a `Boolean` refuses a String outright — every rule for `"0"` and
`"off"` is somebody's convention, so convert at the call site.

### `nil` sends `null`

A variable passed `nil` now sends an explicit `null`; one left out is still left
out. That's what lets a mutation clear a field — and it changes what a kwarg fed
a possibly-missing value means:

```ruby
UpdateProfile.execute!(bio: params[:bio])   # a missing param used to omit; now it clears the bio
```

**Grep for kwargs fed straight from `params` or an optional attribute**, and
pass the keyword only when you mean it:

```ruby
UpdateProfile.execute!(**(params[:bio] ? { bio: params[:bio] } : {}))
```

Non-null variables are unaffected: they can't carry `null`, so `nil` there still
omits and the schema default applies. Input objects get the distinction only
where a Hash can express it — `coerce({nickname: nil})` sends null, `coerce({})`
omits, and a struct built with `.new` can't tell the two apart, so `nil` there
still means omit.

### Renames

| before | after |
|---|---|
| `Retry.new(tries: n)`, `retries: { tries: n }` | `retries: n - 1` — one word everywhere, counting the attempts *after* the first, so `retries: 0` is one attempt and `GraphWeaver.new(url, retries: 3)` is four |
| `GraphWeaver.new(url, retries: { retries: 5, retry_codes: […] })` | `GraphWeaver.new(url, retries: 5, retry_codes: […])` — the other retry options sit beside the count; the Hash form read as a key nested in itself |
| `Retry.new(t, on: […])` | `Retry.new(t, retry_on: […])` |
| `Retry.new(t, base: 0.5, max: 30)` | `Retry.new(t, base_delay: 0.5, max_delay: 30)` — beside a count, `max: 30` read as a second, larger attempt count |
| `Codegen.generate(module_name:)` | `name:` — the spelling `GraphWeaver.parse` already used; `module_name:` now raises, naming its replacement |
| `Testing.config.null_chance = 0.3` | `graphql_fake(null_chance: 0.3)`, on the example that wants it |
| `Testing.config.mode = :literal` | `graphql_fake(values: :literal)`, likewise |
| `Testing::MODES` | `Testing::VALUE_STYLES` |
| `SchemaLoader.stale?(path)` | `SchemaLoader.diff(path).empty?` — and `diff` also names what moved |

The two `Testing.config` deletions are the ones worth a sentence. A suite-wide
`null_chance` answers a per-example question, so it nils an unrelated field one
run in ten, on a seed the failure doesn't name; move it onto the examples that
are *about* an empty state. (`config.default_mode` and the `graphql: :fake` tag
are untouched — the per-fake `mode:` became `values:` so the two can't be
confused for each other.) Every retry misspelling raises rather than being
ignored: the Hash form names its flat replacement, and a retry option passed
without `retries:` says so.

### The internals moved behind `Internal`

The public surface is now what the docs name, what generated code calls, and the
`execute` slot; everything else sits under `GraphWeaver::Internal` or went
`private`, and a spec diffs the two so the next accidental promotion fails CI.
Nothing documented moved — skip this section unless `srb tc` or a
`NoMethodError` says otherwise.

What a suite might plausibly have reached for: the federation query planner and
its IR (`Internal::Planner`), the fake-value engine (`Internal::Values`), the
selection walk (`Internal::Selection` — so `FakeClient` no longer answers
`each_field` or `gather`), the cassette matching rules (`Internal::RequestKey`),
subgraph detection (was `Testing::Subgraphs`), `GraphWeaver.log` /
`.instrument` / `.filter_variables` (`Internal::Log` — `logger=`,
`instrumenter=` and `filter_parameters=` are unchanged), and
`Transport.operation_name` / `.mutation?` / `.log_tag`, which left the class you
subclass for `Internal::Wire`.

Two smaller edges. `SchemaDiff::Change`, `Cassette::Check`, `Coverage::Result`
and `InputStruct::Field` are `Data` now rather than `Struct`, so they hand out
no writers — read one, build a new one to change a field. And generated modules
keep their own plumbing to themselves: `DEFAULT_CLIENT`, `FIELDS` and `ONE_OF`
are emitted `private_constant`, so **regenerate**.

### Behavior that changed under you

- **A mutation is no longer retried.** A timeout doesn't say whether the server
  applied it, and a second `charge` is worse than a failed one. Pass
  `retry_mutations: true` for an API whose mutations are idempotent.
- **A registration this schema can't match warns instead of failing
  generation.** One registry serves a whole federated graph, so a name the
  schema in hand doesn't declare may belong to the subgraph next door — see
  [federation](federation.md#generating-for-a-federated-graph). Your typo is now
  in the list `rake graph_weaver:generate` prints after the files, so read it.
- **`verify_generated!` fails when it finds no query documents.** A mistyped
  `queries_paths` used to leave a CI gate green forever.
- **The local router refuses a `@fromContext` argument** rather than fetching
  the field with it unset. Federation 2.8's `@context` machinery was on the
  routing table's known list, so the argument was read and dropped. Per query,
  like `@interfaceObject`: a subtree one subgraph answers whole still runs.
- **A `#trace` assertion may see one entry fewer.** Two `@requires` field sets
  crossing into the same subgraph on the same `@key` now ride one entity fetch,
  the way Apollo's do.
- **Fabricating a custom scalar registered as a class of your own needs a pin
  for the type** — `Testing.config.overrides = { "Money" => "12.00" }`, or the
  same key on one example's `graphql_fake`. Without one, `FakeClient` and
  cassette anonymization refuse rather than feeding your cast a `"Money-1"`
  placeholder. Scalars registered as `BigDecimal`, `Time`, `Date`, `Integer`,
  `Float`, `String` or `T::Boolean` need nothing.
- **Re-run `rake graph_weaver:cassettes:anonymize`** on any committed cassette
  holding a registered custom scalar: the anonymizer used to write a value the
  generated codec couldn't read back.
- **Generation refuses four more things**, each naming its fix — a
  `register_scalar` whose Ruby type nothing can build out of JSON (a value
  object of your own: give it a `cast:`), a result key that would shadow a constant the
  file uses, an enum value that camelizes to nothing, and a narrowed fragment
  whose `__typename` sits behind `@skip`/`@include`.

## Upgrading to 0.5.0

0.5.0 is one large breaking release. Almost all of it is caught mechanically,
in this order:

```sh
# 1. rename the path settings first — generate won't load without them
#    (queries_path -> queries_paths, generated_path -> generated_paths,
#     fragments_path -> fragments_paths; see "Path settings are lists" below)

bundle exec tapioca gem graph_weaver   # 2. regenerate the RBI
rake graph_weaver:generate             # 3. the emitted call shape changed
srb tc                                 # 4. every call site that moved is an error
rake graph_weaver:verify               # 5. fails until the tree is regenerated
```

**Step 2 is not optional.** Against the 0.4.6 RBI, `srb tc` reports errors
pointing into your `generated/` directory — `QueryModule`, `client_for`,
`check_envelope!` — which read as though codegen emitted broken Ruby. It
didn't; sorbet is checking new generated code against the old gem's types.
Regenerate the RBI and what remains is only your own call sites.

Generated code is `# typed: strict`, so step 4 finds those for you. The rest of
this page is what a typechecker can't see.

### `execute` means one thing now

Every client answers the same call — `execute(query, variables:, operation_name:)`,
returning the raw response hash. `Client` used to spell something else under
that name, which is why `Retry.new(client)` and `Sequence.new(client, fake)`
raised `ArgumentError`. They work now.

The one-shot sugar moved to `run`:

```ruby
client.execute!("query { … }", id: "1")   # before
client.run!("query { … }", id: "1")       # after   (and #run for the envelope)

GraphWeaver.execute(source, query, **vars)   # before
GraphWeaver.run(source, query, **vars)       # after
```

**This one is worth grepping for.** `Client#execute` still exists, so a stale
call fails at runtime rather than at typecheck — as do `GraphWeaver.execute`
and `GraphWeaver.reset_scalars!`, which are simply gone and will not be flagged
until the RBI is regenerated (step 2): `rg '\.execute!?\(' --type ruby`
and check each hit is passing `variables:` rather than loose kwargs.

A generated module takes its per-call client as a **keyword**:

```ruby
PersonQuery.execute(some_client, id: "1")          # before
PersonQuery.execute(client: some_client, id: "1")  # after
```

`GraphWeaver.resolve_transport` is gone; nothing needs unwrapping any more.

### Path settings are lists

`queries_paths`, `generated_paths`, `fragments_paths` — every entry is read.
Assigning a String still works, so the change is the name:

```ruby
GraphWeaver.queries_path = "app/graphql/queries"    # before
GraphWeaver.queries_paths = "app/graphql/queries"   # after
```

`schema_path` stays singular: one run reads one schema.

### One reset

`GraphWeaver.reset_registrations!` is the clean slate between tests, or between
generations for different schemas. The four
narrow ones moved to where they live:

```ruby
GraphWeaver.reset_scalars!            # before
GraphWeaver::Codegen.reset_scalars!   # after   (also reset_enums!, clear_scalars!,
                                      #          reset_type_helpers!)
```

### Generated names come from the response key, not the type

Nested structs used to be named for the GraphQL *type* they were cast from;
they are now named for the **response key that selects them**, camelized, and
the constant path reads like the query. The typechecker finds the call sites in
a `# typed: true` file (an unresolved constant is an `srb tc` error); in a
`# typed: false` file it is `uninitialized constant` at runtime, so grep for
`::Result::` there.

| selection | before (type) | after (key) |
|---|---|---|
| `person { pets { name } }` | `PersonQuery::Result::Person::Pet` | `PersonQuery::Result::Person::Pets` |
| `payrollRisk { score }` | `…::Result::RiskAssessment` | `…::Result::PayrollRisk` |
| `_entities(…) { ... on Product { … } }` | `…::Result::Product` | `…::Result::Entities::Product` |

The key is used verbatim — no pluralization, so a list field `pets` is `Pets`.
To pick the name yourself, alias the field: `pet: pets { name }` generates
`Pet`. Union and interface members keep their type-condition names, nested in
the container the field names. The payoff is that adding, removing or
reordering an unrelated selection can never rename a struct you reference.

**Enums moved out of the result tree.** Every schema enum a query touches is one
Ruby type in the shared module, `GraphQLTypes::Species`, so a value read from
one query hands straight into another's variable. A query module aliases the
enums its *variables* use (`AddPetMutation::Species` still works); an enum
reached only through a result is no longer nested under the struct that
carries it — `SearchQuery::Result::Search::Species` is `GraphQLTypes::Species`.

### Smaller renames

| before | after |
|---|---|
| `Testing.config.auto_fake = true` | `Testing.config.default_mode = :fake` |
| a mutation's `…Query` module | `…Mutation` |
| `graphql: :none` (rspec tag) | `graphql: :live` |

**The shared types module was three, and is now one.** `GraphQLInputs`,
`GraphQLEnums` and `GraphQLUnions` are all `GraphQLTypes`, and the files move
with them — `generated/inputs/` becomes `generated/types/`. The three settings
that named them (`inputs_module=`, `enums_module=`, `unions_module=`) are one
`types_module=`. Regenerating writes the new tree; delete the old directory,
which pruning leaves behind empty.

If your specs run one schema class in-process while your client points at a
different API, name it — per example, since a federated suite runs more than
one:

```ruby
graphql_in_process(MySchema)                     # in the example
GraphWeaver::Testing.config.schema = MySchema    # or once, for the whole suite
```

### Registering from Rails

A registration naming one of your own constants belongs in a `to_prepare` block
— the same place the in-process client goes, and for the same reason:
autoloading is set up after `config/initializers` run.

```ruby
Rails.application.config.to_prepare do
  GraphWeaver.register_enum("Species", PetKind, fallback: PetKind::Unknown)
  GraphWeaver.extend_type("Pet", PetHelpers)
end
```

Generation depends on `:environment`, which runs `to_prepare` too, so the
registration is in place before it emits — and at boot the generated files
load from a `to_prepare` block of their own, after yours.

### If you use the federation router

Detection only sees *loaded* schema classes, and Rails does not eager load for
rake or in the default test environment. Both are one line:

```ruby
config.eager_load = true        # config/environments/test.rb
config.rake_eager_load = true   # config/application.rb
```

Without them the `federation:*` tasks silently see nothing — and
`federation:diff` now **fails** rather than reporting a green "matches" over
zero subgraphs.
