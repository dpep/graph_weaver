###  v0.0.2  (unreleased)
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

###  v0.0.1  (2026-07-07)
- voila: typed codegen (T::Structs, T::Enums, typed variable kwargs)
- queries + mutations; fragments, unions, interfaces, enums, custom scalars
- schema sources: live class, introspection JSON, SDL (incl. supergraph)
- pluggable executor: in-process schema or HTTP
- dynamic (no-build) mode for development
