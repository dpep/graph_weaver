require "tmpdir"

# Introspecting a real API is slow (GitHub's schema is ~10MB of JSON), so
# integration specs cache twice: the built schema object per run (this
# hash), and the raw introspection JSON across runs (a tmpdir file via
# SchemaLoader's cache:, refreshed daily). Delete the files to force a
# refresh.
INTEGRATION_SCHEMAS = {}

def integration_schema(key, executor)
  INTEGRATION_SCHEMAS[key] ||= GraphWeaver::SchemaLoader.introspect(
    executor,
    cache: File.join(Dir.tmpdir, "graph_weaver", "#{key}-schema.json"),
    ttl: 24 * 60 * 60,
  )
end
