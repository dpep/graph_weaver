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
  # Default: development only.
  config.graph_weaver = ActiveSupport::OrderedOptions.new

  class << self
    # The file watcher, so the to_prepare block below can ask it whether a
    # query changed. nil when not watching.
    attr_accessor :watcher
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
    Rails.autoloaders.each do |loader|
      # patterns, not paths — generated_paths may be globs, and Zeitwerk
      # expands its own at setup (which is what this runs before)
      GraphWeaver::Internal::Util.generated_dirs.each do |path|
        loader.ignore(GraphWeaver::Internal::Util.resolve(path))
      end
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
  initializer "graph_weaver.watch", after: :load_config_initializers do |app|
    GraphWeaver::Railtie.watch!(app)
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
