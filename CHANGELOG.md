###  unreleased
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
