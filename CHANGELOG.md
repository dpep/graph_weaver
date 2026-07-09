###  v0.0.2  (unreleased)
- GraphWeaver.register_scalar: custom scalar deserialization into rich Ruby
  objects (Symbol/Proc cast + serialize); built-in scalars pre-registered in
  one overridable registry
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
