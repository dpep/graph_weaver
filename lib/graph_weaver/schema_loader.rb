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
    return build_introspection(source) if source.is_a?(Hash)

    # Rails.root.join(...) hands you a Pathname, and to_path is the
    # ecosystem's "I am a path" (File.open honors it). Without this the
    # sniffing below fails as `undefined method 'lstrip'`.
    source = source.to_path if source.respond_to?(:to_path)

    if source.lstrip.start_with?("{") # introspection JSON content
      build_introspection(parse_json(source, "the schema content"))
    elsif sdl_content?(source) # SDL content, one line or many
      build_sdl(source)
    elsif source.include?("\n") # content, but nothing we recognize
      raise GraphWeaver::Error, "unsupported schema content: #{source.lstrip[0, 80].inspect}"
    else
      load_path(source)
    end
  end

  # SDL content rather than a file path. Anchored at the start and requiring
  # a delimiter after the keyword, so `types/schema.graphql` isn't read as a
  # `type` definition — and a one-line `type Query { hi: String }`, the shape
  # you'd type in a console, still is.
  SDL_CONTENT = /\A\s*(?:\#|"|(?:schema|type|interface|union|enum|scalar|directive|input|extend)\b[\s{(@])/

  def self.sdl_content?(source)
    source.match?(SDL_CONTENT)
  end

  def self.load_path(path)
    case File.extname(path)
    when ".json"
      build_introspection(parse_json(read_schema(path), path))
    when ".graphql", ".gql"
      build_sdl(read_schema(path))
    else
      raise GraphWeaver::Error,
        "unsupported schema format: #{path} — expected a .json (introspection) or " \
        ".graphql/.gql (SDL) path, or the content itself#{url_hint(path)}"
    end
  end
  private_class_method :load_path

  def self.read_schema(path)
    File.read(path)
  rescue SystemCallError => e
    raise GraphWeaver::Error, "can't read the schema at #{path}: #{e.message}"
  end
  private_class_method :read_schema

  # A .json that isn't JSON is the corrupt-dump case — a truncated download,
  # an interrupted write, a login page saved over it. JSON::ParserError names
  # neither the file nor what it holds, and isn't under the Error umbrella.
  def self.parse_json(text, source)
    JSON.parse(text)
  rescue JSON::ParserError => e
    holds = text.strip.empty? ? "it is empty" : "it starts #{text.lstrip[0, 60].inspect}"
    raise GraphWeaver::Error,
      "#{source} isn't JSON (#{e.message}) — an introspection dump is the whole envelope, " \
      "{\"data\": {\"__schema\": …}}, and #{holds}"
  end
  private_class_method :parse_json

  # A bare host is the near miss worth naming: "unsupported schema format"
  # sends you looking at the filesystem when the cause is the missing scheme.
  HOST_LIKE = %r{\A[a-z0-9-]+(?:\.[a-z0-9-]+)+(?::\d+)?(?:/\S*)?\z}i
  # dotted-but-not-a-host: a file whose extension we simply don't read
  FILE_SUFFIXES = %w[yaml yml txt xml sdl md rb erb].freeze

  def self.url_hint(source)
    return unless source.match?(HOST_LIKE)

    suffix = source[%r{\A[^/:]+}].to_s[/[^.]+\z/].to_s
    return if FILE_SUFFIXES.include?(suffix.downcase)

    %( — "#{source}" looks like a host; did you mean "https://#{source}"?)
  end
  private_class_method :url_hint

  # Build a schema from SDL, first normalizing whichever federation artifact
  # it is: a composed supergraph gets its composition machinery stripped (so
  # a supergraph dump — often the only artifact for the merged graph, and
  # what the router actually serves — loads like any schema, with the
  # plumbing gone rather than leaked into schema.types); a subgraph gets the
  # federation directive definitions it applies but doesn't declare. Plain
  # SDL passes through.
  def self.build_sdl(sdl)
    kind = sdl_kind(sdl)
    prepared = case kind
    when :supergraph then strip_federation(sdl)
    when :subgraph then add_subgraph_definitions(sdl)
    else sdl
    end

    build(kind) { GraphQL::Schema.from_definition(prepared) }
  end
  private_class_method :build_sdl

  def self.build_introspection(result)
    build(:introspection) { GraphQL::Schema.from_introspection(result) }
  end
  private_class_method :build_introspection

  # Which artifact an SDL string is — it decides both the normalizing it
  # needs and what to say when it won't build.
  def self.sdl_kind(sdl)
    if federation_sdl?(sdl)
      :supergraph
    elsif subgraph_sdl?(sdl)
      :subgraph
    else
      :sdl
    end
  end
  private_class_method :sdl_kind

  SOURCE_KINDS = {
    supergraph: "a federation supergraph SDL — if it's hand-written, check that nothing " \
      "left in it still references an @inaccessible element",
    subgraph: "a federation subgraph SDL — a directive it applies may be outside the " \
      "subgraph spec; declare that one in the file",
    sdl: "plain SDL — a supergraph is recognized by its @join__* markers or the @link/@core " \
      "specs it declares, a subgraph by applied-but-undeclared @key/@shareable/…",
    introspection: 'an introspection result — it should be the whole envelope, {"data": {"__schema": …}}',
  }.freeze

  # graphql-ruby reports a schema it can't build with whatever its internals
  # happen to raise — NoMethodError, ParseError, a bare RuntimeError — often
  # naming a document the caller never wrote (we reprint federation SDL before
  # building). Keep those under the umbrella, and say which artifact we took
  # the source for.
  def self.build(kind)
    yield
  rescue GraphWeaver::Error
    raise
  rescue StandardError => e
    raise GraphWeaver::Error,
      "couldn't build a schema from #{SOURCE_KINDS.fetch(kind)} (#{e.class}: #{e.message})"
  end
  private_class_method :build

  # A composed graph declares the specs that compose it: fed-2 links join,
  # fed-1 @cores the core spec itself. Neither matches a subgraph, which links
  # only the federation spec — so this catches the composed graphs the
  # @join__ marker misses: one that renamed join (`as: "j"`), and a core
  # schema that merged nothing but still carries core__Purpose.
  COMPOSITION_SPEC = %r{@(?:link\s*\(\s*url|core\s*\(\s*feature):\s*"https://specs\.apollo\.dev/(?:join|core)/}

  # A composed Fed2 supergraph is marked by @join__* directives (every merged
  # type carries them); a plain schema has none.
  def self.federation_sdl?(sdl)
    sdl.match?(/@join__\w/) || sdl.match?(COMPOSITION_SPEC)
  end

  # The federation spec a fed-2 subgraph @links, and the directives a fed-1
  # subgraph just applies. Both leave the definitions off the file: fed-1
  # treats them as implicit, fed-2 imports them. A composed supergraph
  # defines everything it applies (and federation_sdl? catches it first).
  SUBGRAPH_LINK = %r{@link\s*\(\s*url:\s*"https://specs\.apollo\.dev/federation/}
  SUBGRAPH_MARKERS = %w[key external extends provides requires shareable override interfaceObject].freeze

  # A raw subgraph SDL — `rover subgraph fetch`, `_service { sdl }`, or the
  # .graphql in a service repo — rather than a composed graph.
  def self.subgraph_sdl?(sdl)
    return false if federation_sdl?(sdl)
    return true if sdl.match?(SUBGRAPH_LINK)

    SUBGRAPH_MARKERS.any? { |name| sdl.match?(/@#{name}\b/) && !sdl.match?(/\bdirective\s+@#{name}\b/) }
  end

  # The subgraph spec's directives and the types they reference, keyed by
  # what a definition in the SDL would be named ("@key" for a directive).
  # The helper scalars are spelled `federation__*` — they are weaver's own
  # injections into someone else's schema, and a subgraph with its own
  # `FieldSet` type must not collide with one.
  # https://www.apollographql.com/docs/graphos/schema-design/federated-schemas/reference/subgraph-spec
  SUBGRAPH_DIRECTIVE_DEFS = {
    "@key" => "directive @key(fields: federation__FieldSet!, resolvable: Boolean = true) repeatable on OBJECT | INTERFACE",
    "@external" => "directive @external on OBJECT | FIELD_DEFINITION",
    "@requires" => "directive @requires(fields: federation__FieldSet!) on FIELD_DEFINITION",
    "@provides" => "directive @provides(fields: federation__FieldSet!) on FIELD_DEFINITION",
    "@shareable" => "directive @shareable repeatable on OBJECT | FIELD_DEFINITION",
    "@extends" => "directive @extends on OBJECT | INTERFACE",
    "@override" => "directive @override(from: String!, label: String) on FIELD_DEFINITION",
    "@interfaceObject" => "directive @interfaceObject on OBJECT",
    "@inaccessible" => "directive @inaccessible on FIELD_DEFINITION | OBJECT | INTERFACE | UNION | ARGUMENT_DEFINITION | SCALAR | ENUM | ENUM_VALUE | INPUT_OBJECT | INPUT_FIELD_DEFINITION",
    "@tag" => "directive @tag(name: String!) repeatable on FIELD_DEFINITION | OBJECT | INTERFACE | UNION | ARGUMENT_DEFINITION | SCALAR | ENUM | ENUM_VALUE | INPUT_OBJECT | INPUT_FIELD_DEFINITION | SCHEMA",
    "@composeDirective" => "directive @composeDirective(name: String!) repeatable on SCHEMA",
    "@authenticated" => "directive @authenticated on FIELD_DEFINITION | OBJECT | INTERFACE | SCALAR | ENUM",
    "@requiresScopes" => "directive @requiresScopes(scopes: [[federation__Scope!]!]!) on FIELD_DEFINITION | OBJECT | INTERFACE | SCALAR | ENUM",
    "@policy" => "directive @policy(policies: [[federation__Policy!]!]!) on FIELD_DEFINITION | OBJECT | INTERFACE | SCALAR | ENUM",
    "@link" => "directive @link(url: String!, as: String, for: link__Purpose, import: [link__Import]) repeatable on SCHEMA",
  }.freeze

  # The types those definitions reference — injected only alongside a
  # directive that needs one. `_Any`/`_Entity`/`_Service` (see
  # entity_plumbing) keep their spec-mandated names; these are ours to
  # namespace, so they can't shadow a subgraph's own type.
  SUBGRAPH_HELPER_TYPES = {
    "federation__FieldSet" => "scalar federation__FieldSet",
    "federation__Scope" => "scalar federation__Scope",
    "federation__Policy" => "scalar federation__Policy",
    "link__Import" => "scalar link__Import",
    "link__Purpose" => "enum link__Purpose { SECURITY EXECUTION }",
  }.freeze

  # A fed-2 subgraph that @links the spec under a namespace — `as: "fed"`,
  # and "federation" is the default — applies every non-imported directive
  # under it: @federation__key rather than @key.
  def self.subgraph_namespace(sdl)
    sdl[/#{SUBGRAPH_LINK}[^)]*\bas:\s*"([^"]+)"/, 1] || "federation"
  end
  private_class_method :subgraph_namespace

  # Prepend the definitions this subgraph applies but doesn't declare, under
  # whichever name it applies them by. Only the missing ones — a duplicate
  # definition is a hard error in graphql-ruby, and a subgraph spelling out
  # its own @key (fed-1 style, or a differing shape) must win.
  def self.add_subgraph_definitions(sdl)
    defined = GraphQL.parse(sdl).definitions.filter_map do |defn|
      next unless defn.respond_to?(:name)

      defn.is_a?(GraphQL::Language::Nodes::DirectiveDefinition) ? "@#{defn.name}" : defn.name
    end.to_set
    namespace = subgraph_namespace(sdl)

    directives = SUBGRAPH_DIRECTIVE_DEFS.filter_map do |name, defn|
      applied = [name, "@#{namespace}__#{name.delete_prefix("@")}"]
        .find { |as| !defined.include?(as) && sdl.match?(/#{as}\b/) }
      applied && defn.sub(name, applied)
    end
    types = SUBGRAPH_HELPER_TYPES
      .select { |name, _| !defined.include?(name) && directives.any? { |defn| defn.include?(name) } }
      .values

    added = types + directives + entity_plumbing(sdl, namespace, defined)
    added.empty? ? sdl : "#{added.join("\n")}\n\n#{sdl}"
  end
  private_class_method :add_subgraph_definitions

  # The entity resolver every subgraph serves — and which no subgraph SDL
  # contains: `_service { sdl }` and `rover subgraph fetch` both print the
  # published schema, where the plumbing is implicit. Supply it so an
  # `_entities` query can be typed against the artifact you actually have
  # (a supergraph doesn't describe `_entities` at all). `_Entity` is the
  # union of the file's own @key'd types, so it stays accurate per subgraph.
  # https://www.apollographql.com/docs/graphos/schema-design/federated-schemas/reference/subgraph-spec
  def self.entity_plumbing(sdl, namespace, defined)
    doc = GraphQL.parse(sdl)
    root = query_root_name(doc)
    entities = entity_names(doc, namespace)
    return [] if entities.empty? || root.nil? || defined.include?("_Any")

    [
      "scalar _Any",
      "type _Service { sdl: String }",
      "union _Entity = #{entities.join(" | ")}",
      "extend type #{root} {\n" \
        "  _entities(representations: [_Any!]!): [_Entity]!\n" \
        "  _service: _Service!\n" \
        "}",
    ]
  end
  private_class_method :entity_plumbing

  # The object types this subgraph resolves as entities: the ones it applies
  # @key to, under whichever name it applies it by (@federation__key when the
  # spec is linked under a namespace). Type extensions count — fed-1 spells an
  # entity it doesn't own as `extend type User @key(...)`.
  def self.entity_names(doc, namespace)
    key_names = ["key", "#{namespace}__key"]

    doc.definitions.filter_map do |defn|
      next unless defn.is_a?(GraphQL::Language::Nodes::ObjectTypeDefinition) ||
        defn.is_a?(GraphQL::Language::Nodes::ObjectTypeExtension)

      defn.name if defn.directives.any? { |d| key_names.include?(d.name) }
    end.uniq
  end
  private_class_method :entity_names

  # The query root's name — `schema { query: Root }` when the file says so,
  # `Query` by convention. nil when the file has no query root to extend.
  def self.query_root_name(doc)
    declared = doc.definitions.grep(GraphQL::Language::Nodes::SchemaDefinition).first ||
      doc.definitions.grep(GraphQL::Language::Nodes::SchemaExtension).first
    name = declared&.query || "Query"
    root_present = doc.definitions.any? do |defn|
      defn.respond_to?(:name) && defn.name == name &&
        (defn.is_a?(GraphQL::Language::Nodes::ObjectTypeDefinition) ||
          defn.is_a?(GraphQL::Language::Nodes::ObjectTypeExtension))
    end
    name if root_present
  end
  private_class_method :query_root_name

  # how a schema declares the specs it's built from: @link in fed 2, @core in fed 1
  LINK_DIRECTIVES = %w[link core].to_set.freeze

  # The floor a supergraph gets whether it declares the specs or not — a
  # hand-written or trimmed one often has no @link header at all. Derivation
  # only ever adds to this.
  DEFAULT_PREFIXES = %w[join__ link__ core__].freeze
  DEFAULT_DIRECTIVES = %w[link core inaccessible].freeze

  # What THIS document calls federation's machinery — type-name prefixes,
  # directive names, and the local names @inaccessible answers to — read off
  # its own @link/@core declarations rather than assumed: a linked spec's name
  # gives both a `join__` type prefix and a root `@join` directive, `as:`
  # renames it, and each `import:` entry binds one more directive in the root
  # namespace, possibly under a different local name. A missed @inaccessible
  # rename over-permits the derived API schema, not merely leaks a type.
  # https://specs.apollo.dev/link/v1.0/ · https://specs.apollo.dev/core/v0.2/
  def self.link_namespaces(doc)
    prefixes = DEFAULT_PREFIXES.dup
    directives = DEFAULT_DIRECTIVES.to_set
    inaccessible = Set["inaccessible"]

    link_declarations(doc).each do |args|
      spec = spec_name(args["url"] || args["feature"])
      local = args["as"].is_a?(String) ? args["as"] : spec
      if local
        prefixes << "#{local}__"
        directives << local
        # a spec's root directive is its own name: @link(url: ".../inaccessible/v0.2", as: "private")
        inaccessible << local if spec == "inaccessible"
      end

      imports(args["import"]).each do |name, as|
        next unless as.start_with?("@")

        directives << as.delete_prefix("@")
        inaccessible << as.delete_prefix("@") if name == "@inaccessible"
      end
    end

    { prefixes: prefixes.uniq.freeze, directives: directives.freeze, inaccessible: inaccessible.freeze }
  end
  private_class_method :link_namespaces

  # The @link/@core applications on the document's schema definition, each as
  # a plain argument hash.
  def self.link_declarations(doc)
    doc.definitions.flat_map do |defn|
      next [] unless defn.is_a?(GraphQL::Language::Nodes::SchemaDefinition) ||
        defn.is_a?(GraphQL::Language::Nodes::SchemaExtension)

      defn.directives
        .select { |d| LINK_DIRECTIVES.include?(d.name) }
        .map { |d| d.arguments.to_h { |arg| [arg.name, arg.value] } }
    end
  end
  private_class_method :link_declarations

  # `import: ["@key", {name: "@inaccessible", as: "@private"}]` as
  # [spec name, local name] pairs.
  def self.imports(value)
    Array(value).filter_map do |entry|
      case entry
      when String then [entry, entry]
      when GraphQL::Language::Nodes::InputObject
        fields = entry.to_h
        name = fields["name"]
        [name, fields["as"].is_a?(String) ? fields["as"] : name] if name.is_a?(String)
      end
    end
  end
  private_class_method :imports

  VERSION_TAG = /\Av\d+\.\d+\z/
  GRAPHQL_NAME = /\A[A-Za-z][A-Za-z0-9_]*\z/

  # The name a linked spec's elements are namespaced under: the URL's
  # penultimate path segment when the last is a version tag, else the last one.
  # Query strings, fragments and empty segments don't count. A segment that
  # can't be a namespace (a bare host, or a name carrying the `__` separator)
  # means the URL is just an opaque identifier and nothing is derived.
  # https://specs.apollo.dev/link/v1.0/
  def self.spec_name(url)
    return unless url.is_a?(String)

    segments = url.split(/[?#]/).first.to_s.split("/").reject(&:empty?)
    segments.pop if segments.last&.match?(VERSION_TAG)
    name = segments.last
    name if name&.match?(GRAPHQL_NAME) && !name.include?("__") && !name.end_with?("_")
  end
  private_class_method :spec_name

  # Synthetic composition TYPES are always prefixed (join__Graph, link__Import).
  # The bare names (link/core/inaccessible) are DIRECTIVES only — a user type
  # literally named `link` (Hasura-style lowercase) must not be dropped.
  def self.federation_type_name?(name, ns)
    !!name && name.start_with?(*ns[:prefixes])
  end
  private_class_method :federation_type_name?

  def self.federation_directive_name?(name, ns)
    !!name && (name.start_with?(*ns[:prefixes]) || ns[:directives].include?(name))
  end
  private_class_method :federation_directive_name?

  # Drop the composition machinery from supergraph SDL: the synthetic
  # join__*/link__* type and directive definitions, and every @join__*/@link
  # application on the types that remain. What's left is the merged graph's
  # ordinary type shapes — exactly what codegen reads. Parsing is lenient (it's
  # schema *building* that rejects the join directives), so we parse, filter the
  # AST, and reprint clean SDL for from_definition — no graphql-ruby monkeypatch
  # and no join__* leaking into schema.types.
  def self.strip_federation(sdl)
    doc = GraphQL.parse(sdl)
    ns = link_namespaces(doc)
    defs = remove_inaccessible(doc.definitions, ns)
      .reject { |defn| federation_definition?(defn, ns) }
      .map { |defn| strip_federation_directives(defn, ns) }

    if defs.none? { |d| d.is_a?(GraphQL::Language::Nodes::ObjectTypeDefinition) }
      raise GraphWeaver::Error,
        "supergraph has no object types left after stripping the federation machinery — " \
        "is the whole schema behind @inaccessible?"
    end

    GraphQL::Language::Nodes::Document.new(definitions: defs).to_query_string
  end

  # a synthetic composition definition to drop: a federation directive
  # definition (by name), or a synthetic join__*/link__* type (by prefix)
  def self.federation_definition?(defn, ns)
    return false unless defn.respond_to?(:name)

    if defn.is_a?(GraphQL::Language::Nodes::DirectiveDefinition)
      federation_directive_name?(defn.name, ns)
    else
      federation_type_name?(defn.name, ns)
    end
  end
  private_class_method :federation_definition?

  # Derive the API schema by dropping every element marked @inaccessible —
  # present in the federated graph but hidden from the public API the router
  # serves (its common use is safely rolling out a field on a shared type).
  # Cascades: a field/argument/union-member/implements referencing a removed
  # type goes too, and a type left with no fields/values/members is itself
  # removed — repeated to a fixpoint. So codegen matches exactly what clients
  # can query, without the over-permitting a raw supergraph would allow and
  # without Apollo's JS tooling to subtract the API schema.
  def self.remove_inaccessible(definitions, ns)
    removed = definitions.select { |d| type_definition?(d) && inaccessible?(d, ns) }.map(&:name).to_set
    loop do
      survivors = definitions
        .reject { |d| type_definition?(d) && removed.include?(d.name) }
        .map { |d| prune_inaccessible(d, removed, ns) }
      # survivors already exclude `removed`, so anything newly emptied is fresh
      newly = survivors.select { |d| type_definition?(d) && type_emptied?(d) }.map(&:name)
      return survivors if newly.empty?

      removed.merge(newly)
    end
  end
  private_class_method :remove_inaccessible

  # A type-system type definition (object/interface/union/enum/input/scalar) —
  # not a directive or schema definition.
  def self.type_definition?(node)
    node.respond_to?(:name) &&
      !node.is_a?(GraphQL::Language::Nodes::DirectiveDefinition) &&
      node.class.name.end_with?("TypeDefinition")
  end
  private_class_method :type_definition?

  # @inaccessible under whatever local name the schema's @link bound it to.
  def self.inaccessible?(node, ns)
    node.respond_to?(:directives) && node.directives.any? { |d| ns[:inaccessible].include?(d.name) }
  end
  private_class_method :inaccessible?

  # Whether pruning left the type with nothing the SDL grammar allows to be
  # empty — a fieldless object/interface/input, a valueless enum, a memberless
  # union — so it must be removed and its references cascaded.
  def self.type_emptied?(node)
    (node.respond_to?(:fields) && node.fields && node.fields.empty?) ||
      (node.is_a?(GraphQL::Language::Nodes::EnumTypeDefinition) && node.values.empty?) ||
      (node.is_a?(GraphQL::Language::Nodes::UnionTypeDefinition) && node.types.empty?)
  end
  private_class_method :type_emptied?

  # the unwrapped (through NON_NULL/LIST) type name a field or argument references
  def self.unwrapped_type_name(node)
    type = node.type
    type = type.of_type while type.respond_to?(:of_type)
    type.name
  end
  private_class_method :unwrapped_type_name

  # Remove @inaccessible children and children referencing a removed type,
  # from a type's fields (and their arguments), enum values, union members,
  # and implemented interfaces.
  def self.prune_inaccessible(node, removed, ns)
    gone = lambda do |child|
      inaccessible?(child, ns) || (child.respond_to?(:type) && removed.include?(unwrapped_type_name(child)))
    end

    changes = {}
    if node.respond_to?(:fields) && node.fields
      changes[:fields] = node.fields.reject(&gone).map do |field|
        args = field.respond_to?(:arguments) && field.arguments
        args && args.any? ? field.merge(arguments: args.reject(&gone)) : field
      end
    end
    # a directive definition's own arguments — the only top-level node with
    # them, and Apollo's REFERENCED_INACCESSIBLE rule should already have
    # rejected such a supergraph; belt and braces for hand-written ones
    changes[:arguments] = node.arguments.reject(&gone) if node.respond_to?(:arguments) && node.arguments
    changes[:values] = node.values.reject(&gone) if node.respond_to?(:values) && node.values
    changes[:types] = node.types.reject { |t| removed.include?(t.name) } if node.respond_to?(:types) && node.types
    if node.respond_to?(:interfaces) && node.interfaces
      changes[:interfaces] = node.interfaces.reject { |i| removed.include?(i.name) }
    end
    changes.empty? ? node : node.merge(changes)
  end
  private_class_method :prune_inaccessible

  # Recursively remove @join__*/@link applications from a definition and its
  # fields, arguments, and enum values.
  def self.strip_federation_directives(node, ns)
    changes = {}
    if node.respond_to?(:directives) && node.directives
      # A schema definition keeps NONE: graphql-ruby's printer omits the
      # `{ query: Query }` body when the root type names are conventional but
      # still prints directives, so any survivor (@tag, @composeDirective, a
      # composed custom one) reprints as an unparseable braceless `schema @tag`.
      # Codegen never reads schema directives.
      changes[:directives] = if node.is_a?(GraphQL::Language::Nodes::SchemaDefinition)
        []
      else
        node.directives.reject { |d| federation_directive_name?(d.name, ns) }
      end
    end
    changes[:fields] = node.fields.map { |c| strip_federation_directives(c, ns) } if node.respond_to?(:fields) && node.fields
    changes[:arguments] = node.arguments.map { |c| strip_federation_directives(c, ns) } if node.respond_to?(:arguments) && node.arguments
    changes[:values] = node.values.map { |c| strip_federation_directives(c, ns) } if node.respond_to?(:values) && node.values
    changes.empty? ? node : node.merge(changes)
  end
  private_class_method :strip_federation_directives

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
  #     PR-reviewable diffs). Both load back to the same schema, but not
  #     at the same cost: SDL has to be parsed, so on a big schema
  #     (GitHub's 2.9 MB) it's roughly twice as slow to load — SDL for
  #     reviewability, JSON when boot time matters.
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
  def self.introspect(transport, cache: nil, ttl: nil, auth_env: nil)
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

    result = GraphWeaver.log_timed(:info, "introspected #{endpoint(transport)}") do
      transport.execute(GraphQL::Introspection.query, variables: {}).to_h
    end
    if (errors = result["errors"])
      raise GraphWeaver::Error, "introspection failed: #{errors.inspect}"
    end
    # a 200 of well-formed JSON that isn't an introspection result — a REST
    # base url, a GraphiQL page, a proxy that ate the path. from_introspection
    # would raise a bare NoMethodError on the missing "__schema" key.
    data = result["data"]
    unless data.is_a?(Hash) && data["__schema"]
      raise GraphWeaver::Error,
        "introspection at #{endpoint(transport)} returned no __schema — is that a GraphQL " \
        "endpoint? got: #{result.inspect[0, 200]}"
    end

    schema = GraphQL::Schema.from_introspection(result)

    if cache
      FileUtils.mkdir_p(File.dirname(cache))
      # the extension picks the format: .json is the verbatim wire
      # artifact; .graphql/.gql is SDL — human-readable, PR-reviewable
      # diffs (both generate byte-identical code)
      meta = stamp(transport, auth_env)
      content = if cache.end_with?(".json")
        JSON.generate(meta ? result.merge("graph_weaver" => meta) : result)
      else
        header = meta && "# graph_weaver: #{JSON.generate(meta)}\n\n"
        "#{header}#{schema.to_definition}"
      end
      GraphWeaver.atomic_write(cache, content)
      GraphWeaver.log(:info) { "wrote schema cache: #{cache} (#{content.bytesize} bytes)" }
    end

    schema
  end

  # What to call the thing we introspected, for a log line or an error: its
  # url when it has one, else the class (a schema class, a fake).
  def self.endpoint(transport)
    (transport.respond_to?(:url) && transport.url) || transport.class
  end
  private_class_method :endpoint

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

  # The ENV var holding the token for a private API, when the dump doesn't
  # name its own.
  DEFAULT_AUTH_ENV = "GRAPHWEAVER_AUTH"

  # The provenance recorded in a dump ({"url" => ..., "introspected_at"
  # => ..., "auth_env" => ...}), whichever format holds it; nil for
  # local/unannotated dumps.
  # A corrupt dump records nothing readable, which is what nil says — and
  # `schema:refresh` is the fix for one, so it must not be the thing that
  # trips over it.
  def self.provenance(path)
    content = File.read(path)
    if path.end_with?(".json")
      JSON.parse(content)["graph_weaver"]
    elsif (meta = content[/\A# graph_weaver: (\{.*\})$/, 1])
      JSON.parse(meta)
    end
  rescue JSON::ParserError
    nil
  end

  # The ENV var a dump's token lives in — whichever the generator recorded,
  # else GRAPHWEAVER_AUTH. Keeps `--auth MY_TOKEN` from producing an app
  # that authenticates and rake tasks that 401.
  def self.auth_env(path = nil)
    # the first refresh names a dump that doesn't exist yet
    recorded = provenance(path)&.dig("auth_env") if path && File.exist?(path)
    recorded || DEFAULT_AUTH_ENV
  end

  # Re-introspect a dump's source and compare — true when the server has
  # drifted from what's on disk. transport: overrides the transport (auth
  # etc); by default one is built from the dump's recorded url. Wired up
  # as `rake graph_weaver:schema:diff` / `:refresh`.
  def self.stale?(path, transport: nil)
    transport ||= source_transport(path)
    fresh = introspect(transport)

    fresh.to_definition != load(path).to_definition
  end

  # Re-introspect and rewrite the local dump, returning [path, url].
  # url: defaults to the one the dump recorded, so a refresh needs no
  # arguments once a dump exists — and passing one bootstraps the first
  # dump, which is what `rails g graph_weaver:install` does.
  # auth_env: the ENV var holding the token — defaults to whichever the
  # dump recorded, so `--auth MY_TOKEN` keeps working on every later
  # refresh without being repeated. auth: passes a token directly.
  def self.refresh!(url: nil, auth_env: nil, auth: nil)
    path = locate_path
    url ||= path && provenance(path)&.dig("url")
    raise GraphWeaver::Error, refresh_hint(path) unless url

    path ||= GraphWeaver.schema_path
    auth_env ||= self.auth_env(path)
    auth ||= ENV[auth_env]
    # ttl: 0 — an existing dump never counts as fresh, a refresh always refetches
    introspect(GraphWeaver.new(url, auth:).transport, cache: path, ttl: 0, auth_env:)
    [path, url]
  end

  def self.refresh_hint(path)
    missing = path ? "#{path} records no source url" : "no schema dump at #{GraphWeaver.schema_path}"
    "#{missing} — pass one: rake graph_weaver:schema:refresh URL=https://api.example.com/graphql " \
      "(a dump taken from a schema class is rebuilt from code, not re-fetched — see " \
      "docs/getting_started.md#your-apps-own-schema-in-process)"
  end
  private_class_method :refresh_hint

  # A transport to the dump's recorded url, authenticated from whichever ENV
  # var the dump named (else DEFAULT_AUTH_ENV). The single way to reach a
  # dump's own server — building one at a call site is how `--auth MY_TOKEN`
  # ends up honoured in some places and not others.
  def self.source_transport(path)
    meta = provenance(path)
    unless meta&.key?("url")
      raise GraphWeaver::Error,
        "#{path} records no source url — it wasn't introspected from one. Pass transport:, " \
        "or rebuild it from the schema class that produced it."
    end

    GraphWeaver.new(meta["url"], auth: ENV[auth_env(path)]).transport
  end

  # Where a dump came from, recorded into the file so it can be
  # re-verified later — a parsable header comment in SDL, a
  # "graph_weaver" sibling key in introspection JSON (from_introspection
  # reads only "data"). nil when the transport has no url (schema
  # classes, fakes).
  def self.stamp(transport, auth_env = nil)
    return unless transport.respond_to?(:url) && transport.url

    require "time"
    meta = { "url" => transport.url, "introspected_at" => Time.now.utc.iso8601 }
    # only the non-default var is worth recording — auth_env falls back to
    # DEFAULT_AUTH_ENV, so an unannotated dump reads the same either way
    meta["auth_env"] = auth_env if auth_env && auth_env != DEFAULT_AUTH_ENV
    meta
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

  # The other half of a supergraph. `load` strips the @join__* machinery to
  # get the API schema; this keeps it — who resolves what:
  #
  #      table = GraphWeaver::SchemaLoader.routing_table("supergraph.graphql")
  #      table.owners("Product", "shippingEstimate")  # => ["reviews"]
  #      table.keys("Product", "products")            # => [["upc"]]
  #
  # Takes the same sources `load` does, minus an introspection result — a
  # router's introspection answers with the API schema, which by design says
  # nothing about subgraphs.
  def self.routing_table(source)
    sdl = supergraph_sdl(source)
    unless federation_sdl?(sdl)
      raise GraphWeaver::Error,
        "no routing table here — a composed supergraph SDL carries one in its @join__* markers, " \
        "and this schema has none (a subgraph or an API schema describes one service's slice, " \
        "not who resolves what)"
    end

    RoutingTable.new(sdl)
  end

  def self.supergraph_sdl(source)
    if source.is_a?(Hash)
      raise GraphWeaver::Error,
        "an introspection result carries no routing table — introspection answers with the API " \
        "schema. Load the composed supergraph SDL instead."
    end

    text = source.to_s
    sdl_content?(text) ? text : read_schema(text)
  end
  private_class_method :supergraph_sdl

  # Which subgraph resolves what, read off a composed supergraph's @join__*
  # directives. Subgraphs are named the way `@join__graph(name:)` names them —
  # the same strings a router config and `rover` use — not the SDL's uppercase
  # enum spelling.
  #
  # Everything here is a plain read of the artifact. It cannot plan a query;
  # it answers the questions a planner (or an error message) asks.
  class RoutingTable
    # One field's routing: `graphs` resolve it, `external` declare it without
    # resolving it (an @external copy exists so that subgraph can @key or
    # @requires on it), and requires/provides/override carry the field sets and
    # the migration marker verbatim.
    Field = Struct.new(:graphs, :external, :requires, :provides, :override)

    # Every @join__ directive this table understands. One it doesn't is a
    # federation construct nobody has taught it to read, and it lands in
    # `unsupported` rather than being skipped — a routing table that silently
    # ignores half a spec version routes confidently and wrongly.
    KNOWN = %w[
      join__type join__field join__graph join__implements
      join__unionMember join__enumValue join__owner
    ].to_set.freeze

    # every subgraph in the graph, in the order the supergraph declares them
    attr_reader :subgraphs

    # constructs found in this supergraph that the table can't describe
    # faithfully, each as a one-line explanation
    attr_reader :unsupported

    # { "Media" => ["catalog"] } — types a subgraph resolves as an
    # @interfaceObject, so it answers a whole interface's implementations and
    # this table can't attribute their fields subgraph by subgraph. Not in
    # `unsupported` because it is a fact about one type rather than about the
    # table: a query that never reaches the type is unaffected, and only a
    # caller planning one can tell.
    attr_reader :interface_objects

    def initialize(sdl)
      @document = GraphQL.parse(sdl)
      @names = {}        # "ACCOUNTS" => "accounts"
      @declared_in = {}  # "User" => ["accounts", "reviews"]
      @keys = {}         # "User" => { "accounts" => [["id"]] }
      @fields = {}       # "User" => { "reviews" => Field }
      @field_names = {}  # "User" => Set["id", "username"]
      @abstract = {}     # "FeedItem" => ["Announcement", "Review"]
      @possible = {}     # "FeedItem" => { "reviews" => ["Announcement", "Review"] }
      @unsupported = []
      @interface_objects = {}

      read_graphs
      read_abstracts
      read_types
      @subgraphs = @names.values.freeze
    end

    # Which subgraphs can resolve Type.field, by name. A field with no
    # @join__field at all lives wherever its type does — the composer omits
    # the directive when it has nothing to say, and that omission is the
    # supergraph spec's way of saying "everywhere".
    def owners(type_name, field_name)
      field = self.field(type_name, field_name)
      return declared_in(type_name) if field.nil?
      return field.graphs if field.graphs.any?

      # declared only as @external/@usedOverridden: a reference, not a resolver
      field.external.any? ? [] : declared_in(type_name)
    end

    # The routing for Type.field, or nil when the supergraph says nothing
    # about it (see owners).
    def field(type_name, field_name) = @fields.dig(type_name, field_name)

    # which subgraphs declare a type, by name
    def declared_in(type_name) = @declared_in[type_name] || []

    # every type the supergraph places, in the order it declares them —
    # owners/declared_in answer questions about one, this is the list
    def types = @declared_in.keys

    # The fields of a type the supergraph routes explicitly. A field with no
    # @join__field isn't here: it lives wherever its type does, so the
    # supergraph names no subgraph for it (see owners).
    def fields(type_name) = (@fields[type_name] || {}).keys

    # Every field the supergraph's type declares, routed or not — `fields`
    # answers which of them it routes explicitly, this answers what is
    # there.
    def declared_fields(type_name) = @field_names[type_name]&.to_a || []

    # Whether the supergraph carries this coordinate at all — a type, or a
    # field on it. `owners`/`fields` answer who resolves what the supergraph
    # has; this answers whether it has it, which is the question a local
    # schema's extra field poses.
    def declares?(type_name, field_name = nil)
      return @declared_in.key?(type_name) if field_name.nil?

      !!@field_names[type_name]&.include?(field_name)
    end

    # Who to name in an error about a coordinate: the subgraphs that resolve
    # Type.field, or — for a bare type, or a field the supergraph no longer
    # carries — the ones that declare the type. Empty when it places
    # neither, so a message can simply say nothing.
    def responsible(type_name, field_name = nil)
      return declared_in(type_name) unless field_name && declares?(type_name, field_name)

      owners(type_name, field_name)
    end

    # A `subgraphs:` map with string keys, refusing a name this supergraph
    # doesn't have — a typo'd key would otherwise silently configure nothing.
    # Lives here so the test router and the drift check refuse identically:
    # two copies of this drifted apart once already.
    def named_subgraphs(given)
      map = (given || {}).to_h { |name, schema| [name.to_s, schema] }
      unknown = map.keys - subgraphs
      return map if unknown.empty?

      raise GraphWeaver::ConfigurationError, "subgraphs: names #{unknown.join(", ")}, which " \
        "this supergraph doesn't have (its subgraphs are #{subgraphs.join(", ")})"
    end

    # The @key field sets a subgraph will answer an `_entities` fetch on, each
    # as a list of dotted paths ("id organization { id }" => ["id",
    # "organization.id"]). A `resolvable: false` key declares a shape this
    # subgraph does not answer for, so it isn't one.
    def keys(type_name, subgraph) = @keys.dig(type_name, subgraph) || []

    # whether any subgraph will resolve this type from a key
    def entity?(type_name) = (@keys[type_name] || {}).each_value.any?(&:any?)

    # The concrete types `subgraph` can answer an abstract type with — a
    # union's members there, an interface's implementations there. Only these
    # may be named in a fetch to it: a subgraph rejects an `... on T` its own
    # schema doesn't place in the abstract type.
    #
    # nil when the supergraph doesn't say, which a caller has to treat as
    # unknown rather than empty. @join__unionMember / @join__implements record
    # it; a supergraph composed before those existed carries neither, and then
    # only a type declared in ONE subgraph is answerable — everything it can
    # possibly return is that subgraph's.
    def possible_types(type_name, subgraph)
      all = @abstract[type_name] or return

      per_graph = @possible[type_name]
      return per_graph[subgraph] || [] if per_graph

      all if declared_in(type_name).one?
    end

    def inspect = "#<#{self.class.name} subgraphs=#{@subgraphs.inspect}>"
    alias to_s inspect

    # A @key/@requires/@provides field set is a selection set. Flattened to
    # dotted paths, so a nested one is recognizable as nested by its shape.
    def self.parse_field_set(text)
      flatten(GraphQL.parse("{ #{text} }").definitions.first.selections, [])
    end

    def self.flatten(selections, prefix)
      selections.flat_map do |node|
        unless node.is_a?(GraphQL::Language::Nodes::Field)
          raise GraphWeaver::Error, "a field set holds plain fields only, got #{node.class}"
        end

        if node.selections.any?
          flatten(node.selections, prefix + [node.name])
        else
          [(prefix + [node.name]).join(".")]
        end
      end
    end
    private_class_method :flatten

    private

    # join__Graph's enum values ARE the subgraphs: ACCOUNTS
    # @join__graph(name: "accounts", url: "...").
    #
    # This table reads the join spec under its default name, and only that —
    # a supergraph that renamed it (`@link(url: ".../join/v0.3", as: "j")`)
    # spells every marker `j__` and lands here with nothing found. Being told
    # a composed graph has no subgraphs is worse than being refused, so an
    # empty read is `unsupported` rather than an answer.
    def read_graphs
      enum = @document.definitions.find do |defn|
        defn.is_a?(GraphQL::Language::Nodes::EnumTypeDefinition) && defn.name == "join__Graph"
      end

      enum&.values&.each do |value|
        name = argument(value.directives.find { |d| d.name == "join__graph" }, "name")
        @names[value.name] = name if name
      end

      return if @names.any?

      @unsupported << "no join__Graph enum names the subgraphs — this schema declares a " \
        "composition spec, so either it merged nothing, or it renamed the join spec " \
        "(@link(url: \".../join/v0.3\", as: \"...\")), which this table doesn't follow"
    end

    # What each abstract type can be, from the SDL alone — a union's members,
    # and the objects that name an interface in their `implements`. The
    # per-subgraph split comes from @join__ directives in read_types; this is
    # the whole of it, which is all a single-subgraph abstract type needs.
    def read_abstracts
      @document.definitions.each do |defn|
        case defn
        when GraphQL::Language::Nodes::UnionTypeDefinition
          @abstract[defn.name] = defn.types.map(&:name)
        when GraphQL::Language::Nodes::InterfaceTypeDefinition
          @abstract[defn.name] ||= []
        when GraphQL::Language::Nodes::ObjectTypeDefinition
          defn.interfaces.each { |iface| (@abstract[iface.name] ||= []) << defn.name }
        end
      end
    end

    # An interface implemented by another interface isn't a possible type —
    # only the objects underneath it are, and each names the interface itself.
    def read_possible(defn)
      defn.directives.each do |directive|
        name = subgraph(directive) or next
        case directive.name
        when "join__unionMember"
          member = argument(directive, "member") or next
          ((@possible[defn.name] ||= {})[name] ||= []) << member
        when "join__implements"
          next unless defn.is_a?(GraphQL::Language::Nodes::ObjectTypeDefinition)

          iface = argument(directive, "interface") or next
          ((@possible[iface] ||= {})[name] ||= []) << defn.name
        end
      end
    end

    def read_types
      @document.definitions.each do |defn|
        note_unknown(defn, defn.respond_to?(:name) ? defn.name : "schema")
        next unless defn.respond_to?(:name) && defn.respond_to?(:directives)
        next if defn.name.start_with?("join__", "link__", "core__")

        joins = defn.directives.select { |d| d.name == "join__type" }
        @declared_in[defn.name] = joins.filter_map { |d| subgraph(d) }.uniq
        @keys[defn.name] = read_keys(joins)
        read_possible(defn)

        as_object = joins.select { |d| argument(d, "isInterfaceObject") == true }
        @interface_objects[defn.name] = as_object.filter_map { |d| subgraph(d) } if as_object.any?

        read_fields(defn)
      end
    end

    def read_keys(joins)
      joins.each_with_object({}) do |directive, acc|
        name = subgraph(directive) or next
        acc[name] ||= []
        key = argument(directive, "key")
        acc[name] << self.class.parse_field_set(key) if key && argument(directive, "resolvable") != false
      end
    end

    def read_fields(defn)
      return unless defn.respond_to?(:fields) && defn.fields

      @field_names[defn.name] = defn.fields.map(&:name).to_set
      @fields[defn.name] = defn.fields.filter_map do |field|
        note_unknown(field, "#{defn.name}.#{field.name}")
        applied = field.directives.select { |d| d.name == "join__field" }
        next if applied.empty? # the supergraph says nothing — see owners

        external, resolvable = applied.partition do |d|
          argument(d, "external") == true || argument(d, "usedOverridden") == true
        end

        [field.name, Field.new(
          resolvable.filter_map { |d| subgraph(d) },
          external.filter_map { |d| subgraph(d) },
          resolvable.filter_map { |d| argument(d, "requires") }.first,
          resolvable.filter_map { |d| argument(d, "provides") }.first,
          applied.filter_map { |d| argument(d, "override") }.first,
        )]
      end.to_h
    end

    def note_unknown(node, where)
      return unless node.respond_to?(:directives) && node.directives

      node.directives.each do |directive|
        next unless directive.name.start_with?("join__")
        next if KNOWN.include?(directive.name)

        @unsupported << "#{where} applies @#{directive.name}, which this table doesn't read"
      end
    end

    # the subgraph NAME a directive's graph: argument points at
    def subgraph(directive) = @names[argument(directive, "graph")]

    def argument(directive, name)
      return unless directive

      value = directive.arguments.find { |arg| arg.name == name }&.value
      value.is_a?(GraphQL::Language::Nodes::Enum) ? value.name : value
    end
  end
end
