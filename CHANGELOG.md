###  unreleased
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
