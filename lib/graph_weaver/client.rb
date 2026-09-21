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

  # refused from two branches — a url source, and a schema source with
  # nothing to hand a context to — so the two can't word it differently
  CONTEXT_IN_PROCESS = "context: applies to a schema class executing in-process"

  # the whole rule, said wherever a retry option is refused
  RETRY_RULE = "retries: is how many attempts follow the first; the other retry options sit beside it"
  private_constant :CONTEXT_IN_PROCESS, :RETRY_RULE

  def initialize(source, auth: nil, headers: {}, transport: nil, cache: nil, ttl: nil,
    open_timeout: nil, read_timeout: nil, pool_size: nil, context: nil,
    retries: false, backoff: nil, base_delay: nil, max_delay: nil, jitter: nil, retry_on: nil,
    retry_if: nil, retry_codes: nil, retry_mutations: nil, sleeper: nil, &middleware)
    check_source!(source)

    # Retry's options, spelled the same and passed straight through; nil
    # is "not given", so their defaults stay in Retry alone
    retry_options = { backoff:, base_delay:, max_delay:, jitter:, retry_on:, retry_if:,
                      retry_codes:, retry_mutations:, sleeper: }.compact

    if source.is_a?(String) && source.match?(URL)
      raise ArgumentError, CONTEXT_IN_PROCESS if context

      built = build_transport(source, auth:, headers:, kind: transport, open_timeout:, read_timeout:, pool_size:,
        &middleware)
      @transport = wrap_retries(built, retries, retry_options)
    else
      if auth || middleware || retries || open_timeout || read_timeout || pool_size || !retry_options.empty?
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
      # A supergraph's routing table lives in the file, not in the loaded
      # schema, so the path is the only thing that can name one later. Told
      # from SDL by its extension, as SchemaLoader tells it.
      @schema_source = source if !source.is_a?(Module) && GraphWeaver::SchemaLoader.dump_path?(source)

      if context && !(source.is_a?(Module) && transport.nil?)
        # nothing would ever read it — a dump has no resolvers, and an
        # explicit transport carries its own
        raise ArgumentError, CONTEXT_IN_PROCESS
      end

      # InProcess adds context:, logging and branded errors to the bare
      # schema class, which stays usable on its own everywhere else
      @transport = transport ||
        (GraphWeaver::InProcess.new(source, context: context || {}) if source.is_a?(Module))
    end

    @cache = cache
    @ttl = ttl
    @schema_lock = Mutex.new
  end

  # Called by generated code — not semver'd for direct use.
  #
  # What actually runs a request, for anything in a client slot. A bare
  # graphql-ruby schema class satisfies the execute contract on its own, so
  # `client "Billing::Schema"`, `GraphWeaver.client = MyApp::Schema` and
  # `execute!(client: MyApp::Schema)` all worked — and every one of them ran
  # with no instrumentation seam at all: Schema.execute is not ours to
  # bracket, so there was no APM event and no log line, not even at debug.
  # One rule, applied wherever a client is read: a schema class gets the same
  # InProcess wrapper GraphWeaver.new(Schema) builds. Everything else — a
  # Client, a transport, a Retry, a fake — passes through untouched.
  #
  # Not memoized: the wrapper is two ivars beside a whole GraphQL execution,
  # and in dev the class object is replaced on reload, so anything held onto
  # would be the stale one.
  def self.instrumented(client)
    return client unless client.is_a?(Class) && client <= GraphQL::Schema

    GraphWeaver::InProcess.new(client)
  end

  # The transport queries run through: a url-built transport, an
  # explicit transport:, or the live schema class executing in-process.
  # Clients are self-contained — the app default never leaks in; nil for
  # schema-dump clients (type information only).
  attr_reader :transport

  # The dump this client's schema was read from, or nil for a url, a schema
  # class, or inline SDL. What a graph named by this client is named by.
  attr_reader :schema_source

  # transport, when this client must be able to execute
  private def transport!
    transport or raise GraphWeaver::Error,
      "this client has no transport (built from a schema dump) — pass a url or transport:"
  end

  # How long a failed introspection answers for the threads behind it. The
  # lock makes a cold schema one round trip at a time, so against a hung
  # upstream every queued thread used to pay its own read_timeout in turn —
  # 8 threads at the 30s default is four minutes of occupied worker, and the
  # next wave paid it again. A second is enough to collapse a wave and the
  # retry right behind it, and short enough that an upstream which comes back
  # is tried again on the next request. Deliberately not a circuit breaker:
  # nothing here counts failures or stays open.
  FAILURE_TTL = 1.0
  private_constant :FAILURE_TTL

  # The schema, introspecting through the transport on first use (cached
  # per the client's cache:/ttl:) unless one was given up front.
  #
  # Locked because a cold Puma process serves its first requests
  # concurrently: a bare ||= there is one full introspection round trip per
  # in-flight thread, each of them also writing the cache file.
  def schema
    @schema_lock.synchronize do
      next @schema if @schema
      raise @schema_error if @schema_error && Process.clock_gettime(Process::CLOCK_MONOTONIC) < @schema_error_until

      begin
        @schema_error = nil
        @schema = GraphWeaver::SchemaLoader.introspect(transport!, cache: @cache, ttl: @ttl)
      rescue GraphWeaver::Error => e
        @schema_error = e
        @schema_error_until = Process.clock_gettime(Process::CLOCK_MONOTONIC) + FAILURE_TTL
        raise
      end
    end
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
  def build_transport(url, auth:, headers:, kind:, open_timeout: nil, read_timeout: nil, pool_size: nil, &middleware)
    headers = headers.dup
    if auth
      unless auth.is_a?(String) || auth.respond_to?(:call)
        raise ArgumentError, "auth: takes a token string, or something answering #call that returns " \
          "one per request, got #{auth.class} — other headers go in headers:"
      end

      # a callable stays callable: both transports resolve a header value per
      # request, which is what a token that expires needs
      headers["Authorization"] ||=
        auth.respond_to?(:call) ? -> { bearer(auth.call) } : bearer(auth)
    end

    # nil means "the transport's default" — both bundled ones agree on it
    timeouts = { open_timeout:, read_timeout: }.compact

    transport =
      if transport_kind(kind, middleware) == :faraday
        # Faraday's adapter owns its connections; a pool ceiling here would be
        # a number nothing reads, so say so instead of dropping it
        raise ArgumentError, "pool_size: sizes the bundled HTTP transport's pool — Faraday's adapter " \
          "manages its own connections, so configure it there" if pool_size
        build_faraday(url, headers:, timeouts:, &middleware)
      else
        GraphWeaver::Transport::HTTP.new(url, headers:, pool_size:, **timeouts)
      end

    GraphWeaver::Internal::Log.log(:info) { "transport: #{transport.class} -> #{transport.safe_url}" }
    transport
  end

  # "Bearer" is assumed unless the token carries its own scheme; nil is a
  # token the caller declined to produce, and drops the header.
  def bearer(token)
    return if token.nil?

    token.to_s.include?(" ") ? token.to_s : "Bearer #{token}"
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

  # retries: is off by default — a count, or true for Retry's default
  # count. Without it nothing wraps the transport, so a retry option on
  # its own would quietly do nothing.
  def wrap_retries(transport, retries, options)
    case retries
    when Integer then GraphWeaver::Retry.new(transport, retries:, **options)
    when true then GraphWeaver::Retry.new(transport, **options)
    when false, nil
      raise ArgumentError, "#{options.keys.first}: needs retries: — #{RETRY_RULE}" if options.any?

      transport
    when Hash
      # it used to take a Hash of Retry options, which read as a key nested in itself
      flat = retries.map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
      raise ArgumentError, "retries: no longer takes a Hash — pass GraphWeaver.new(url, #{flat})"
    else
      raise ArgumentError, "#{RETRY_RULE} — got #{retries.inspect}"
    end
  end
end
