# Upgrading

[Regenerate](#regenerate-on-every-upgrade) whichever version you're on, then read
the one section that is yours: from [0.7.0](#upgrading-from-070) or from
[0.6.1](#upgrading-from-061). Coming from 0.6.0 or older, the path is that
version's own upgrade notes — read them at the tag they shipped under
(`git show v0.7.1:docs/upgrading.md`), then this page from 0.6.1 down.

## Regenerate on every upgrade

**Any release can change what codegen emits**, patch releases included — most of
them are fixes to a generated type, and a fix to a type is a change to the bytes.
So `rake graph_weaver:generate` is part of upgrading the gem, every time, and
`rake graph_weaver:verify` is the detector: it fails when the checked-in Ruby
isn't what this version would write. Nothing beyond that is promised — there is no
"generated output is stable within a minor" rule to lean on, and what each release
changed is in the [changelog](../CHANGELOG.md).

A generated file's header names the release that wrote it, so the first `verify`
after an upgrade reports the tree as stale whether or not codegen actually moved.
That's the reminder working, not a false alarm. Generation is deterministic, so
the diff is exactly what the new version emits differently and nothing else —
worth reading rather than rubber-stamping.

## Upgrading from 0.7.0

A patch release of fixes, and a typical app ticks none of these. Read the left
column and skip what isn't yours; the [changelog](../CHANGELOG.md) says why each
one moved.

| applies if you… | what changed |
|---|---|
| read `payload[:code]` in an alert or a dashboard expecting an HTTP status | it is a GraphQL error code or nothing now — the number is on `:http_status`, where it already was |
| assert a fabricated `userErrors` is non-empty under `graphql: :fake` | a list field whose name ends in `errors` fabricates `[]` — pin it (`{ "userErrors" => [{ "message" => "…" }] }`) to fabricate failures |
| grep or parse the debug log for `[req 3 …]` | the tag names the process: `[req 4123-3 …]` |
| run more than one graph with `cache: true` | the second graph caches to `schema-<url digest>.json` of its own instead of sharing the first's dump — `cache: "<path>"` names it yourself |
| commit your cassette directory | recording takes a `<cassette>.yml.lock` sidecar — gitignore `*.yml.lock` |
| `rescue ArgumentError` around the union-dispatch refusal | it is a `GraphWeaver::Error` naming the query file now |
| wrote a client of your own with a bare `attr_accessor :context` and mount it behind `Testing::Endpoint` | include `GraphWeaver::ContextSeam` — the lock lives on whoever owns the field |
| read `CHANGELOG.md` out of the installed gem | it isn't packaged any more; `changelog_uri` points at `blob/v<version>` |
| send a `File`, `IO`, `Pathname` or plain object as a variable under `graphql: :in_process` or `:fake` | refused there too now, as it already was over the wire — **a test that "proved" an upload works starts failing** |
| retry a 429/503 that arrives **with** a GraphQL errors body | a `Retry-After` header wins over the configured backoff now, as it already did for a raised `ServerError` — **nothing raises** |

## Upgrading from 0.6.1

Mostly mechanical. Everything that wants your hands, or changes under you, is one
row below; read the left column and skip what isn't yours. A typical app ticks two
or three.

| applies if you… | what changed |
|---|---|
| run a Rails app that configures no logger or instrumenter | **you start logging one info line per GraphQL call** — a production log-volume change, [first bullet below](#behavior-that-changed-under-you) |
| wrap a gateway in `Retry` | **a 5xx/429 that arrives with an errors body retries now** — real traffic, [below](#behavior-that-changed-under-you); `retries: 0` opts out |
| commit a schema dump introspected through a url carrying a token | **refresh it, and rotate the token if that file was pushed** — the dump recorded the url verbatim |
| keep a schema dump deliberately behind your own schema class | `verify` fails on it now |
| check in a composed supergraph as your dump | `schema:refresh` refuses it rather than overwriting it with the API schema — recompose instead |
| use `@oneOf` input types and commit a `.json` dump | `@oneOf` starts being enforced client-side once you regenerate |
| call `result.to_json`, or `render json: result` | it is the wire shape now, not `#inspect` or your prop names |
| send a `File`, `IO` or `Pathname` as a variable | refused at the wire, where `JSON.generate` used to ship its `#to_s` |
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
| have an entity `@key` that selects through a list | the kwarg is a list now, not one hash — regenerate |
| build a type helper with `extend_type("Widget") { … }` | its constant is named for its graph and its type — regenerate |
| adopt `GraphWeaver.graph` | every queries directory then needs one |
| write `config.graph_weaver.<anything but watch>` | refused at boot |
| pass `SUPERGRAPH=` to any task but `federation:*` | refused, where it was ignored — a CI step that did it goes red |
| compare a `Testing::Router` error hash whole in a spec | a subgraph error carries `extensions: {"service" => …}` now |
| pass `seed:` to `graphql_router(fake: …)` | refused |
| require `graph_weaver/rspec` from `spec/support/` | check the glob is uncommented — rspec-rails ships it commented out |
| adopt `graphql: :wire` | it needs `require "webmock/rspec"`, not just the gem |

Then five commands, in order:

```sh
# 1. the two renames your own code holds
grep -rn "GraphWeaver::TypeError\|GraphWeaver::ValidationError" app lib spec
grep -rn "graph_weaver.execute" app lib config spec   # the old event name

# 2. rewrite the dump: it drops a credential the url carried, and picks up
#    isOneOf. Skip only if your dump is SDL and records no source url — and
#    a composed supergraph refuses, since introspection can't rebuild one:
#    `rover supergraph compose` is what rewrites that.
rake graph_weaver:schema:refresh

# 3. regenerate — also the graph name in every module, the underscored
#    reserved props, as_json, and the client: and cast:/serialize: refusals
rake graph_weaver:generate

# 4. the renamed tag, the deleted nil, the seed: refusal
bundle exec rspec

# 5. the gate: red while any checked-in file is still what 0.6.1 wrote
rake graph_weaver:verify
```

**Two kinds of file answer that first grep, and only one needs your hands.** Hits
under your generated directory (`app/graphql/generated/` by default) are the old
names in machine-written code — step 3 rewrites them. Hits anywhere else are
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

The first one reaches every Rails app that never configured logging, and it is the
only one here that shows up in production rather than in your code.

- **A Rails app logs one line per GraphQL call, and emits one notification.** The
  railtie sets `GraphWeaver.instrumenter` to the `ActiveSupport::Notifications`
  adapter and attaches `GraphWeaver::LogSubscriber`, so an app that configured
  neither gets `GraphWeaver billing/InvoicesQuery (12.3ms) ok` at **info** — the
  query and variables stay at debug. **To opt out, set `GraphWeaver.logger = nil`
  or `GraphWeaver.instrumenter = nil` in `config/initializers`**, which now takes
  effect (an app that worked around that with `config.after_initialize` can drop
  it). In-process calls are in scope too: a bare schema class in a client slot goes
  through the same wrapper, so it produces events and log lines where it produced
  none. See [logging](logging.md).
- **A `Retry` in front of a gateway starts actually retrying.** It read only the
  failures that *raised*, and Apollo Router answers everything it decides itself
  with a GraphQL errors body, so `retries: 3` made one attempt. A response retries
  now when its status is one a `ServerError` retries on (5xx, 408, 429), or when
  its error codes are named in `retry_codes:`. **This is real traffic you weren't
  sending** — if the inert policy was what you wanted, `retries: 0`.
- **A task that can't honour `SUPERGRAPH=` refuses instead of ignoring it.** The
  flag reaches the `federation:*` tasks and nothing else, so
  `SUPERGRAPH=public.graphql rake graph_weaver:queries:check` used to report every
  query valid against a supergraph missing fields they select. **A CI step that
  passes it to `generate`, `verify` or `queries:check` goes red**; drop the flag,
  or declare the supergraph on a graph.
- **`InputError#field` names the input field, not the variable.** It is `#path`'s
  last *named* segment — the slot that actually held the bad value — where it used
  to be re-branded with the *variable* name. Nothing raises; the value just differs
  once a refusal happens inside an input object. **Read `error.path.first` wherever
  you wanted the variable.** An index is a position rather than a field, so
  `execute(ids: [1, 2, "x"])` reports `#path` `["ids", 2]` and `#field` `"ids"`.
- **The instrumentation payload's `:status` is a Symbol, and the HTTP status moved
  to `:http_status`.** `:status` is `:ok`, `:errors` or `:failed` — a 200 carrying
  errors is not a success, and only a symbol says that on both sides of the seam.
  Nothing raises: a subscriber comparing it to an Integer just stops matching. **A
  subscriber that branched on a 4xx/5xx reads `:http_status` now**, which is nil
  in-process. The whole payload is a documented contract —
  [logging](logging.md#the-payload).
- **`respond_to?` on a result struct no longer answers true for a name that doesn't
  exist.** It used to say true for any near miss, which broke the standard
  duck-typing guard. **A branch that read the old answer now takes the other path**,
  and `struct.method(:nmae)` raises Ruby's bare `NameError`; `struct.nmae` still
  hints.
- **A `graphql:` tag reaches a module generated with `client:`.** The baked client
  used to sit above the slot a tag swaps, so a bound module ran against its real
  endpoint under `graphql: :fake`. **If a spec relied on that**, pass `client:` on
  the call, or tag the example `graphql: :live`.
- **`config.context`, `config.schema` and `config.router` are suite setup.**
  Setting any of the three once an example is running refuses, naming the
  per-example helper (`graphql_context`, `graphql_fake(schema:)`,
  `graphql_router(fake:)`). The tag builds an example's clients in a `before` hook
  of its own, which rspec runs ahead of any group `before`, so a set there was read
  too late and silently changed nothing. **Move it to an `around`, or to
  `GraphWeaver::Testing.configure` in the spec helper.**
- **`result.to_json` is real JSON, and it is the wire shape.** It used to be Ruby's
  `Object#to_json` — the `#inspect` string, quoted — while under Rails
  `render json: result` shipped the *Ruby* prop names. Both now produce the response
  keys, each leaf back through its scalar registration's `serialize:`, so
  `Result.from_h(JSON.parse(result.to_json)) == result`. `#to_h` is unchanged and
  still the Ruby view. **Anything that parsed the old output is reading something
  different now** — and `as_json` is emitted code, so a struct generated by 0.6.1
  raises `GraphWeaver::Error` naming this until you regenerate.
- **A schema dump introspected through a credentialed url still holds the token.**
  The provenance stamp wrote the transport's url verbatim. It records the endpoint
  bare now — userinfo and any query parameter `filter_parameters` filters are
  dropped — and re-introspection still authenticates from the dump's `auth_env`.
  **Run `rake graph_weaver:schema:refresh` once, and rotate the token if that file
  was ever pushed.**
- **`verify` fails when the dump has fallen behind the schema class it was built
  from.** For an app that serves its own schema the dump is an artifact derived
  from code in the same repo, so `generate` and `verify` both called a tree up to
  date while the live resolvers had already moved. **A dump you deliberately keep
  behind your own schema is a red gate now** — `rake graph_weaver:schema:refresh`,
  or ask about no dump at all with `verify_generated!(schema:)`. It costs one
  in-process introspection per graph and never a network call.
- **`@oneOf` starts being enforced if your dump is `.json`.** graphql-ruby's
  introspection query omits `isOneOf` unless asked, so every dump this gem had
  written said "not @oneOf" for every input object. **Regenerate and the emitted
  `ONE_OF` starts refusing calls that set two fields** — which your server was
  refusing all along, so the failure moves from the wire into `execute`. SDL dumps,
  inline SDL and a live class were always correct.
- **A fake pin is told from an option by a schema lookup, not by casing.** A
  lowercase type could not be pinned at all (`graphql_fake("pokemon_v2_pokemon" =>
  …)` against a Hasura API); those pins work now. The other side of it: **a keyword
  that is a near-miss for a pin (`Persn: "Ada"`) raises `ArgumentError` from the
  fake** rather than `GraphWeaver::Error` from the override check — the same key
  written in the leading positional hash is unchanged, and is the spelling for a
  schema whose vocabulary collides with an option name.
- **A `DateTime` given for a `Date` variable is refused.** `DateTime` is a `Date`
  to Ruby, so it used to pass the cast untouched and go on the wire as a full
  timestamp where the schema said `ISO8601Date`. **Pass `.to_date`.** The pairings
  that already raised — a `Time` for a date, a `Date` for a timestamp — now raise a
  branded `InputError` rather than Ruby's *"no implicit conversion of Time into
  String"*, and a `DateTime` or `Time.zone.now` for a *timestamp* converts
  losslessly where it used to raise.
- **A `cast:` of your own gets the same guard and the same verdict.** A registration
  like `register_scalar("Date", Date, cast: :iso8601, serialize: :iso8601)` emitted
  a bare `value.is_a?(Date)` pass-through, so a `DateTime` went by untouched and
  your `serialize:` wrote a full timestamp into a date field — **pass `.to_date`
  there too**. Anything else wrong used to arrive as Ruby's own sentence under
  `kind: :unparseable`; the verdict is the library's now and splits the way Ruby
  does — a `TypeError` from a codec reads `expected a Date, got 5` under
  `:type_mismatch`, an `ArgumentError` keeps the parser's words under
  `:unparseable`. **`#details[:type]` is the GraphQL type now, never a Ruby class.**
  A spec matching the old message, or branching on `:unparseable` for a wrong class,
  needs updating — and the guard is emitted into your generated files, so a
  checked-in one keeps the old behavior until you regenerate.
- **A field whose name a struct already answers to now generates as `name_`.**
  `class` becomes `class_`, and so on for `hash`, `display`, `to_json`, `each` and
  (on an input) `supplied`. Only the Ruby name moves: the wire keeps the schema's
  spelling in both directions, so a refusal on that field still reports `#path`
  `["class"]`, and an input struct's `#to_h` is still the wire hash. A key you
  aliased in the query to get past the old refusal still generates from that alias
  — **drop the alias and regenerate** if you want the field's own name back. The
  names that take an underscore are a list the gem owns (`T::Struct` and `Object`'s
  public instance methods, the hooks Ruby and Rails call on an object, and the
  gem's own mixins) rather than whatever the generating process happened to have
  loaded, so a few more names move than 0.6.1 touched; Kernel's *private* methods
  are not on it, so `format`, `select`, `open` and `load` stay ordinary props. A
  federation `@key` on such a field follows the same rule instead of being refused
  — the kwarg takes the underscore and `"class"` still goes on the wire, so
  **regenerate if a `@key` of yours names one**. Generated source marks each rename
  on the line above the prop, so **read the regenerate diff**.
- **If you adopt `GraphWeaver.graph`, every queries directory needs a graph.**
  Declaring one replaces the implicit graph your top-level settings describe, so a
  graph declared beside an existing `app/graphql/queries` used to leave that
  directory unread. `generate!`, `verify_generated!` and `check_queries` refuse
  now, naming the stray files. **Name the directory in a graph, declare a graph for
  it, or delete it.** An app that declares no graph is unaffected.
- **A `client` that isn't a constant is refused at generation.** Its value is
  spelled into every module the graph generates, so `client` given an endpoint url
  emitted a file that doesn't parse, from a run that reported success. Declare the
  constant and name it — `CLIENT = GraphWeaver.new(url)`, then `client "CLIENT"`.
- **A `cast:` or `serialize:` proc that returns a value is refused at
  registration.** A proc there builds *source* for the generated file, so
  `cast: ->(v) { v.to_sym }` interpolated to nothing and every response failed far
  from the registration. It is probed once when registered now: return the source
  (`cast: ->(v) { "Money.parse(#{v})" }`) or name a method instead.
- **`config.graph_weaver` refuses a key the railtie doesn't read**, at boot. It
  takes `watch`; `config.graph_weaver.queries_paths = …` was taken silently and did
  nothing. **Move it to `GraphWeaver.queries_paths =`.**
- **A router's `fake:` refuses `seed:`**, as `graphql_fake` already did. A router is
  built once for the suite, so a seed there would pin every example to one run —
  `rspec --seed 1234` reproduces the fabricated data along with the test order, and
  `GraphWeaver::Testing.config.seed` is the override for a harness that isn't rspec.
- **Check that your `require "graph_weaver/rspec"` actually runs.** The old setup
  put it in `spec/support/graph_weaver.rb`, and rspec-rails ships the `spec/support`
  glob **commented out** — so if you never uncommented it, the tag did nothing and
  every `graphql: :fake` example has been hitting the real client.
  `rails g graph_weaver:install` writes the line into `spec/rails_helper.rb`
  instead; **move yours there** if the glob isn't live.
- **`graphql: :wire`, if you adopt it, needs webmock *enabled*** — `require
  "webmock/rspec"` in the spec helper. Having it in the Gemfile is not enough:
  `Bundler.require` loads webmock without installing its adapters, and the tag
  refuses before the first request.
- **Regenerate**, as ever. Generated modules carry a private `GRAPH` naming the
  graph they were generated from, and a
  [multi-schema](getting_started.md#more-than-one-schema) app whose modules predate
  it refuses rather than guessing which schema a module belongs to. A generated
  `execute` also makes its request through the gem now, which is what lets an event
  name the graph; 0.6.1's modules keep working, but `verify` reports the tree out of
  date until you regenerate. Result structs also gained `==`/`eql?`/`hash`,
  `deconstruct_keys`, `#to_h` and `#as_json`.
