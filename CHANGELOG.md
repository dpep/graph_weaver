###  v0.0.2  (unreleased)
- GraphWeaver.register_scalar: custom scalar deserialization into rich Ruby
  objects. cast/serialize inferred from a class type via paired codecs
  (.parse/#to_s or .load/.dump), or given as a Symbol/Proc (:itself opts out);
  requires: emits (validated, and require-checked when type: is a class)
  requires into generated source — the built-in Date scalar carries
  require "date" so Date-using queries are self-contained; coerce: true lets a
  variable accept the value or its raw input, casting the latter; built-in
  scalars pre-registered in one overridable registry (reset_scalars!/clear_scalars!)
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
