# typed: true
# frozen_string_literal: true

require_relative "codegen"
require_relative "errors"
require_relative "inflect"
require_relative "retry_executor"
require_relative "schema_loader"
require_relative "transport/http"

# One object tying the whole flow together — transport, schema, and
# generation:
#
#      github = GraphWeaver.new("https://api.github.com/graphql", auth: token, cache: true)
#      github.register_scalar("DateTime", type: Time, serialize: :iso8601, requires: "time")
#
#      RepoQuery = github.parse("queries/repo.graphql")   # implicit schema + transport
#      github.execute!("query { viewer { login } }")      # one-shot
#
# The first argument is a url (a transport is built; the schema comes
# from introspection on first use, cached per cache:/ttl:) or a schema
# source — a live schema class (which also executes in-process), or a
# path/SDL/introspection dump via SchemaLoader. Pass executor: to bring
# your own transport for a schema source.
#
# Clients are independent: each has its own transport, schema, and
# scalar registrations, so one app can talk to several GraphQL servers —
# even ones that disagree about what a "DateTime" is.
class GraphWeaver::Client
  URL = %r{\Ahttps?://}i

  def initialize(source, auth: nil, headers: {}, retries: false, executor: nil, cache: nil, ttl: nil, &middleware)
    if source.is_a?(String) && source.match?(URL)
      raise ArgumentError, "pass a url or executor:, not both" if executor

      @executor = wrap_retries(build_transport(source, auth:, headers:, &middleware), retries)
    else
      if auth || middleware || retries != false
        raise ArgumentError, "auth:/retries:/middleware apply to a url — got a schema source"
      end

      # a live schema class doubles as an in-process executor; a loaded
      # dump has no resolvers, so it is type information only
      @schema = source.is_a?(Module) ? source : GraphWeaver::SchemaLoader.load(source)
      @implicit_executor = source if source.is_a?(Module)
      @executor = executor
    end

    @cache = cache
    @ttl = ttl
    @scalars = {}
  end

  # The transport queries run through: this client's own (a url-built
  # transport, or executor:), else the global default, else — last, so a
  # configured global such as a test fake still wins — the live schema
  # class executing in-process.
  def executor
    return @executor if @executor
    return GraphWeaver.executor if GraphWeaver.executor?

    @implicit_executor || GraphWeaver.executor # raises the helpful error
  end

  # The schema, introspecting through the executor on first use (cached
  # per the client's cache:/ttl:) unless one was given up front.
  def schema
    @schema ||= GraphWeaver::SchemaLoader.introspect(executor, cache: @cache, ttl: @ttl)
  end

  # Client-scoped scalar registration: consulted before the global
  # registry when this client generates code, so two clients can map the
  # same scalar name onto different Ruby types. Same signature as
  # GraphWeaver.register_scalar.
  def register_scalar(graphql_name, type:, cast: nil, serialize: nil, requires: nil, coerce: nil)
    @scalars[graphql_name.to_s] =
      GraphWeaver::Codegen::ScalarType.new(graphql_name, type:, cast:, serialize:, requires:, coerce:)
  end

  # Parse a query (a .graphql path or raw string) into a typed module
  # bound to this client's schema, scalars, and transport.
  def parse(query, name: nil)
    GraphWeaver.parse(schema:, query:, name:, executor: @executor, scalars: @scalars)
  end

  # Parse every .graphql query in a directory into typed modules, named
  # like generation would name them — the no-build-step analog of
  # generate! + load_generated!:
  #
  #      github.load_queries!                        # queries/person.graphql => ::PersonQuery
  #      github.load_queries!(namespace: Github)     # => Github::PersonQuery
  #
  # Reloadable (constants are replaced), so it suits consoles and dev.
  # Returns the modules.
  def load_queries!(dir = GraphWeaver.queries_path, namespace: Object)
    Dir[File.join(dir, "*.graphql")].sort.map do |path|
      name = "#{GraphWeaver::Inflect.camelize(File.basename(path, ".graphql"))}Query"
      namespace.send(:remove_const, name) if namespace.const_defined?(name, false)
      namespace.const_set(name, parse(path))
    end
  end

  # One-shot dynamic execution — parse + execute, returning the typed
  # Response envelope (execute! returns the result or raises). Variables
  # are plain kwargs, exactly as on a generated module ("executor" is
  # reserved); graphql-cased string keys work too.
  def execute(query, **variables)
    mod = parse(query)
    kwargs = variables.to_h { |key, value| [GraphWeaver::Inflect.underscore(key.to_s).to_sym, value] }
    mod.execute(**kwargs, executor:)
  end

  def execute!(query, **variables)
    execute(query, **variables).data!
  end

  private

  # auth: is a token — "Bearer" is assumed unless the string carries its
  # own scheme ("Basic dXNlcjpwYXNz..."). Transport pick: Faraday when
  # the app already loads it (its middleware/proxy/timeout ecosystem
  # comes along), the zero-dependency Transport::HTTP otherwise.
  # Detection is `defined?(Faraday)` — deliberately NOT a require:
  # faraday rides along transitively in most bundles (stripe, octokit,
  # ...), and try-requiring would switch transports on apps that never
  # chose it. With faraday under `require: false`, load it before
  # building the client.
  def build_transport(url, auth:, headers:, &middleware)
    headers = headers.dup
    if auth
      headers["Authorization"] ||= auth.include?(" ") ? auth : "Bearer #{auth}"
    end

    if defined?(::Faraday)
      require_relative "transport/faraday"
      GraphWeaver::Transport::Faraday.new(url, headers:, &middleware)
    elsif middleware
      raise ArgumentError, "middleware blocks require the faraday gem"
    else
      GraphWeaver::Transport::HTTP.new(url, headers:)
    end
  end

  # retries: is off by default — true for RetryExecutor defaults, or a
  # Hash of its options
  def wrap_retries(transport, retries)
    case retries
    when true then GraphWeaver::RetryExecutor.new(transport)
    when false, nil then transport
    else GraphWeaver::RetryExecutor.new(transport, **retries)
    end
  end
end
