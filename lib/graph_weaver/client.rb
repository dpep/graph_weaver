# typed: true
# frozen_string_literal: true

require_relative "codegen"
require_relative "errors"
require_relative "inflect"
require_relative "retry"
require_relative "schema_loader"
require_relative "transport/http"

# One object tying the whole flow together — transport, schema, and
# generation:
#
#      github = GraphWeaver.new("https://api.github.com/graphql", auth: token, cache: true)
#
#      RepoQuery = github.parse("queries/repo.graphql")   # implicit schema + transport
#      github.execute!("query { viewer { login } }")      # one-shot
#
# The first argument is a url (a transport is built; the schema comes
# from introspection on first use, cached per cache:/ttl:) or a schema
# source — a live schema class (which also executes in-process, through
# an InProcess wrapper that takes context:), or a path/SDL/introspection
# dump via SchemaLoader.
#
# transport: means "which transport" alongside a url — :http (the
# default, always, whatever else the Gemfile loads) or :faraday — and
# "this transport" alongside a schema source.
#
# Clients are independent: each has its own transport and schema, so one
# app can talk to several GraphQL servers. Scalar/enum/type registrations
# are a codegen concern and live in one global registry (see
# GraphWeaver.register_scalar) — the same registry the rake tasks bake.
class GraphWeaver::Client
  URL = %r{\Ahttps?://}i

  def initialize(source, auth: nil, headers: {}, retries: false, transport: nil, cache: nil, ttl: nil,
    open_timeout: nil, read_timeout: nil, context: nil, &middleware)
    if source.is_a?(String) && source.match?(URL)
      raise ArgumentError, "context: applies to a schema class executing in-process" if context

      built = build_transport(source, auth:, headers:, kind: transport, open_timeout:, read_timeout:, &middleware)
      @transport = wrap_retries(built, retries)
    else
      if auth || middleware || retries || open_timeout || read_timeout
        raise ArgumentError, "auth:/retries:/timeouts/middleware apply to a url — got a schema source"
      end
      if transport.is_a?(Symbol)
        # naming a bundled transport only builds one from a url
        raise ArgumentError, "transport: #{transport.inspect} needs a url — got a schema source; pass a built transport"
      end
      if cache || ttl
        # a schema source never introspects, so a cache would silently no-op
        raise ArgumentError, "cache:/ttl: apply to url introspection — got a schema source"
      end

      # a live schema class doubles as an in-process transport; a loaded
      # dump has no resolvers, so it is type information only
      @schema = source.is_a?(Module) ? source : GraphWeaver::SchemaLoader.load(source)

      if context && !(source.is_a?(Module) && transport.nil?)
        # nothing would ever read it — a dump has no resolvers, and an
        # explicit transport carries its own
        raise ArgumentError, "context: applies to a schema class executing in-process"
      end

      # InProcess adds context:, logging and branded errors to the bare
      # schema class, which stays usable on its own everywhere else
      @transport = transport ||
        (GraphWeaver::InProcess.new(source, context: context || {}) if source.is_a?(Module))
    end

    @cache = cache
    @ttl = ttl
  end

  # The transport queries run through: a url-built transport, an
  # explicit transport:, or the live schema class executing in-process.
  # Clients are self-contained — the app default never leaks in; nil for
  # schema-dump clients (type information only).
  attr_reader :transport

  # transport, when this client must be able to execute
  def transport!
    transport or raise GraphWeaver::Error,
      "this client has no transport (built from a schema dump) — pass a url or transport:"
  end

  # The schema, introspecting through the transport on first use (cached
  # per the client's cache:/ttl:) unless one was given up front.
  def schema
    @schema ||= GraphWeaver::SchemaLoader.introspect(transport!, cache: @cache, ttl: @ttl)
  end

  # Parse a query (a .graphql path or raw string) into a typed module
  # bound to this client's schema and transport (including a live schema
  # class executing in-process — the module came from this client, so it
  # runs against it; pass a client per call to override, e.g. with a
  # fake). Same as GraphWeaver.parse(schema: self, ...).
  def parse(query, name: nil)
    GraphWeaver.parse(schema: self, query:, name:)
  end

  # Parse every .graphql query in a directory into typed modules, named
  # like generation would name them — the no-build-step analog of
  # generate! + load_generated!:
  #
  #      github.load_queries!                        # queries/person.graphql => ::PersonQuery
  #      github.load_queries!(namespace: Github)     # => Github::PersonQuery
  #                                                  # a mutation file => ::AdoptMutation
  #
  # Reloadable (constants are replaced), so it suits consoles and dev.
  # Returns the modules.
  def load_queries!(dir = nil, namespace: Object)
    Dir[File.join(dir || GraphWeaver.queries_path, "*.graphql")].sort.map do |path|
      name = GraphWeaver.module_name(path, File.read(path))
      if namespace.const_defined?(name, false)
        # the constant moves, its instances don't — a struct built before the
        # reload keeps failing is_a? against the new module, silently
        GraphWeaver.log(:info) do
          "replacing #{name} — objects built from the previous module stay instances of it"
        end
        namespace.send(:remove_const, name)
      end
      GraphWeaver.log(:info) { "loaded #{name} from #{path}" }
      namespace.const_set(name, parse(path))
    end
  end

  # One-shot dynamic execution — parse + execute, returning the typed
  # Response envelope (execute! returns the result or raises). Variables
  # are plain kwargs, exactly as on a generated module; graphql-cased
  # string keys work too.
  def execute(query, **variables)
    mod = parse(query)
    kwargs = variables.to_h { |key, value| [GraphWeaver::Inflect.underscore(key.to_s).to_sym, value] }
    mod.execute(transport!, **kwargs)
  end

  def execute!(query, **variables)
    execute(query, **variables).data!
  end

  private

  # auth: is a token — "Bearer" is assumed unless the string carries its
  # own scheme ("Basic dXNlcjpwYXNz...").
  #
  # Transport pick: always Transport::HTTP unless you ask for Faraday
  # (transport: :faraday, or a middleware block, which is Faraday's
  # anyway). Deliberately NOT `defined?(Faraday)`: faraday rides along
  # transitively in most bundles (stripe, octokit, ...), so sniffing for
  # it lets an unrelated gem swap your transport — along with its
  # timeouts and, since Faraday's default net_http adapter reconnects
  # per request, your connection reuse. Same code, same transport.
  def build_transport(url, auth:, headers:, kind:, open_timeout: nil, read_timeout: nil, &middleware)
    headers = headers.dup
    if auth
      headers["Authorization"] ||= auth.include?(" ") ? auth : "Bearer #{auth}"
    end

    # nil means "the transport's default" — both bundled ones agree on it
    timeouts = { open_timeout:, read_timeout: }.compact

    transport =
      if transport_kind(kind, middleware) == :faraday
        build_faraday(url, headers:, timeouts:, &middleware)
      else
        GraphWeaver::Transport::HTTP.new(url, headers:, **timeouts)
      end

    GraphWeaver.log(:info) { "transport: #{transport.class} -> #{url}" }
    transport
  end

  # Which bundled transport a url client builds: the explicit
  # transport:, else Faraday when a middleware block asks for it.
  def transport_kind(kind, middleware)
    case kind
    when nil then middleware ? :faraday : :http
    when :faraday then :faraday
    when :http
      raise ArgumentError, "middleware blocks are Faraday's — pass transport: :faraday" if middleware

      :http
    else
      raise ArgumentError, "transport: takes :http or :faraday alongside a url, got #{kind.inspect}"
    end
  end

  # The faraday gem is optional, so a missing one reads as a Gemfile
  # problem rather than a stack trace out of require.
  def build_faraday(url, headers:, timeouts:, &middleware)
    begin
      require_relative "transport/faraday"
    rescue LoadError
      nil # reported below, alongside a gem that loaded but wasn't there
    end

    unless defined?(::Faraday)
      raise ArgumentError, "the faraday transport needs the faraday gem — add it to your Gemfile"
    end

    GraphWeaver::Transport::Faraday.new(url, headers:, **timeouts, &middleware)
  end

  # retries: is off by default — true for Retry defaults, or a
  # Hash of its options
  def wrap_retries(transport, retries)
    case retries
    when true then GraphWeaver::Retry.new(transport)
    when false, nil then transport
    else GraphWeaver::Retry.new(transport, **retries)
    end
  end
end
