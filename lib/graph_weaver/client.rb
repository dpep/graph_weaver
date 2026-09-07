# typed: true
# frozen_string_literal: true

require_relative "codegen"
require_relative "errors"
require_relative "inflect"
require_relative "parsing"
require_relative "retry"
require_relative "schema_loader"
require_relative "transport/http"

# One object tying the whole flow together — transport, schema, and
# generation:
#
#      github = GraphWeaver.new("https://api.github.com/graphql", auth: token, cache: true)
#
#      RepoQuery = github.parse("queries/repo.graphql")   # implicit schema + client
#      github.run!("query { viewer { login } }")          # one-shot
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
  include GraphWeaver::Parsing

  URL = %r{\Ahttps?://}i

  def initialize(source, auth: nil, headers: {}, retries: false, transport: nil, cache: nil, ttl: nil,
    open_timeout: nil, read_timeout: nil, context: nil, &middleware)
    check_source!(source)

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

  # The client contract, same as every transport: a query and its
  # variables in, the raw response hash out. (#run is the one-shot that
  # parses and returns the typed envelope.)
  def execute(query, variables: {}, operation_name: nil)
    transport!.execute(query, variables:, operation_name:)
  end

  # One-shot dynamic execution — parse + run, returning the typed
  # Response envelope (run! returns the result or raises). Variables
  # are plain kwargs, exactly as on a generated module; graphql-cased
  # string keys work too.
  def run(query, **variables)
    mod = parse(query)
    kwargs = variables.to_h { |key, value| [GraphWeaver::Inflect.underscore(key.to_s).to_sym, value] }
    mod.execute(**kwargs)
  end

  def run!(query, **variables)
    run(query, **variables).data!
  end

  private

  # Anything already speaking the client contract — another Client,
  # InProcess, Retry, a transport, a fake, the test router — carries no
  # schema to generate from, so it can't stand in as the schema source.
  # Without this it is handed to SchemaLoader and fails as `undefined
  # method 'lstrip'`.
  def check_source!(source)
    # a graphql-ruby schema class executes too, and *is* a schema source
    return if source.is_a?(Module) || !source.respond_to?(:execute)

    raise GraphWeaver::Error, "#{source.class} is a client, not a schema source — pass the schema, and this " \
      "as its transport: GraphWeaver.new(schema, transport: client). For a live schema class " \
      "with a context: GraphWeaver.new(schema, context: { ... })."
  end

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
