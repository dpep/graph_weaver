# typed: true
# frozen_string_literal: true

require "fileutils"
require "graphql"
require "json"
require_relative "errors"

# Load a schema for codegen from either format a remote service can hand
# you — introspection JSON or SDL, as a file path or the content itself —
# or fetch one straight from a live endpoint via introspect.
module GraphWeaver::SchemaLoader
  # Accepts, and detects:
  #   - a Hash (a parsed introspection result)
  #   - a file path — .json (introspection) or .graphql/.gql (SDL)
  #   - raw content — introspection JSON (starts with "{") or SDL
  # so a cache round-trip is symmetrical with introspect:
  #      SchemaLoader.load(cached_json)  # from Rails.cache/redis/...
  def self.load(source)
    return GraphQL::Schema.from_introspection(source) if source.is_a?(Hash)

    if source.lstrip.start_with?("{") # introspection JSON content
      GraphQL::Schema.from_introspection(JSON.parse(source))
    elsif source.include?("\n") # multi-line: SDL content
      unless source.match?(/^\s*(schema|type|interface|union|enum|scalar|directive|input|")/)
        raise ArgumentError, "unsupported schema content: #{source.lstrip[0, 80].inspect}"
      end

      GraphQL::Schema.from_definition(source)
    else # a file path
      case File.extname(source)
      when ".json"
        GraphQL::Schema.from_introspection(JSON.parse(File.read(source)))
      when ".graphql", ".gql"
        GraphQL::Schema.from_definition(File.read(source))
      else
        raise ArgumentError, "unsupported schema format: #{source}"
      end
    end
  end

  # Run the standard introspection query through a transport and build a
  # schema from the result:
  #
  #      transport = GraphWeaver::Transport::HTTP.new(url, headers: { ... })
  #      schema = GraphWeaver::SchemaLoader.introspect(transport)
  #
  # Introspecting a large API takes seconds, so cache: dumps the schema
  # to a file and reuses it until ttl: seconds elapse (no ttl = until the
  # file is deleted). cache: takes
  #   - true — GraphWeaver.schema_path, the file the generation workflow
  #     reads (its extension picks the format)
  #   - a path — the extension picks the format: .json is the verbatim
  #     introspection result, .graphql/.gql is SDL (human-readable,
  #     PR-reviewable diffs); both load back identically
  #   - :json / :graphql / :gql — GraphWeaver.schema_path's location, in
  #     that format
  # Reading is format-agnostic: any fresh sibling dump counts, whatever
  # its format — an existing schema.graphql is reused rather than
  # re-introspecting to write schema.json.
  # GraphQL has no standard schema-version signal to invalidate on — a
  # stale cache surfaces as server-side validation errors (see
  # QueryError#schema_stale?), so pick a ttl that matches how fast the
  # API moves, or delete the file.
  #
  # To cache anywhere else (Rails.cache, redis, ...), serialize the schema
  # itself — schemas round-trip through their introspection JSON:
  #
  #      json = Rails.cache.fetch("gh_schema", expires_in: 12.hours) do
  #        GraphWeaver::SchemaLoader.introspect(transport).to_json
  #      end
  #      schema = GraphWeaver::SchemaLoader.load(json)
  def self.introspect(transport, cache: nil, ttl: nil)
    cache = cache_path(cache)

    if cache
      # reuse whatever fresh dump is present, regardless of format —
      # don't re-introspect to write schema.json when a usable
      # schema.graphql already sits there
      existing = cache_candidates(cache).find { |candidate| fresh?(candidate, ttl) }
      if existing
        GraphWeaver.log(:info) { "schema cache hit: #{existing}#{" (ttl #{ttl}s)" if ttl}" }
        return load(existing)
      end

      GraphWeaver.log(:info) { "schema cache miss: #{cache}" }
    end

    result = GraphWeaver.log_timed(:info, "introspected #{transport.respond_to?(:url) ? transport.url : transport.class}") do
      transport.execute(GraphQL::Introspection.query, variables: {}).to_h
    end
    if (errors = result["errors"])
      raise GraphWeaver::Error, "introspection failed: #{errors.inspect}"
    end

    schema = GraphQL::Schema.from_introspection(result)

    if cache
      FileUtils.mkdir_p(File.dirname(cache))
      # the extension picks the format: .json is the verbatim wire
      # artifact; .graphql/.gql is SDL — human-readable, PR-reviewable
      # diffs (both generate byte-identical code)
      meta = stamp(transport)
      content = if cache.end_with?(".json")
        JSON.generate(meta ? result.merge("graph_weaver" => meta) : result)
      else
        header = meta && "# graph_weaver: #{JSON.generate(meta)}\n\n"
        "#{header}#{schema.to_definition}"
      end
      File.write(cache, content)
      GraphWeaver.log(:info) { "wrote schema cache: #{cache} (#{content.bytesize} bytes)" }
    end

    schema
  end

  # The conventional schema dump, whatever its format: schema_path or the
  # first sibling extension that exists. nil when none is on disk.
  def self.locate_path(path = GraphWeaver.schema_path)
    cache_candidates(path).find { |candidate| File.exist?(candidate) }
  end

  # locate_path, loaded.
  def self.locate(path = GraphWeaver.schema_path)
    found = locate_path(path)
    found && load(found)
  end

  # The provenance recorded in a dump ({"url" => ..., "introspected_at"
  # => ...}), whichever format holds it; nil for local/unannotated dumps.
  def self.provenance(path)
    content = File.read(path)
    if path.end_with?(".json")
      JSON.parse(content)["graph_weaver"]
    elsif (meta = content[/\A# graph_weaver: (\{.*\})$/, 1])
      JSON.parse(meta)
    end
  end

  # Re-introspect a dump's source and compare — true when the server has
  # drifted from what's on disk. transport: overrides the transport (auth
  # etc); by default one is built from the dump's recorded url. Wired up
  # as `rake graph_weaver:schema:verify` / `:refresh`.
  def self.stale?(path, transport: nil)
    transport ||= source_transport(path)
    fresh = introspect(transport)

    fresh.to_definition != load(path).to_definition
  end

  # a transport to the dump's recorded url (GRAPHWEAVER_AUTH supplies a
  # token when set)
  def self.source_transport(path)
    meta = provenance(path)
    unless meta&.key?("url")
      raise GraphWeaver::Error, "#{path} records no source url — pass transport:"
    end

    GraphWeaver.new(meta["url"], auth: ENV["GRAPHWEAVER_AUTH"]).transport
  end
  private_class_method :source_transport

  # Where a dump came from, recorded into the file so it can be
  # re-verified later — a parsable header comment in SDL, a
  # "graph_weaver" sibling key in introspection JSON (from_introspection
  # reads only "data"). nil when the transport has no url (schema
  # classes, fakes).
  def self.stamp(transport)
    return unless transport.respond_to?(:url) && transport.url

    require "time"
    { "url" => transport.url, "introspected_at" => Time.now.utc.iso8601 }
  end
  private_class_method :stamp

  CACHE_EXTENSIONS = %w[.json .graphql .gql].freeze

  # cache: true / :json / :graphql / :gql / a path => the file to write
  # (nil for no caching). Symbols and true anchor at GraphWeaver.schema_path —
  # the schema dump the generation workflow reads, so one file serves both
  # (introspect caches it, rake generate loads it).
  def self.cache_path(cache)
    case cache
    when nil, false
      nil
    when true
      GraphWeaver.schema_path
    when Symbol
      unless CACHE_EXTENSIONS.include?(".#{cache}")
        raise ArgumentError, "cache: format must be :json, :graphql, or :gql, got #{cache.inspect}"
      end

      "#{strip_extension(GraphWeaver.schema_path)}.#{cache}"
    else
      unless cache.end_with?(*CACHE_EXTENSIONS)
        raise ArgumentError, "cache: must be a .json or .graphql/.gql path, got #{cache}"
      end

      cache
    end
  end
  private_class_method :cache_path

  # the requested path first, then its siblings in the other formats
  def self.cache_candidates(path)
    base = strip_extension(path)
    [path, *CACHE_EXTENSIONS.map { |ext| base + ext }].uniq
  end
  private_class_method :cache_candidates

  def self.strip_extension(path)
    path.delete_suffix(File.extname(path))
  end
  private_class_method :strip_extension

  def self.fresh?(path, ttl)
    File.exist?(path) && (ttl.nil? || Time.now - File.mtime(path) < ttl)
  end
  private_class_method :fresh?
end
