## Unreleased
**A variable named `$client` no longer generates a file that won't parse.**
`query($client: ID!)` emitted `def self.execute(client = nil, client:)` — a
`SyntaxError` raised at app boot from `load_generated!`, arbitrarily far from
the query that caused it, while `verify_generated!` reported the tree as
current. Generation now refuses `$client`, `$variables` and `$transport` — the
three locals the generated `execute` body owns — naming the fix. **Rename such
a variable in the query (`query($clientId: ID!)`) before regenerating.** A
single input-object variable whose *field* is one of those names (which you
can't rename) simply keeps its wrapping kwarg instead of being flattened.

**`auto_coerce` no longer erases the typing of String/ID variables.** It mapped
both to `#to_s`, which widened their kwargs to `T.anything` — the majority of
real variables, statically unchecked, in exchange for a cast that can't fail.
`auto_coerce` now covers only the conversions that are conversions (`Int`→`to_i`,
`Float`→`to_f`) plus scalars with a full cast/serialize pair. **If you relied on
a String/ID kwarg accepting anything, opt in per scalar:**
`GraphWeaver.register_scalar("ID", String, coerce: :to_s)`.

**An anonymous operation is now named after its module — in the query text and
in `OPERATION_NAME`.** Requests started carrying `operationName` so servers and
APMs can attribute traffic, but the constant was only set when the `.graphql`
document named its operation — and anonymous is what the docs show, so every
trace arrived `anonymous` and the feature did nothing for the documented happy
path. `person.graphql` holding `query($id: ID!) { ... }` now emits
`query PersonQuery($id: ID!) { ... }` with `OPERATION_NAME = "PersonQuery"`.
Both halves move together: a server rejects an `operationName` its document
doesn't declare. A document that names its own operation is left untouched.

**Re-record cassettes for anonymous operations.** Cassette entries key on
`operationName`, and those were recorded with the key omitted, so they no
longer match (`Recorder` / `Cassette.use` with a live client, or delete the
cassette).

**`GraphWeaver.queries_paths` (plural) is gone — use `queries_path`.**
`generate!` and `check_queries` read the singular (the first entry) while
`load_queries!` walked the whole list, so a second queries directory produced
modules at runtime that `rake graph_weaver:generate` never generated and
`verify` never checked — silently. Queries are single-schema by design. **If
you appended a second queries directory, fold it into the first** (or run a
second `generate!` with its own `queries:`). `generated_paths` and
`fragments_paths` stay plural; they genuinely load from several places.

**One GraphQL enum is now one Ruby type.** A schema enum a query touches — as
a variable, in a result, or both — is emitted once per schema into
`generated/enums.rb` as `GraphQLEnums::<Enum>`, and every query module aliases
it. Before, an enum read out of a result got a class named for the response key
and nested in the struct that selected it (`SearchQuery::Result::Search::Pet::Species`),
while the same enum used as a variable got a module-level one — so whether a
schema enum was one Ruby type or three depended on what else the query happened
to reference, and handing a value from one query into another's variable raised
a `TypeError` that wasn't even a `GraphWeaver::Error`.

**Regenerate, and expect enum constants to move.** A nested enum path in app
code becomes the query module's own alias — `SearchQuery::Species` — or
`GraphQLEnums::Species`; `srb tc` finds them all. The enums a shared fragment's
union members select are hoisted too, so `unions.rb` now aliases them rather
than re-emitting them.

**The shared module names no longer depend on your output directory.** They are
`GraphQLInputs`, `GraphQLUnions` and `GraphQLEnums`, full stop. The old rule
camelized the parent of `generated/` unless it was on a hardcoded blocklist, so
`output: "gen2"` gave you `Gen2Inputs` and renaming `app/graphql/generated` to
`app/gql/generated` renamed a public constant. **A multi-schema layout must now
name its modules explicitly** — `GraphWeaver.inputs_module=` /
`unions_module=` / `enums_module=`, or `generate!(inputs_module:, ...)` — in the
same initializer that already gives each schema its paths. `GraphWeaver.inputs_module`
and `unions_module` no longer take an output-path argument.

**One registration registry, not two.** `Client#register_scalar`,
`#register_enum`, `#register_enums` and `#extend_type` are **deleted** — a
client-scoped registration was invisible to `GraphWeaver.generate!` (the rake
tasks have no client), so the console typed a field richly and the checked-in
code silently generated `T.untyped`. **Move any `client.register_*` /
`client.extend_type` call to the `GraphWeaver.` form** (an initializer, next to
the rest of your config). The one thing client scoping bought — two servers
disagreeing about a scalar — is what the per-field coordinate form is for:
`GraphWeaver.register_scalar("User.birthday", Date)`.

Also gone with it: `GraphWeaver.register_enums` (bulk) — there was never a
`register_scalars` to match it, so call `register_enum` per line — and
`GraphWeaver.reject_positional_map!`, now folded into the one
`Codegen.register_enum` that every door reaches (so all three doors give the
same "the value map is a keyword" error instead of a bare arity complaint).
`Codegen.parse` / `.generate` / `.generate_inputs` / `.generate_unions` no
longer take `scalars:`/`enums:`/`types:`.

**`generate!` now takes a Client where it takes a schema** — `GraphWeaver.generate!(schema: api)`,
`verify_generated!`, `check_queries` and `parse` all accept one, so the object
you built in the console is the object the build step wants and no schema dump
is needed. `client:` still means what it meant (a constant name to bake as
`DEFAULT_CLIENT`) and still refuses a live object.
**Rails integration fixes, found by running the gem in a real Rails app.**

- **Production boot no longer raises `uninitialized constant
  Generated::PersonQuery`.** The default `generated_path` is
  `app/graphql/generated`, which Zeitwerk claims as an autoload root, while
  the files there define top-level constants. Development (lazy) was fine and
  eager loading was not, so this only showed up in production or
  `rails zeitwerk:check`. The Railtie now hides the generated directory from
  the loader; nothing to configure.
- **`rake graph_weaver:generate` runs your initializer again.** The tasks
  asked whether Rails' `:environment` task existed at *load* time, but Rails
  defines it after every Railtie's `rake_tasks` block, so the answer was
  always no. Generation and `verify` therefore ran without booting the app —
  silently dropping every `register_scalar` / `register_enum` / `extend_type`
  in `config/initializers`, and generating code that disagreed with the
  running app. **Regenerate**: if you register anything in an initializer,
  your committed generated files are wrong, and `rake graph_weaver:verify`
  will now say so.
- `generate`, `verify` and `schema:verify` report a `GraphWeaver::Error` the
  way `schema:refresh` already did — the message, and a non-zero exit,
  instead of a rake backtrace through codegen.

**`rails g graph_weaver:install` takes any source `GraphWeaver.new` takes.**
The endpoint moves from `--url=` to a positional argument, and a schema class
or an existing dump work the same way:

```sh
rails g graph_weaver:install https://api.example.com/graphql
rails g graph_weaver:install MyApp::Schema        # in-process, no socket
rails g graph_weaver:install db/schema.graphql    # a dump you already have
```

`--url=` no longer exists — pass the url as the argument. The initializer
reflects the form chosen: a schema class is resolved in a `to_prepare` block
(it is autoloaded, so an initializer can not read it, and a dev reload
replaces the class object), and a dump you already have becomes
`GraphWeaver.schema_path` rather than being copied. `--auth` and the
introspection step are url-only; a source that can not use them, a constant
that does not resolve, and a class that is not a schema are all refused
before any file is written.

**Generated struct names now come from the query's own field names.** A struct
is named for the response key that selects it — `stargazers` becomes
`Stargazers`, `edges` becomes `Edges` — so its name is a function of its own
position in the query and nothing else. Names came from GraphQL *type* names
before, disambiguated by field name only on collision, which meant **a second
selection of the same type renamed the first**: a silent break in checked-in
code your app references. Deep queries could also collide outright and refuse
to generate.

**Regenerate, and expect renames.** Nearly every nested struct changes name
(`PersonQuery::Result::Person::Pet` becomes `...::Person::Pets`), and app code
naming one won't typecheck until it's updated — `srb tc` finds them all. The
payoff: adding, removing, or reordering an unrelated selection can never move
a name again.

- The key is used verbatim, with no pluralization heuristic — a list field
  `pets` generates `Pets`. To pick a different name, alias the field in the
  query: `pet: pets { name }` generates `Pet` (and a `.pet` accessor).
- Union and interface members keep their type-condition names (`... on Book`
  gives `Book`), inside a container named for the field; a union hoisted from
  a shared fragment is still named for the fragment.
- Two ties that walk order used to settle now resolve on their own: fields
  sharing one collapsed union type take the first of their keys
  alphabetically, and a name that would shadow the struct it nests in
  (`pet { pet { ... } }`) takes a numeric suffix (`Pet2`).

**Requests now send `operationName`** — every graph_weaver request used to be
anonymous in Apollo Studio, Hasura, and any APM that keys traces, rate limits
and slow-query reports on it. Generated modules emit their operation name as
`OPERATION_NAME` beside `QUERY` and send it on the wire; a raw query string
handed to a transport falls back to the name in the document. In-process
execution passes it to `Schema.execute(operation_name:)`, which also makes a
multi-operation document selectable there.

To get the benefit, **name your operations** — `query Person($id: ID!)`, not
`query($id: ID!)` — and regenerate. An anonymous operation still works and
sends no `operationName`.

Three breaking changes come with it:
- **The client-slot contract widened to
  `execute(query, variables:, operation_name: nil)`.** If you wrote your own
  transport, client, or test double, add the kwarg — a client that doesn't
  accept it now raises `ArgumentError: unknown keyword: :operation_name`. A
  graphql-ruby `Schema` class already takes it, so bare schemas in the client
  slot are unaffected. Subclasses of `GraphWeaver::Transport` only implement
  `post(body)` and need no change.
- **Cassettes are keyed on `operationName` too**, so two operations in one
  document can't collide. Cassettes recorded from a *named* operation before
  this release no longer match — re-record them
  (`GRAPHWEAVER_RECORD=1 bundle exec rspec`). Anonymous ones are unaffected.
- **`GraphWeaver::Transport.log_tag` takes an operation name, not a query
  string** (`log_tag(query)` → `log_tag(operation_name)`); the constant
  `Transport::OPERATION_NAME` is now `Transport::OPERATION_NAME_PATTERN`, since
  generated modules define an `OPERATION_NAME` of their own.

Codegen bug fixes from the library review (all with regression coverage):
- Narrowing (`... on X` and nothing else) now reads the match off `__typename`
  when the selection carries it, instead of off "the object came back empty".
  Selecting `__typename` guaranteed a non-empty object, so **every non-matching
  member was cast into `X`'s struct** — loudly when it had a non-null field,
  silently when all its fields were nullable. Regenerate: any query mixing
  `__typename` with a single type condition (the `_entities { __typename
  ... on Widget { … } }` federation shape) was mistyped and now filters
  correctly.
- A dispatched union/interface now requires its `__typename` to be unaliased and
  free of `@skip`/`@include` — `from_h` reads it unguarded, so either would have
  raised at runtime. Fix the selection if generation now refuses it.
- **Unions and interfaces generate per named condition, plus one catch-all
  `Other`** — not one struct per schema member. A two-condition query against
  GitHub's `Node` (278 implementations) went from 5,386 lines / 279 structs to
  162 lines / 4. **Regenerate, and expect member names to move**: a type your
  query names no fields on is now `Other` rather than its own struct, so a
  `case` over the members needs an `Other` branch (`T.absurd` will tell you).
  In exchange, a `__typename` the query doesn't name — including a **member the
  schema grows after you generate** — deserializes into `Other` instead of
  raising `unexpected __typename`, so adding a union member upstream stays the
  non-breaking change GraphQL says it is.
- `@skip`/`@include` on an inline fragment or a named spread now makes the
  fields under it nilable, as it always did for a directly-marked field —
  previously they kept non-null typing and a `data.fetch`, so a skipped block
  raised `key not found`. The narrowing guard sees the fragment's own directive
  too. Conversely, a field selected both conditionally and unconditionally is no
  longer over-nilable: one unguaranteed selection doesn't unmake the guarantee.
- A GraphQL enum used as BOTH a result field and a variable now generates one
  Ruby class, so a value read out of a result can be passed straight back in
  (it used to raise `TypeError: expected T.any(M::Species, String), got
  M::Result::Pet::Species`). **The result-side constant moves**: reach for
  `M::Species::Dog`, not `M::Result::Pet::Species::Dog`, when the enum is also
  a variable type. An enum that appears only in results is unchanged.
- List variables coerce per element, so an enum inside a list accepts its wire
  value the way a scalar enum already did (`sort: ["POPULARITY_DESC"]` used to
  raise `NoMethodError: undefined method 'serialize' for String`). Input-object
  and custom-scalar elements coerce in lists too.

- Federation schemas that previously wouldn't load now do:
  - a supergraph whose `schema` definition carries a non-`@link` directive
    (`@tag`, `@composeDirective`, a composed custom one) no longer dies with a
    `GraphQL::ParseError` pointing into a document you never wrote.
  - **raw subgraph SDL loads** — what `rover subgraph fetch`, `_service { sdl }`,
    or your service repo's `.graphql` gives you. The federation directives a
    subgraph applies but doesn't declare (`@key`, `@external`, `@shareable`, …)
    are supplied on load, for both fed-1 and `@link`-style subgraphs. Note the
    `@inaccessible` subtraction stays supergraph-only: a subgraph keeps those
    fields, because it is not the public contract.
- A schema that won't build now raises `GraphWeaver::Error` naming the artifact
  we took the source for (supergraph / subgraph / plain SDL / introspection),
  instead of whatever graphql-ruby's internals happened to raise — a
  `NoMethodError`, a `ParseError` pointing into a document you never wrote, a
  bare `RuntimeError`. **Rescuing the raw graphql-ruby classes no longer
  catches these.** The `@inaccessible` cascade also prunes a directive
  definition's own arguments.
- **Single-line SDL loads.** `SchemaLoader.load("type Query { hi: String }")` —
  the shape you type in a console — was rejected as "unsupported schema format",
  because a string had to contain a newline to count as content rather than a
  path.
- Rejecting a schema source is branded too, so the error class no longer depends
  on which branch rejected it: an unsupported format and an unreadable file both
  raise `GraphWeaver::Error` (were `ArgumentError` and `Errno::ENOENT`). A bare
  host now says so — `"graphql.anilist.co" looks like a host; did you mean
  "https://graphql.anilist.co"?` — instead of pointing at the file system.
- Cassette recording accepts a `GraphWeaver::Client` — the call
  `docs/cassettes.md` has always shown (`Cassette.use("github", client: live)`),
  which failed with `ArgumentError: missing keywords`. And a client that can't
  `execute` is now rejected on the spot, with its class named, rather than
  surfacing later as `NoMethodError … for an instance of Hash`.
- Generated structs answer `respond_to?` the way `method_missing` behaves, so
  `struct.method(:nmae)` gets the same "did you mean" hint the direct call does.
- `@oneOf` input objects enforce exactly one field. The schema can't express it
  — every `@oneOf` field is nullable — so the struct accepted zero or many and
  the server rejected the round trip; supplying the wrong number now raises
  `GraphWeaver::InputError` naming the type and the keys. **Regenerate** to pick
  it up.
- An enum whose values differ only in case (`enum E { active ACTIVE }`) is
  refused at generation naming both wire values, instead of emitting two
  `Active` constants and raising `RuntimeError: Enum values must be assigned to
  constants` when the file loads. **Map such an enum onto one of yours**
  (`register_enum`). `AB`/`A_B` and `IN_PROGRESS`/`INPROGRESS` still generate
  fine — they name distinct constants.
- A `.graphql` file that won't parse raises `GraphWeaver::ValidationError`
  **naming the file**, instead of a bare `GraphQL::ParseError` whose `[6, 1]`
  pointed into a document you never wrote — fragment inlining parses on the
  `generate!` path before `Codegen#generate`'s rescue could brand it. Fragment
  files get the same treatment.
- Generated `from_response` shape-checks the envelope, so a malformed one stays
  under `GraphWeaver::Error`. A non-object `data`, a `Hash` (or an array of
  strings) for `errors`, and non-object `extensions` all escaped as a raw Sorbet
  `TypeError` — the `data` one from `from_h`'s sig, before the struct's own
  rescue could see it. A body that isn't an object at all deserialized to an
  empty envelope (`String#[]` answers `"data"` with nil); it now raises.
- The generated `from_h` rescues `StandardError`, not just
  `TypeError`/`ArgumentError`/`KeyError` — a registered scalar whose cast raises
  anything else (`JSON::ParserError`, `URI::InvalidURIError`, your
  `Money::ParseError`) escaped the umbrella. **Regenerate** to pick both up.
- A document holding more than one operation is refused at generation. Only the
  first was ever typed, and the whole document went on the wire with no
  `operationName`, so the request came back "Must provide operation name" —
  **split multi-operation files into one operation each.**
- Result keys are checked before they become props, so generation refuses what
  used to be an unloadable file. Two keys that underscore to the same prop
  (`{ name Name: name }` — a plain alias, no exotic schema needed) raised
  `ArgumentError: Attempted to redefine prop :name` at require time; so did a
  field named `class`, `hash`, `send` or `frozen?`, which `T::Props` won't let a
  struct redefine. **Alias the field in the query** (`classValue: class`) — the
  error names the key and the spelling. The same reserved set now covers input
  fields, which only checked Ruby keywords and `serialize`/`to_h` before.
- **Global registrations are validated against the schema**, like client-scoped
  ones always were: `GraphWeaver.extend_type("Medai", …)` (or `register_scalar` /
  `register_enum`) used to be a silent no-op, which is the failure mode
  `docs/getting_started.md` step 3 walks you straight into — it now raises at
  generation with the spellchecked hint. File generation has no client overlay,
  so globals were the only path there and nothing checked them. **If you keep
  registrations for a schema you don't generate against, scope them to their
  client** (`client.register_enum(…)`) rather than registering globally. The
  built-in scalars are exempt — a schema with no `Date` isn't a mistake.
- `extend_type(requires:)` and `register_enum(requires:)` check each path is
  loadable at registration, as `register_scalar(requires:)` already did and
  `docs/scalars.md` already promised — a typo fails now, not in the generated
  file.
- Docs: `docs/testing.md` passed the client to generated `execute` as a `client:`
  kwarg — it's positional. `README.md` had module naming backwards for the
  documented path (a file's module comes from the **file** name, not the
  operation name). `docs/federation.md` covers subgraph SDL, federation v1
  supergraphs, and that `@inaccessible` is subtracted only on the supergraph
  path. `docs/cassettes.md` names `MissingRecording` correctly.
- **Federation namespaces are derived from the schema's own `@link`/`@core`
  declarations** instead of a hardcoded `join__`/`link__`/`core__` list — the
  spec URL's name segment gives the namespace, `as:` renames it, and `import:`
  binds names into the root namespace (`{name: "@key", as: "@myKey"}` included).
  Four things this fixes:
  - a graph using fed-2.5+ auth (`@requiresScopes`/`@policy`/`@context`) no
    longer leaks `federation__Scope`, `federation__Policy` or
    `context__ContextFieldValue` into `schema.types`;
  - a supergraph that renamed a spec (`@link(url: ".../join/v0.3", as: "j")`)
    strips its `j__*` machinery — it previously failed to load at all;
  - **a renamed `@inaccessible`** (`import: [{name: "@inaccessible", as:
    "@private"}]`, or `as:` on the inaccessible spec) hides what it marks. It
    was missed entirely before, so the derived API schema kept fields the
    router does not serve and codegen over-permitted them. **Regenerate** if
    your supergraph renames it.
  - a `@core`-only fed-1 schema, and any composed graph carrying no `@join__`
    marker, is now recognized as composed rather than loaded as plain SDL
    (`core__Purpose` used to survive, and `@inaccessible` went unsubtracted).

- **Subgraph SDL loads with the entity resolver it serves.** No published
  subgraph SDL contains `_entities`/`_service` — `rover subgraph fetch` and
  `_service { sdl }` both print the schema, where the plumbing is implicit — so
  the one query only a subgraph can describe couldn't be typed against the
  artifact you have. Weaver now supplies `_Any`, `_Service` and an `_Entity`
  union over the file's own `@key`'d types, alongside the `@key`/`@external`
  definitions it already supplied. Supergraphs and plain SDL are untouched;
  a file declaring its own `_entities` keeps it.
- **Typed `_entities` representations.** A query selecting entities now
  generates a `Representations` builder per entity it can resolve, typed from
  the `@key(fields:)` directives the subgraph SDL carries:
  `UserQuery::Representations.user(id: "1")` → `{"__typename" => "User", "id"
  => "1"}`. `__typename` is injected, key fields are typed from the schema, and
  a single `@key` makes them **required kwargs** — so an incomplete
  representation is an `srb tc` error, not a round trip. Compound (`"upc sku"`)
  and nested (`"organization { id }"`) key sets are parsed as the selection
  sets they are; a type with two alternative keys takes them optionally and
  raises `GraphWeaver::InputError` naming the type and what's missing when
  neither is satisfied. Builders are emitted only for entities the query
  actually reaches, and a key marked `resolvable: false` gets none.
  **`Representations` joins `Result`/`QUERY` as a reserved module-level name**
  — a shared fragment hoisting to it is now refused.

Transport improvements from the same review:
- **`Transport::HTTP` pools its connections** (`pool_size:`, default 5) instead
  of serializing every request behind one socket and one mutex. The mutex was
  held across the whole network round trip, so one transport — which is what
  `GraphWeaver.client = api` gives a Rails app — allowed exactly one request in
  flight process-wide. Against a 10 ms-latency server, 8 threads × 10 calls:
  1059 ms before, 281 ms with the default pool of 5 (~3.8×). Sockets still open
  lazily, stay keep-alive, and are dropped on any error so the next call
  reconnects. **Lower `pool_size:` if your server counts connections per
  client**; raise it to match a threaded web server's thread count.
- Both transports now send `Accept: application/graphql-response+json,
  application/json;q=0.9` — the media type GraphQL-over-HTTP requires a
  conforming client to accept, so a spec-conformant server can finally use the
  newer status-code semantics — and `User-Agent: graph_weaver/<version>`, so
  server operators can attribute the traffic. Previously the only header sent
  was `Content-Type`, and net/http supplied `Accept: */*`. `headers:` still
  overrides both; a prebuilt `Faraday::Connection` keeps whatever it carries.
- **`Transport::Faraday` takes `open_timeout:`/`read_timeout:` and defaults them
  to 10s/30s**, the same as `Transport::HTTP`. It had no timeout knobs at all,
  so it inherited net/http's 60s/60s — 6× and 2× the documented defaults, on the
  transport an app is *more* likely to get, since Faraday is auto-selected
  whenever it's loaded and it rides in transitively via stripe/octokit. Both
  timeouts now also thread through the client: `GraphWeaver.new(url,
  read_timeout: 5)` works whichever transport is picked. Passing a timeout
  alongside a prebuilt `Faraday::Connection` raises, as `headers:` already did.
  The Faraday transport also logs its adapter at `:info` — the default
  `net_http` one opens a connection per request, which was invisible.
- **New `GraphWeaver::InProcess`**, wrapping a live graphql-ruby schema class —
  `GraphWeaver.new(MySchema, context: { current_user: user })`. In-process
  execution worked but was blind in three ways: nothing supplied a `context:`,
  so a resolver reading `context[:current_user]` got nil (surfacing as "Cannot
  return null for non-nullable field Query.me"); all logging lived in
  `Transport#execute`, which an in-process schema bypasses, so not one line at
  DEBUG; and a resolver raise came out as a bare `RuntimeError` where the same
  failure over HTTP is a `ServerError`, so `rescue GraphWeaver::Error` caught
  one and missed the other. A resolver raise is now a `ServerError` (status
  500) with the original kept as `#cause` — in-process, the real backtrace is
  the point. **A bare schema class still works in any client slot**; the
  wrapper is an upgrade, not a requirement.
- **`ServerError` carries the response `#headers`** (names downcased), plus
  `#retry_after` (seconds or HTTP-date, per RFC 9110) and `#rate_limited?`. The
  `Net::HTTPResponse` was always in hand and thrown away, so recovering
  `x-ratelimit-remaining` or a request id meant monkey-patching the transport.
  A `post` override may now return a third element, the headers; returning the
  documented `[status, body]` pair stays correct.
- **`Retry` honours `Retry-After`** — the server's delay wins over the
  configured backoff, clamped to `max:` and not jittered. Related: **408 and
  429 now retry by default.** They were treated as ordinary 4xx ("your bug,
  retrying won't fix it"), which for the one status that exists to say "come
  back later" was exactly backwards, and left `Retry` incorrect against GitHub
  and Shopify. Pass `retry_if:` to restore the old behaviour.
- **A throttling predicate, spelled the same everywhere**: `ServerError#throttled?`
  (429, or a 503 that says when to come back) and `QueryError#throttled?` /
  `Response#throttled?` (a throttle code in the errors array). An API says "slow
  down" with an HTTP status or with a code in a 200 body, and callers shouldn't
  have to know which. The codes are `GraphWeaver::GraphQLError::THROTTLE_CODES`
  — Shopify's `THROTTLED`, GitHub's `RATE_LIMITED`, and the common Apollo/Hasura
  spellings — so `retry_codes:` takes the constant instead of a hand-written
  string. `QueryError#to_h` gains `"throttled"` alongside `"schema_stale"`.
- `Transport::HTTP` takes `ca_file:`/`ca_path:`/`cert:`/`key:`/`verify_mode:`,
  forwarded to `Net::HTTP.start` — a private CA or mTLS no longer means
  switching to Faraday, which was the real but undiscoverable answer. Passing
  one to an `http://` url raises instead of quietly doing nothing.
- **An instrumentation seam**: `GraphWeaver.instrumenter = ->(event, payload,
  &block) { ... }`, a no-op until set, wrapping every request — over the wire
  and in-process, one seam for both. `ActiveSupport::Notifications` becomes a
  two-line adapter. The one event is `GraphWeaver::EXECUTE_EVENT`; its payload
  carries `:url`, `:schema`, `:operation` and `:status`, and deliberately not
  the query or variables (those are PII, and belong at debug on the logger
  where the level gates them). See `docs/logging.md`.
Developer-experience fixes (all with regression coverage):
- **FakeClient override keys are validated against the schema.** A typo'd key
  (`"Person.nmae" => "Daniel"`) pinned nothing, and the example passed against
  random fake data — a test that had quietly stopped checking what it claims to.
  Keys now raise, spellchecked, at `FakeClient.new` and at `Testing.configure`
  when a schema is already set. Bare field-name keys (`"name"`) still work;
  **fix or drop any key that doesn't name a field in your schema.**
- Codegen validation errors name the position they already captured: each
  message is prefixed `4:5`, and `queries/typo.graphql:4:5` when the file is
  known (`Codegen.new`/`Codegen.generate` take it as `path:`), instead of
  leaving a project of thirty query files to search by hand.
- A strict `alias:` whose path doesn't fit a query now names the query that
  failed and ends with `— pass optional: true to skip selections that don't
  fit`, the documented way out.
- Generation lists the custom scalars it had no registration for at `info`
  (`3 unregistered custom scalars → T.untyped: …`). Informational — a scalar
  without a codec is a legitimate choice, just no longer a silent one.
- `Response#ok?` (and `#success?`) — the positive form of `errors?`.
- `FakeClient#schema` reads back the schema responses are fabricated against,
  which is how to reach it under `auto_fake`, where `GraphWeaver.client` is the
  fake; `Testing.config.schema` reads back too.
New:
- **`rake graph_weaver:schema:check` — which of your queries a schema change
  broke.** Re-introspects the url the dump records (leaving the dump alone) and
  validates every checked-in `.graphql` against the server as it is now,
  reporting file plus line:col plus message and exiting non-zero on any
  failure, so it drops into CI. `GraphWeaver.check_queries` returns the same
  thing as data (`{path => [{"message", "line", "column"}]}`, empty when
  everything validates); pass `schema:` to check a schema you already have
  without touching the network. Complements `graph_weaver:verify`, which asks
  the different question of whether the committed Ruby is stale.
- `verify_generated!` (and `rake graph_weaver:verify`) compares generated files
  with line endings normalized, so a checkout under git's `autocrlf` no longer
  reports every generated file as stale.
- New [editor support](docs/editors.md) doc: the `graphql.config.yml` that gives
  VS Code and RubyMine validation, autocomplete and hover docs in your
  `.graphql` files — no JS project, no gem code, five lines of YAML.
- **Byte-identical generation is now a stated guarantee**, not just a property:
  the same schema and queries produce the same files on any machine, in any
  order (`docs/generated_modules.md`). It was already true and spec-enforced;
  it was documented nowhere.

**Faraday is no longer auto-selected — `GraphWeaver.new(url)` always builds
`Transport::HTTP`.** Selection used to be `defined?(::Faraday)`, and faraday
rides into most bundles transitively (stripe, octokit, ...), so adding an
unrelated gem silently swapped your transport, its timeouts, and its connection
behaviour. The accidental default was also the slower one: `Transport::HTTP`
pools persistent sockets (1 TCP connection for 10 requests) where Faraday's
default `net_http` adapter reconnects per request (10 for 10) — a full TLS
handshake each time over HTTPS.

**What you must do:** if you were relying on the auto-pick, ask for Faraday
explicitly — `GraphWeaver.new(url, transport: :faraday)`. A middleware block
still implies it (`GraphWeaver.new(url) { |conn| ... }`), since the block is
Faraday's. Faraday is otherwise unchanged and fully supported. Alongside a url,
`transport:` now takes `:http` (the default) or `:faraday` rather than a
built transport object — passing an object there used to raise "pass a url or
transport:, not both" and now raises naming the two symbols. Alongside a schema
source it still takes a built transport, and now rejects a Symbol. The client
logs which transport it built at `info`.

`docs/transports.md` gains the recipe for giving Faraday the connection reuse
`Transport::HTTP` has by default: the `:net_http_persistent` adapter, the two
gems it needs, and the version pairing (Faraday 2.x requires
`faraday-net_http_persistent` **2.x**; 1.2.0 raises `NoMethodError: undefined
method 'dependency'` at load). graph_weaver depends on neither and never
selects it for you.

**Generated files are pruned when their query disappears.** Renaming or
deleting a `.graphql` used to leave its `.rb` behind forever: `load_generated!`
kept requiring it, its module kept resolving against a query that no longer
existed, and `verify_generated!` stayed silent — the pruning only covered
`inputs/*.rb` and `unions.rb`. `generate!` now deletes any generated file the
plan no longer produces, and `verify_generated!` reports it as stale.

Only files carrying the `# Generated by GraphWeaver — do not edit.` header are
ever deleted, so a hand-written file in the output directory survives. **What
you must do:** nothing, unless you were relying on a lingering module — the
next `generate!` removes it, and CI's `rake graph_weaver:verify` will name it
first.

**Mutations now generate `…Mutation` modules, not `…Query`.**
`save_list_entry.graphql` holding a `mutation` produces
`SaveListEntryMutation` in `save_list_entry_mutation.rb`;
`SaveListEntryQuery.execute!` read wrong for a write. Queries are unchanged.
The rule is one rule — the camelized file name plus the operation the file
defines — and all three naming sites follow it: `generate!`,
`GraphWeaver.parse(path)`, and `client.load_queries!`. The operation name
written *inside* the file still names nothing; it goes on the wire as
`operationName`.

**What you must do:** regenerate (`rake graph_weaver:generate`) and rename the
call sites of any mutation module — `AdoptQuery` → `AdoptMutation`, including
nested constants like `AdoptQuery::AdoptionInput`. Regeneration prunes the old
`*_query.rb` files, and `rake graph_weaver:verify` names anything missed.
Changing a file's `query` to `mutation` from here on renames its constant the
same way, which CI now catches rather than letting it drift.

**Generated modules get their client plumbing from
`GraphWeaver::QueryModule`.** `client`/`client=` carry no per-query type
information, so every generated file repeated the same fifteen untyped lines;
they now live in the gem, beside the input-struct runtime, and a module says
`extend GraphWeaver::QueryModule` instead. `execute`, `execute!`,
`from_response` and `from_response!` stay generated — their sigs are your
query's types. A baked `client:` constant is emitted as `DEFAULT_CLIENT`,
still resolved on first use so a module can load before the initializer that
builds its client, and resolution is unchanged: per call → per module → baked
constant → `GraphWeaver.client`.

**What you must do:** regenerate (`rake graph_weaver:generate`). The files
change; nothing about how you call them does.
Error-message and console ergonomics from the same review:
- **Validation errors name the query file and render one per line**, compiler
  style — `invalid query in app/graphql/queries/person.graphql:` followed by an
  indented `4:5  Field 'nmae' doesn't exist on type 'Person'` per error. They
  arrived as one joined line with no file at all, because `generate!` had the
  path in hand and never passed it to codegen, so thirty query files left you
  hunting for a bare `4:5`. `ValidationError#errors` and `#to_h` keep the shape
  `rake graph_weaver:schema:check` reads; only the message text changed, and
  **it is multi-line now** — update anything matching on it.
- **`register_enum("Species", PetKind, {"DOG" => :dog})` says the value map is a
  keyword**, and shows the call with `map:` in it. Guessing the map as a third
  positional argument used to get Ruby's `wrong number of arguments (given 3,
  expected 2)`, which never mentions `map:`. Both `GraphWeaver.register_enum`
  and `client.register_enum`.
- **`load_queries!` logs when it replaces an already-loaded module**, at
  `:info`, before swapping the constant: `replacing PersonQuery — objects built
  from the previous module stay instances of it`. Reloading is unchanged and
  still what the method is for; it just isn't silent about the structs it
  orphans, which is how a console session ends up with an `is_a?` that fails
  for no visible reason.
**Rails install generator.**
`rails g graph_weaver:install --url=https://api.example.com/graphql` writes
`config/initializers/graph_weaver.rb`, the `app/graphql/queries` and
`app/graphql/generated` directories, `graphql.config.yml` (schema autocomplete
and validation for `.graphql` files in VS Code / RubyMine) and the schema dump
— replacing the console step the getting-started guide used to open with.
`--auth` names the ENV var holding the token (default `GRAPHWEAVER_AUTH`),
`--no-schema` skips the introspection. Re-running prompts on conflict like any
Rails generator.

**`rake graph_weaver:schema:refresh` can now create the first dump.** It read
its url from an existing dump's provenance stamp, so it couldn't bootstrap one
— pass `URL=https://api.example.com/graphql` and it will, and both the
no-dump and no-provenance messages now name that fix. The same logic is
`GraphWeaver::SchemaLoader.refresh!(url:, auth:)`, which is what the generator
calls.

###  v0.4.6  (2026-07-30)
Bug fixes from a full-library review (all with regression coverage):
- alias: a nested-object/enum leaf (`meta.sub`) now qualifies its constant
  (`Meta::Sub`) instead of emitting a bare `Sub` that raised NameError; alias
  names/segments are validated as identifiers (were interpolated verbatim,
  allowing injection); `optional:` no longer swallows a reserved-name/collision
  mistake; a real field named `first`/`last` resolves as a field.
- Shared unions: a hoisted member selecting a mapped enum now emits its
  `<NAME>_FROM_WIRE` table into `unions.rb` (was a NameError at `from_h`); a
  fragment whose name collides with `Result`/`QUERY` is refused.
- A named interface fragment holding inline `... on X` conditions now dispatches
  instead of silently dropping those fields; fragment cycles raise a clear error
  in the FakeClient/Anonymizer walkers instead of `SystemStackError`.
- Malformed responses/inputs stay under `GraphWeaver::Error`: a non-2xx
  `errors: null` body keeps its status; a 2xx non-object body is a `ServerError`;
  `data!` on null-data/no-errors raises `QueryError`; `coerce(non-Hash)` raises
  `InputError`.
- Testing harness: FakeClient/Anonymizer merge duplicate result keys (were
  fabricating shapes the generated struct couldn't cast); `fail_at` fires every
  execute; symbol-keyed cassette variables no longer crash on reload; the
  Anonymizer keeps concrete-fragment fields when data lacks `__typename`.
- Federation: a user type named `link` is no longer dropped; an all-`@inaccessible`
  schema raises a pointed error. Client accepts `retries: nil` on a schema
  source; `register_scalar` rejects an anonymous class.
- FakeClient: an Integer `list_size` now means exactly that length (a Range
  randomizes within it). Codegen rejects two variables that underscore to the
  same kwarg (`$userId` + `$user_id`). The Faraday transport raises rather than
  silently dropping `headers:`/block when handed a prebuilt connection.

###  v0.4.5  (2026-07-30)
- `alias:` paths gain list-element selectors: a `first`/`last` segment picks one
  element out of a list hop, always nilable — `alias: { entity: "_entities.first" }`
  yields `def entity = _entities&.first`, and navigation continues into the
  element (`_entities.first.name`). Typed from the selection: a single inline
  fragment lands on the concrete member (`T.nilable(Widget)`), a multi-fragment
  selection on the union. Selectors are checked against the node shape — `.first`
  on a non-list raises. Cleanly retires the `result._entities&.first&.field`
  boilerplate of single-entity federation `_entities` queries.
- `extend_type(..., optional: true)` makes its aliases lenient: a query whose
  selection doesn't fit the path omits the accessor instead of failing
  generation. For an alias on a universal type (a `Query` accessor a strict alias
  would force every query to satisfy), or one that only fits some selections.

###  v0.4.4  (2026-07-30)
- Supergraph loading now derives the **API schema**: `@inaccessible` elements
  (present in the federated graph but hidden from what the router serves) are
  removed on load, cascading — a field/argument/union-member/interface
  referencing a removed type goes too, and a type left empty is removed in turn.
  So codegen validates against exactly what clients can query, with no
  over-permitting and no Apollo JS tooling to subtract the API schema first.
  Plain (non-federation) SDL is untouched.

###  v0.4.3  (2026-07-30)
- Federation-aware supergraph loading: `SchemaLoader` (and `Client.new`) now
  load a composed Apollo Federation v2 supergraph SDL directly. When the `@join__*`
  markers are present it strips the composition machinery — the synthetic
  `join__*`/`link__*` types and directive definitions, and every `@join__*`/`@link`
  application — via an AST rewrite before `from_definition`, so the merged type
  shapes load cleanly with nothing federation-internal leaking into
  `schema.types`. Plain SDL is untouched. A query can now be typed against the
  composed supergraph, not just per-subgraph schema objects.
- Removed `directive_defaults_patch.rb` (the graphql-ruby monkeypatch); the
  preprocessor supersedes it and `graphql-ruby` fixed the underlying issue. The
  gem now requires `graphql >= 2.6.7`.

###  v0.4.2  (2026-07-30)
- `extend_type` accepts `alias:` — project a selected field (possibly nested)
  onto a flat, typed accessor emitted into the struct body:
  `extend_type("Widget", alias: { tag: "meta.tag" })` generates a sig'd
  `def tag = meta&.tag`. Retires hand-written value objects that only flattened
  a passthrough field. Takes a `{ name => path }` hash, a bare path string
  (accessor named after the last segment), or an array of paths. Typed from the
  selection — a nullable hop makes the accessor nilable and nil-safe; the leaf
  may be a scalar, enum, or nested struct. Validated per query at generation: an
  unselected/misspelled segment (with `did you mean`), a list hop, or a name
  collision raises. Stacks and is client-scopable like the mixin forms.

###  v0.4.1  (2026-07-29)
- Generated `execute!` forwards its kwargs to `execute` via hash shorthand
  (`execute(client, name:, species:)` rather than `name: name, species: species`)
  — cosmetic only. Regenerate to refresh (`verify` flags the drift otherwise).

###  v0.4.0  (2026-07-28)
- Shared unions: when a named shared fragment is the whole selection on a union
  field (`feed { ...FeedItemFields }`), its type is hoisted once into a
  `GraphQLUnions` module and every query that spreads it aliases the same type —
  so a union selected across many queries is one Ruby type family (one
  exhaustive `case … T.absurd`), not a fresh dispatch module per query. No flag:
  the shared fragment is the opt-in. Triggers only for an exact lone spread;
  mixing other fields, or shadowing with a query-local fragment, keeps the union
  inlined. Module name derives from the output path (override with
  `GraphWeaver.unions_module=`); dynamic `parse` still inlines.
- Removed the `shared_inputs:` option from `generate!` / `verify_generated!`.
  Directory-based generation always emits each input type once into a shared
  module — the self-contained-module opt-out added complexity for little value.
  Single-query `parse` / `Codegen.generate` still inline their types (there's
  no set to share against). Only affects callers who passed
  `shared_inputs: false`.

###  v0.3.4  (2026-07-29)
- Shared fragments: define reusable named fragments once (default
  `app/graphql/fragments`, configurable via `GraphWeaver.fragments_paths`) and
  spread them from any query. Each query inlines only the fragments it
  transitively spreads, so the sent query stays self-contained. Fragment files
  hold only fragments; names are unique across them. Works in `generate!` and
  dynamic `parse`.

###  v0.3.3  (2026-07-29)
- Union member-type dedup: a union selected more than once on a struct now
  collapses to one Ruby type family instead of a distinct per-field family with
  identical members — so a consumer gets a single exhaustive
  `case … T.absurd` across every field of that union. Structurally different
  selections stay distinct types. (First cut: same-struct siblings; regenerate
  checked-in modules to pick it up.)

###  v0.3.2  (2026-07-29)
- `register_scalar` accepts a `Type.field` coordinate to override how one
  field's scalar deserializes — so the same scalar can be different Ruby types
  across fields (`register_scalar("User.birthday", Date)` while
  `ISO8601DateTime` stays a `Time` elsewhere). Field overrides win over the
  scalar-name registration; both stack global-then-client. The coordinate is
  validated against the schema (a typo'd or non-scalar field raises). Same
  method, same signature — a `.` in the name selects the field form.

###  v0.3.1  (2026-07-28)
- `GraphWeaver.extend_t_sig` controls whether generated modules/structs emit
  `extend T::Sig`. Default (`nil`) auto-detects a global T::Sig injection
  (`class Module; include T::Sig`) and skips the now-redundant `extend` — so
  generated code stays clean under rubocop's `Sorbet/RedundantExtendTSig`.
  Force with `true`/`false`; `false` requires the global include.

###  v0.3.0  (2026-07-28)
- Renamed `register_type` to `extend_type` to disambiguate intent: it
  *decorates* a generated struct with mixin modules/helpers — it doesn't
  define or replace a type's deserialization (that's `register_scalar` /
  `register_enum`, for leaf types, whose Ruby shape is fixed; a composite's
  shape is per-query, so there's nothing fixed to replace). No deprecation —
  the old name is dropped.
- Invalid query input now raises `GraphWeaver::InputError` (under the
  `GraphWeaver::Error` umbrella) instead of a raw `ArgumentError` /
  `KeyError` / sorbet `TypeError`: an unknown or typo'd input key, a
  missing required field, an out-of-range enum, or a wrong-typed field
  when an input object is built from a hash through `coerce`. Carries
  `#field` / `#struct` and a JSON-ready `#to_h` — one rescue point for
  returning a 422 at an API boundary. Top-level *scalar* kwargs still
  fail like any Ruby method call (sorbet `TypeError` / `ArgumentError`).

###  v0.2.2  (2026-07-22)
- Generated modules expose from_response / from_response! alongside
  execute / execute!: deserialize a raw GraphQL response (fetched by any
  client) into the typed envelope without going through the transport.
  execute now delegates to from_response

###  v0.2.1  (2026-07-13)
- Conventional paths are appendable lists: queries_paths /
  generated_paths (singular accessors read the first entry, so existing
  config keeps working); load_generated!, Client#load_queries!, and the
  Railtie walk every entry — append spec/support/graphql/* from a spec
  helper to load test-only queries. Entries may be globs, and the
  generated default includes app/graphql/*/generated so per-schema
  layouts auto-load
- inputs_module derives from the output path: multi-schema layouts name
  each schema's module after its directory
  (app/graphql/github/generated -> GithubInputs), the conventional
  layout keeps GraphQLInputs; GraphWeaver.inputs_module= and
  generate!(inputs_module:) still override
- Shared types split one-file-per-type: generated/inputs/ holds each
  input struct/enum in its own small file (PokeAPI: 573 files, median
  24 lines vs one 11.5k-line blob) with inputs.rb as the manifest
  (forward declarations make load order irrelevant); regeneration
  prunes files for types the schema dropped, verify flags strays;
  generate!/verify take inputs_module: per invocation (multi-schema
  apps generate into different modules)
- Shared input types: generate! emits every variable type (input
  structs + their enums + mapped-enum tables) ONCE per schema into
  generated/inputs.rb (module GraphQLInputs; GraphWeaver.inputs_module=
  renames, shared_inputs: false opts out), with query modules aliasing
  only what their own surface references — AdoptQuery::AdoptionInput
  keeps working and shared types gain one identity across modules.
  Three filtered Hasura queries: 34,684 lines inline -> 11,754 shared
  (~90 lines per query module)
- BREAKING (vs 0.2.0): auto_fake is opt-in again — require
  "graph_weaver/rspec" no longer swaps every example onto a fake;
  set config.auto_fake = true explicitly (the schema still auto-locates
  once you do). Less magic, no unexpected behavior
- Generated input structs are table-driven: typed consts + a per-field
  FIELDS table (conversions as lambdas) interpreted by the
  GraphWeaver::InputStruct runtime, replacing unrolled
  serialize/coerce/value_at per struct — a bool_exp-heavy PokeAPI module
  shrinks 29k -> 11.5k lines (-60%) with identical behavior (nil
  omission, wire-value enums, nested/recursive coercion, spellchecked
  unknown keys all covered by the existing suite)
- Internal: Node base class for the codegen IR protocol; module
  assembly moved from Codegen#generate into Emit#emit_module
  (byte-identical output)

###  v0.2.0  (2026-07-12)
- Cleanup pass (staff-engineer review): scalar registrations get the
  same typo validation as enums/types; cassette replay stops recomputing
  its key per entry; dependency-order DFS uses hash bookkeeping (big
  bool_exp graphs); require/vocabulary residue swept; the vestigial
  graph_weaver/testing/rspec shim removed
- BREAKING: "client" replaces "executor" across the whole surface.
  Generated modules: the per-call override is an optional POSITIONAL
  first argument — PersonQuery.execute(github, id: "1") — so variables
  own the entire kwarg namespace and NOTHING is reserved (a $client or
  $executor variable is fine; only Ruby keywords refuse); per-module is
  MyQuery.client=, the baked param is client:. GraphWeaver.executor= is
  gone — GraphWeaver.client= is the one ambient slot (auto_fake swaps
  it per example; explicit clients are self-contained and never see it).
  Client#executor is now Client#transport (transport: to bring your
  own); SchemaLoader.introspect/stale? speak transport. Renames:
  FakeExecutor => Testing::FakeClient, SequenceExecutor =>
  Testing::Sequence, RetryExecutor => GraphWeaver::Retry,
  Recording/ReplayExecutor => Recorder/Replayer, Cassette.use(client:)
- Live federation integration: two Ruby subgraphs (apollo-federation
  gem) composed and routed by a real Apollo gateway (node harness under
  spec/support/federation), with GraphWeaver introspecting through the
  router and executing a query stitched across BOTH subgraphs — part of
  make integration. Complements the existing supergraph-SDL codegen spec
- graphql-over-http: a non-2xx response carrying a GraphQL errors body
  (Apollo Server/Router send request errors as 4xx JSON) flows into the
  Response envelope so QueryError sees the structured errors; only
  non-GraphQL bodies (proxy pages) raise ServerError
- Fix: input-struct serialize used bare locals (result/value) that a
  same-named prop silently shadowed — a field named "result" dropped
  its value onto the wrong target; generated locals now wear the
  reserved __gw prefix (GraphQL reserves __-names, so no collision is
  possible)
- Input fields and variables whose Ruby name would be a keyword
  (nil/def/end/...), a generated method (serialize/to_h), or the
  reserved executor kwarg now refuse at generation with a pointed
  error instead of emitting broken code
- Non-JSON 200 bodies (proxy error pages) classify as ServerError, and
  unserializable variables (NaN/Infinity) raise GraphWeaver::Error —
  raw JSON::* errors no longer escape the umbrella
- Transports redact on inspect/to_s (class + url only) — Authorization
  headers can't leak through logs or exception dumps
- Narrowed `... on X` selections require at least one unconditional
  field: with every field behind @skip/@include, a matching response is
  {} — byte-identical to a non-match — so generation refuses rather
  than silently dropping real matches to nil
- Integration spec against Hasura's PokeAPI: snake_case codegen,
  recursive bool_exp variable filtering, untyped jsonb pass-through
  (make integration)
- BREAKING: ValidationError now descends from GraphWeaver::Error (was
  ArgumentError) — one `rescue GraphWeaver::Error` catches everything
- Input-struct .coerce raises on unknown hash keys with a spellchecked
  hint — a typo'd filter key no longer silently drops off the wire
- Client registrations (register_type/register_enum) validate at the
  call site when the schema is already loaded; lazy clients still
  validate at generation
- Unregistered custom scalars emit bare T.untyped (not
  T.nilable(T.untyped), an srb tc error under typed: strict)
- Wire log lines carry [req N OperationName] tags; long queries
  (introspection) truncate at debug
- Logging: GraphWeaver.logger (any stdlib-compatible Logger; Rails.logger
  auto-wired by the railtie) — wire traffic + timings at debug,
  introspection/cache/codegen at info, every raised error at warn
- Recursive input types generate — self- and mutually-referential inputs
  (Hasura's bool_exp filter surface) emit dependency-ordered structs with
  runtime forward declarations for cycles, so variable-driven Hasura
  filtering works; previously raised "recursive input type"
- Fix: snake_case GraphQL type names (Hasura, PostGraphile) camelize
  into valid Ruby constants — pokemon_v2_pokemon => PokemonV2Pokemon
  (previously generated a SyntaxError); wire names (__typename dispatch,
  registry keys) are untouched
- Everything raised is rescuable: unparseable queries wrap as
  ValidationError (GraphQL::ParseError no longer leaks), and internal
  NotImplementedError raises (recursive inputs, unsupported kinds,
  subscriptions) became GraphWeaver::Error
- Transport::HTTP takes open_timeout:/read_timeout: (defaults 10s/30s);
  timeouts surface as retriable TransportError
- Transport::HTTP reuses its connection (keep-alive, mutex-serialized,
  keep_alive_timeout: for the idle window); any failure drops the socket
  so the next call starts fresh
- GraphQLError#code also reads a top-level "type" (GitHub's dialect:
  NOT_FOUND, FORBIDDEN) when extensions.code is absent
- Typo'd client-scoped registrations raise at generation with a
  spellchecked hint (register_type("Pett") => "did you mean 'Pet'?")
  instead of silently no-oping
- Abstract selections narrow: __typename is only required when the
  selection varies by concrete type. Interface-level-fields-only
  selections generate one shared struct (no dispatch); a single
  `... on X` condition generates X's struct, always nilable — a
  non-matching runtime type casts to nil, so narrowing doubles as
  filtering
- Zero-config rspec: require "graph_weaver/rspec" now defaults
  auto_fake on and auto-locates the schema from the committed dump
  (config.schema= / config.auto_fake = false to override) — one line is
  the whole test setup in a conventional app
- examples/: runnable demos, all directly executable — countries.rb
  (public API, no auth, all dynamic), rick_and_morty.rb (filtered
  search, pagination, a block-built type helper), and github/ (auth,
  checked-in generated modules; stars the repo ⭐ then tours the
  stargazers, their top repos, and what else they've starred); excluded
  from the gem package
- Fix: requires: now load before codec probing, so inference sees
  methods the required file provides — register_scalar("DateTime", Time,
  requires: "time") correctly infers Time.parse in a fresh process
  (previously the cast was silently skipped unless "time" was already
  loaded)
- docs/quickstart.md renamed to docs/getting_started.md
- Rails Railtie: the graph_weaver:* rake tasks self-register (no
  Rakefile edit) and depend on :environment, and generated modules load
  at boot (after initializers) when generated_path exists; outside
  Rails, require "graph_weaver/tasks" and call load_generated! as before
- BREAKING (vs 0.1.0): reset_scalars! lost its coerce: flavor —
  GraphWeaver.auto_coerce = true is the one way to default-coerce
  (broader: convertible built-ins AND full cast/serialize scalars,
  resolved lazily, per-registration coerce: still wins)
- GraphWeaver.client= — the blessed global wiring: assign the app's
  default client and generated modules resolve through it (per call ->
  per module -> baked -> executor= -> client). executor= stays as the
  low-level override, so test fakes still win
- Enum mappings: register_enum("Species", PetKind) (+ bulk
  register_enums, client-scoped variants) — generated code speaks YOUR
  T::Enum, with the wire mapping inferred by name, pinned via map:,
  exhaustiveness-checked at generation (fails naming gaps), and
  fallback: to absorb unknown wire values on cast (inputs stay strict);
  translation tables emitted into the source (X_FROM_WIRE / X_TO_WIRE)
- Type helpers: register_type("Pet", PetHelpers) (global or
  client-scoped, additive) — app-owned modules included into every
  struct generated from that GraphQL type, so derived values live as
  methods beside the honest wire data and srb tc checks them against
  each query's selection. Or build the mixin inline with a block
  (module_eval'd into an auto-named GraphWeaver::TypeHelpers constant —
  quick decoration, invisible to srb tc)
- BREAKING (vs 0.1.0): register_scalar takes the type positionally —
  register_scalar("Money", Money, requires: ...) — matching the new
  registrars: the GraphQL name + your Ruby type up front, options as
  kwargs
- GraphWeaver::Client — transport, schema, and scalars for one server in
  one object: GraphWeaver.new(url_or_schema) takes a url (transport
  built, schema introspected lazily per cache:/ttl:) or a schema source
  (live class — also the in-process executor — or a path/SDL/dump);
  #parse and #execute/#execute! bind the implicit schema + transport;
  #register_scalar scopes scalar mappings to the client (overlaying the
  global registry), so two servers can disagree about a scalar type
- BREAKING: GraphWeaver.connect removed — GraphWeaver.new(url) replaces
  it (wire generated modules with GraphWeaver.executor = client.executor)
- BREAKING: the one-shots are now GraphWeaver.execute(url_or_schema,
  query, **variables) / execute! — Client#execute on a throwaway client;
  variables are plain kwargs, as on a generated module
- Client#load_queries! — parse every query file into modules named like
  generation would name them (reloadable; namespace: to scope): the
  no-build-step analog of generate! + load_generated!
- Introspected schema dumps record provenance (source url + timestamp):
  a parsable SDL header comment, a "graph_weaver" sibling key in JSON —
  read it back with SchemaLoader.provenance(path), check drift with
  SchemaLoader.stale?(path) or rake graph_weaver:schema:verify, rewrite
  with rake graph_weaver:schema:refresh (GRAPHWEAVER_AUTH for tokens)
- generate!/verify_generated!/rake auto-locate the schema dump at
  schema_path in any supported format; SchemaLoader.locate is public
- Calling a result field by its camelCase wire name raises a pointed
  NoMethodError naming the snake_case prop that does exist
  (result.addPet => "use 'add_pet'"), and near-miss typos in either
  casing get a spellchecked suggestion (result.addPt => "did you mean
  'add_pet'?") — the runtime companion to srb tc's static flag
- BREAKING: an operation whose only variable is a required input object
  (the Relay convention) now flattens the input's fields into execute's
  kwargs — AdoptQuery.execute!(name:, species:) instead of
  execute!(input: {...}); multi-variable / nullable-input operations
  keep the input: kwarg (struct or hash)
- Enum kwargs accept the T::Enum or its wire value (T.any(Enum, String))
  everywhere — variables now match input-hash fields
- BREAKING: HttpExecutor / FaradayExecutor are now Transport::HTTP /
  Transport::Faraday, subclasses of the new abstract GraphWeaver::Transport
  base, which owns the shared flow (encode, TransportError reclassify,
  non-2xx ServerError, parse) — a custom transport just implements
  post(body) => [status, body]. Opt-in require moved:
  "graph_weaver/faraday_executor" -> "graph_weaver/transport/faraday"
- SchemaLoader.introspect cache: reuses a fresh dump in ANY supported
  format before re-introspecting (an existing schema.graphql wins over
  writing schema.json), and accepts :json / :graphql / :gql to pick the
  format at GraphWeaver.schema_path's location
- rubydoc.info rendering: ship .yardopts (markdown markup, docs/ guides
  as extra files) and re-indent docstring examples so code blocks and
  backticks render; make docs previews locally
- GraphWeaver.connect(url, auth:, headers:, retries:): one-shot setup —
  best transport (Faraday when the app loads it; detection is defined?,
  never a require), bearer/verbatim auth, opt-in RetryExecutor wrapping
  (true / options Hash; off by default), wired in as the global executor
- Generation workflow: GraphWeaver.generate! (queries dir -> generated
  dir), verify_generated! (the freshness guard — raises naming stale
  files), load_generated! (factory_bot-style explicit loading), rake
  tasks (require "graph_weaver/tasks": graph_weaver:generate / :verify),
  all defaulting to configurable conventional paths (queries_path /
  generated_path / schema_path)
- GraphWeaver.auto_coerce = true: default input coercion for scalars
  without an explicit coerce:, resolved lazily at generation time (no
  reset_scalars! ordering dance) — convertible built-ins take their
  conversion, cast/serialize pairs take parse-style coercion
- SchemaLoader.introspect cache: true — caches at GraphWeaver.schema_path,
  in the format the extension picks: .json (verbatim wire artifact) or
  .graphql/.gql (SDL — human-readable, PR-reviewable diffs);
  the same dump rake graph_weaver:generate reads
- docs/transports.md: connect, the executor contract, Faraday, retries
- Cassette workflow: GRAPHWEAVER_RECORD=1 / config.record force
  re-recording; config.anonymize scrubs responses as they are recorded
  (caller sees the anonymized data too, so assertions hold on replay);
  rake graph_weaver:cassettes:anonymize; docs/cassettes.md guide
- auto_coerce reaches input-object fields: raw scalar values inside
  input hashes coerce via the registry, mutations included
- RetryExecutor: composable retries over any transport — tries:,
  exponential/linear/custom backoff with jitter and max clamp,
  retry-by-error-class (5xx yes, 4xx no by default; retry_if: override)
  and retry-by-GraphQL-code (retry_codes: ["THROTTLED"])

###  v0.1.0  (2026-07-11)
- Structured errors: execute returns a typed Response envelope (#data/#data!,
  #errors, #errors?, #extensions) instead of raising on GraphQL errors, so
  partial data and top-level extensions (cost/throttle) survive. Error classes
  under GraphWeaver::Error — TransportError (network), ServerError (non-2xx
  HTTP, #status/#body), QueryError (#errors/#data/#extensions/#codes),
  ValidationError (build-time) — plus a GraphQLError value object with #code.
  Transport-error classification is an extensible Set (GraphWeaver.transport_errors
  / register_transport_error): each transport seeds its own network exceptions
  and apps can add more (e.g. a connection-pool timeout).
  The envelope is a single generic GraphWeaver::Response[Result] (no per-query
  wrapper class). execute! is the shortcut for execute(...).data! — the typed
  result or a raised QueryError — on both generated modules and the one-shot
  GraphWeaver.execute!/execute.
  BREAKING: module #execute returns Response; use #execute! (or #data!) for
  the old raise-or-result behavior. GraphWeaver.execute now returns the
  envelope too; GraphWeaver.execute! returns the result.
- GraphWeaver.register_scalar: custom scalar deserialization into rich Ruby
  objects. cast/serialize inferred from a class type via paired codecs
  (.parse/#to_s or .load/.dump), or given as a Symbol/Proc (:itself opts out);
  requires: emits (validated, and require-checked when type: is a class)
  requires into generated source — the built-in Date scalar carries
  require "date" so Date-using queries are self-contained; coerce: true lets a
  variable accept the value or its raw input (coerce: :to_f for a built-in
  conversion), casting/converting the latter — reset_scalars!(coerce: true)
  reloads the built-ins coercible; built-in scalars pre-registered in one
  overridable registry (reset_scalars!/clear_scalars!)
- FaradayExecutor: url, Faraday connection, or middleware block
- GraphWeaver.executor default transport; per-module executor= override
- GraphWeaver.parse and GraphWeaver.execute (dynamic queries)
- Codegen.generate shorthand; executor: takes a constant; module_name
  derived from operation or file name
- Error ergonomics: schema_stale? (validation-shaped rejections hint at
  regeneration), errors_at(path) + each_error/errors_by_field filtering,
  #report (field-keyed rollup with entity ids resolved from partial
  data), #to_h across the hierarchy (JSON-ready machine output), and
  GraphWeaver::TypeError wrapping cast failures with the failing struct
- SchemaLoader: introspect(executor, cache:, ttl:) fetches schemas from
  live endpoints with file caching; load accepts introspection JSON /
  SDL content / Hashes as well as paths (cache round-trips)
- GraphWeaver::Testing (require "graph_weaver/testing", or
  "graph_weaver/rspec" for the rspec integration): FakeExecutor
  fabricates schema-correct castable responses (mode: :faker semantic
  values / :literal; overrides by GraphQL name; seeded; list_size /
  null_chance), failure simulation (Failure.transport/server/graphql/
  throttled/stale_schema, SequenceExecutor for retries, fail_at: with
  spec-correct null propagation, corrupt: for derived type mismatches),
  cassette record/replay above the transport, and Cassette#anonymize!
  (shape-preserving, consistent id mapping). rspec: seed follows
  --seed; auto_fake installs a fake executor per example
- one-off integration specs against live GitHub + Countries APIs
  (make integration)
- Input objects: INPUT_OBJECT variables generate module-level T::Structs
  with serialize (aliased to_h) producing the wire hash; execute kwargs
  also accept plain hashes, normalized + type-checked via the generated
  .coerce (underscored Symbol/String keys, enums as instances or wire
  values, nested inputs as hashes)
- fields under @skip/@include generate nilable regardless of schema
  nullability; FakeExecutor honors first/last/limit when sizing lists
- eval hardening for parse: module names must be constant names, and
  QUERY heredocs can't be terminated early by block strings
- GraphWeaver::Selection: one shared query-walk (codegen, FakeExecutor,
  anonymizer); codegen split into scalar_type / nodes / emit
- docs/: generated_modules, real_world, scalars, errors, testing;
  README slimmed to pitch + quickstart

###  v0.0.1  (2026-07-07)
- voila: typed codegen (T::Structs, T::Enums, typed variable kwargs)
- queries + mutations; fragments, unions, interfaces, enums, custom scalars
- schema sources: live class, introspection JSON, SDL (incl. supergraph)
- pluggable executor: in-process schema or HTTP
- dynamic (no-build) mode for development
