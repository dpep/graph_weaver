# typed: ignore — Rails::Railtie DSL
# frozen_string_literal: true

# Rails wiring, so the conventional layout needs no ceremony:
#
# - rake tasks: Rails.application.load_tasks collects every Railtie's
#   rake_tasks block, so graph_weaver:* tasks appear with no Rakefile
#   edit. (Outside Rails there is no task-discovery hook — add
#   `require "graph_weaver/tasks"` to your Rakefile.)
# - generated modules: required at boot once every registration has run —
#   both the initializer kind and the to_prepare kind, since a generated
#   file `include`s the type helper it was generated with and that
#   constant must resolve. load_generated! stays idempotent, so calling
#   it yourself too is harmless.
# - Zeitwerk: the generated directory is hidden from it, since the
#   default one lives under app/ and its files define top-level
#   constants.
# - watch mode: in development, editing a .graphql regenerates before the
#   next request, the way editing a route or a locale takes effect.
class GraphWeaver::Railtie < Rails::Railtie
  # config.graph_weaver.watch — false to never regenerate during a request.
  # Default: development only. Every other setting is a top-level one, and an
  # OrderedOptions would take `config.graph_weaver.queries_paths = ...` without
  # a word and do nothing with it, so this refuses what it doesn't read.
  class Options < ActiveSupport::OrderedOptions
    KEYS = %i[watch].freeze

    def method_missing(name, *args)
      key = name.to_s.delete_suffix("=").delete_suffix("?").delete_suffix("!").to_sym
      return super if KEYS.include?(key)

      raise ArgumentError, refusal(key)
    end

    def respond_to_missing?(name, _private = false)
      KEYS.include?(name.to_s.delete_suffix("=").delete_suffix("?").delete_suffix("!").to_sym)
    end

    private

    def refusal(key)
      near = GraphWeaver::Internal::Util.did_you_mean(KEYS.map(&:to_s), key.to_s)
      fix =
        if GraphWeaver.respond_to?(:"#{key}=") then " — GraphWeaver.#{key} = ... is the setting you want"
        elsif near then " (did you mean #{near}?)"
        end
      "config.graph_weaver takes #{KEYS.join(", ")}, not #{key}#{fix}"
    end
  end

  config.graph_weaver = Options.new

  class << self
    # The file watcher, so the to_prepare block below can ask it whether a
    # query changed. nil when not watching.
    attr_accessor :watcher

    # What ignore_generated actually hid, resolved. Zeitwerk only reads its
    # ignore list at setup, so anything that arrives later isn't hidden by
    # calling ignore again — check_generated_ignored! refuses instead.
    attr_accessor :ignored_dirs
  end

  rake_tasks do
    require "graph_weaver/tasks"
  end

  # generated/person_query.rb defines ::PersonQuery, but Zeitwerk infers
  # Generated::PersonQuery from the path — and app/graphql/generated is
  # inside an autoload root by default, so eager loading raised
  # "uninitialized constant Generated::PersonQuery" in production while
  # development (lazy) was fine. load_generated! below requires them.
  #
  # after: :load_config_initializers as well as before Zeitwerk's setup — a
  # graph's output: is only known once the app has declared its graphs, and
  # with only the `before:` constraint this ran ~20 initializers too early, so
  # an output outside the conventional glob was eager loaded on top of
  # load_generated! and died on a redefined enum.
  initializer "graph_weaver.ignore_generated",
    after: :load_config_initializers, before: :setup_main_autoloader do
    # patterns, not paths — generated_paths may be globs, and Zeitwerk
    # expands its own at setup (which is what this runs before)
    dirs = GraphWeaver::Internal::Util.generated_dirs.map { GraphWeaver::Railtie.autoload_path(_1) }
    GraphWeaver::Railtie.check_autoload_once!(dirs)
    GraphWeaver::Railtie.ignored_dirs = dirs
    Rails.autoloaders.each { |loader| dirs.each { |path| loader.ignore(path) } }
  end

  # The `once` autoloader is set up in bootstrap, and Zeitwerk reads its ignore
  # list only at setup — so the `loader.ignore` above, which runs after
  # config/initializers, hides nothing from it however the output is spelled.
  # The generic advice ("name it in GraphWeaver.generated_paths from
  # config/initializers") produced byte-identical output for this one, so it
  # gets its own refusal, naming the place that is still early enough.
  def self.check_autoload_once!(dirs)
    return unless Rails.respond_to?(:autoloaders) && Rails.autoloaders.respond_to?(:once)

    once = Rails.autoloaders.once
    dirs.each do |dir|
      next unless autoloaded?(once, dir)

      subject, short = describe_output(dir)
      raise GraphWeaver::Error,
        "#{subject} is under config.autoload_once_paths, which Rails sets the `once` autoloader up on " \
        "before config/initializers run — so nothing GraphWeaver can do from there hides it, and its " \
        "modules can't load. Hide it in config/application.rb, which is still early enough: " \
        "Rails.autoloaders.once.ignore(Rails.root.join(#{short.inspect})) — or generate somewhere that " \
        "is not an autoload-once path."
    end
  end

  # A generated path as ZEITWERK sees it: resolved, and with symlinks followed,
  # because Zeitwerk walks real directories. Ignoring a symlinked output hid it
  # under a name Zeitwerk never visits, and the refusal below compared that same
  # name against real autoload roots and so never fired — including for an
  # absolute output through a symlinked ancestor, the Capistrano current/ shape.
  # Only this seam needs it: everywhere else a path stays the setting expanded,
  # so what the gem reports is what you wrote.
  def self.autoload_path(path)
    resolved = GraphWeaver::Internal::Util.resolve(path)
    File.exist?(resolved) ? File.realpath(resolved) : resolved
  end

  # Whether this loader would actually try to load `dir`: one of its roots
  # contains it and its own ignore list doesn't cover it. Asking only about the
  # roots refused an app that had called Rails.autoloaders.main.ignore(dir)
  # itself, and told it the directory couldn't be hidden — when it already was.
  #
  # Zeitwerk answers that question under two names: `ignores?` was public until
  # 2.6.1 made it internal, which publishes it as `__ignores?`. Neither present
  # (some other loader in the slot) falls back to refusing, which is what this
  # did for everyone before.
  IGNORES = %i[__ignores? ignores?].freeze

  def self.autoloaded?(loader, dir)
    return false unless loader.dirs.any? { |root| dir.start_with?("#{root}/") }

    asked = IGNORES.find { |name| loader.respond_to?(name) }
    asked.nil? || !loader.public_send(asked, dir)
  end

  # How a refusal names a generated directory: what writes it, and the path the
  # way the graph itself spells it — not the symlink target autoload_path
  # resolved to, since the advice has to name something the reader can find in
  # their own config.
  def self.describe_output(dir)
    graph = GraphWeaver.graphs.find { autoload_path(_1.output) == dir }
    short = GraphWeaver::Internal::Util.relative(GraphWeaver::Internal::Util.resolve(graph&.output || dir))
    ["#{graph ? "graph :#{graph.name}'s output" : "generated path"} #{short}", short]
  end

  # A graph declared from to_prepare — what the docs say to do when its block
  # names an autoloaded constant — is declared after Zeitwerk is set up, and
  # Zeitwerk reads its ignore list only then. So an output that arrives that
  # late can't be hidden: its files load as ordinary autoloads and raise on the
  # constant they don't define, in a Zeitwerk error that blames a dropped
  # extend_type. Refuse, and name what actually happened.
  def self.check_generated_ignored!
    # no autoloaders, no Zeitwerk, nothing to refuse
    return unless Rails.respond_to?(:autoloaders)

    late = GraphWeaver::Internal::Util.generated_dirs.map { autoload_path(_1) } - Array(ignored_dirs)
    return if late.empty?

    late.each do |dir|
      next unless Rails.autoloaders.any? { |loader| autoloaded?(loader, dir) }

      subject, short = describe_output(dir)
      raise GraphWeaver::Error,
        "#{subject} was declared after Rails " \
        "set Zeitwerk up on it, so it can't be hidden from autoloading and its modules can't load. Declare " \
        "the graph in config/initializers (schema -> { MyApp::Schema } resolves an autoloaded class when " \
        "generation asks), or name #{short.inspect} in GraphWeaver.generated_paths there."
    end
  end

  # Rails.logger, unless the app already chose one (set
  # GraphWeaver.logger = nil in an initializer to silence)
  initializer "graph_weaver.logger" do
    GraphWeaver.logger = Rails.logger if GraphWeaver.logger.nil?
  end

  # The app already declared what is sensitive, so variables logged at debug
  # honour the same list as its request logs — including the Procs and dotted
  # paths only ParameterFilter understands. after: :load_config_initializers,
  # since filter_parameter_logging.rb is where an app adds to it.
  initializer "graph_weaver.filter_parameters", after: :load_config_initializers do |app|
    filters = app.config.filter_parameters
    next if filters.empty? || GraphWeaver.filter_parameters != GraphWeaver::DEFAULT_FILTER_PARAMETERS

    GraphWeaver.filter_parameters = ActiveSupport::ParameterFilter.new(filters)
  end

  # Watch mode. A .graphql edit should reach the next request the way a route
  # or a locale change does, so the query directories and the schema dump
  # become one of Rails' own reloaders: a change there alone triggers a reload
  # cycle, and the to_prepare below regenerates before it loads. Off with
  #
  #      config.graph_weaver.watch = false
  #
  # after: :load_config_initializers — that's where an app moves
  # queries_paths, and the finisher that reads app.reloaders runs later still.
  #
  # to_prepare, not the initializer itself: a graph declared from one of those
  # (what the docs say to do when its block names an autoloaded constant) isn't
  # declared until every initializer has run, and a watcher built before it
  # watched the default queries_paths — an edit to that graph's .graphql
  # silently never regenerated. Registered after the app's own blocks, so every
  # graph is in by the time this runs, and app.reloaders is read per request, so
  # joining it this late still counts. Once, though: a dev reload re-runs
  # to_prepare, and a second watcher is a second reloader over the same files.
  initializer "graph_weaver.watch", after: :load_config_initializers do |app|
    watched = false
    app.config.to_prepare do
      next if watched

      watched = true
      GraphWeaver::Railtie.watch!(app)
    end
  end

  # Registers the watcher, and says so: this is the one thing GraphWeaver does
  # that writes a checked-in file outside a rake task. Returns it, or nil when
  # nothing is being watched.
  def self.watch!(app)
    watch = app.config.graph_weaver.watch
    watch = Rails.env.development? if watch.nil?
    # with reloading off nothing re-runs to_prepare, so a watcher could only
    # promise something it can't do
    return self.watcher = nil unless watch && app.config.reloading_enabled?

    # a directory that doesn't exist yet is still watched — FileUpdateChecker
    # re-globs on every check, and its keys may themselves be globs
    watched = GraphWeaver.graphs.flat_map(&:queries) | GraphWeaver.fragments_paths
    # the dump codegen would read, or where it goes once someone takes one
    dump = GraphWeaver::SchemaLoader.locate_path || GraphWeaver.schema_path

    dirs = watched.to_h { |path| [GraphWeaver::Internal::Util.resolve(path), %w[graphql gql]] }
    self.watcher = app.config.file_watcher.new([GraphWeaver::Internal::Util.resolve(dump)], dirs) { regenerate! }
    app.reloaders << watcher
    GraphWeaver::Internal::Log.log(:info) do
      "watching #{(watched << GraphWeaver::Internal::Util.relative(dump)).join(", ")} — an edit regenerates " \
        "#{GraphWeaver.graphs.map(&:output).uniq.join(", ")} before the next request " \
        "(config.graph_weaver.watch = false to stop)"
    end
    watcher
  end

  # Regenerate in place, and keep serving when a query doesn't compile: a file
  # saved mid-edit shouldn't take the dev server down, and the modules already
  # loaded are the ones that worked a keystroke ago. Nothing is half-written on
  # that path — generation validates every query before it writes any file — so
  # one error per save, and the next save that compiles takes.
  def self.regenerate!
    GraphWeaver.generate!
    changed = GraphWeaver.changed_files
    # before reloading, not after: reloading logs a line of its own, and
    # "loaded 4 generated module(s)" ahead of "regenerated ..." reads backwards
    GraphWeaver::Internal::Log.log(:info) do
      next "generated modules already up to date" if changed.empty?

      "regenerated #{changed.join(", ")}"
    end
    GraphWeaver.reload_generated!
  rescue GraphWeaver::Error => e
    GraphWeaver::Internal::Log.log(:error) { "keeping the modules already loaded — #{e.message}" }
  end

  # A generated file `include`s the type helper it was generated with, so it
  # can't load until that constant resolves — and both Zeitwerk's setup and
  # the app's own to_prepare blocks (where extend_type/register_enum are told
  # to register, Codegen::AUTOLOAD_HINT) happen after config/initializers.
  # to_prepare, not `after:` a finisher initializer: naming one there makes
  # tsort hoist it ahead of the app's own config/initializers. Re-running on
  # each dev reload is free — require is idempotent — and picks up a module
  # generated since boot.
  initializer "graph_weaver.load_generated", after: :load_config_initializers do |app|
    app.config.to_prepare do
      # The graph_weaver tasks write these files and need none of them loaded.
      # Loading them would let a stale one block its own repair: a dropped
      # extend_type leaves a dangling include, and generate depends on
      # :environment, so boot failed before the task that would regenerate it.
      next if GraphWeaver.skip_generated_load

      # the app's own to_prepare blocks have run by now, so this is the first
      # point that sees every graph — and the last before one of them loads
      GraphWeaver::Railtie.check_generated_ignored!

      # Regenerate first, then load — and here rather than in the watcher's own
      # to_run, so an extend_type or register_enum the app registers in its own
      # to_prepare is already in place (that block was registered at
      # :load_config_initializers, so it has run by now). A run that
      # regenerated has already reloaded what it wrote.
      next if GraphWeaver::Railtie.watcher&.execute_if_updated

      # entries may be globs, so Dir[] rather than Dir.exist?
      generated = GraphWeaver::Internal::Util.generated_dirs.any? do |dir|
        Dir[GraphWeaver::Internal::Util.resolve(dir)].any?
      end
      next unless generated

      # `require` no-ops on a file it has already read — which is what we want,
      # except when the constant that file defined is gone. A graph's
      # `namespace:` is normally a module Zeitwerk owns (app/graphql/accounts/
      # implies Accounts), and unloading it on a dev reload takes the generated
      # module nested inside it with it; require then restores nothing and every
      # request 500s on "uninitialized constant Accounts::PersonQuery" until a
      # .graphql edit happens to trigger the watcher. An un-namespaced module
      # defines a top-level constant Zeitwerk never manages, so it survives.
      if GraphWeaver.graphs.any?(&:namespace)
        GraphWeaver.reload_generated!
      else
        GraphWeaver.load_generated!
      end
    end
  end
end
