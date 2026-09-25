# typed: ignore — Rails::Railtie DSL
# frozen_string_literal: true

# Rails wiring, so the conventional layout needs no ceremony:
#
# - rake tasks: Rails.application.load_tasks collects every Railtie's
#   rake_tasks block, so graph_weaver:* tasks appear with no Rakefile
#   edit. (Outside Rails there is no task-discovery hook — add
#   `require "graph_weaver/tasks"` to your Rakefile.)
# - generated modules: required once every registration has run — both the
#   initializer kind and the to_prepare kind, since a generated file
#   `include`s the type helper it was generated with and that constant must
#   resolve. load_generated! stays idempotent, so calling it yourself too is
#   harmless.
# - Zeitwerk: the generated directory is hidden from it, since the
#   default one lives under app/ and its files define top-level
#   constants.
# - watch mode: in development, editing a .graphql regenerates before the
#   next request, the way editing a route or a locale takes effect.
#
# All of that is hung off Rails' lifecycle HOOKS — before_initialize,
# after_initialize, the reloader — rather than off initializers with
# `after:`/`before:` edges naming other railties' initializers. Rails
# topologically sorts every railtie's initializers together, so such an edge
# constrains the whole app's boot order and tsort is free to satisfy it by
# moving initializers that aren't ours: a real app failed to boot with
# graph_weaver in the Gemfile and every one of these bodies neutered. A hook
# has a fixed place in boot and adds no edge. See DECISIONS.md.
class GraphWeaver::Railtie < Rails::Railtie
  # config.graph_weaver.watch — false to never regenerate during a request.
  # Default: development only. Every other setting is a top-level one, and an
  # OrderedOptions would take `config.graph_weaver.queries_paths = ...` without
  # a word and do nothing with it, so this refuses what it doesn't read.
  class Options < ActiveSupport::OrderedOptions
    KEYS = %i[watch].freeze

    def method_missing(name, *args)
      key = setting(name)
      return super if KEYS.include?(key)

      raise ArgumentError, refusal(key)
    end

    # the other door: `config.graph_weaver[:queries_paths] = ...` reaches
    # Hash#[]= without passing method_missing, and was the exact silent no-op
    # the refusal exists to prevent. store is Hash's own synonym for it, so it
    # stays one.
    def []=(key, value)
      raise ArgumentError, refusal(key) unless KEYS.include?(key.to_sym)

      super
    end
    alias_method :store, :[]=

    def respond_to_missing?(name, _private = false)
      KEYS.include?(setting(name))
    end

    private

    # the setting a reader, writer or predicate is about
    def setting(name)
      name.to_s.delete_suffix("=").delete_suffix("?").delete_suffix("!").to_sym
    end

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
    # The file watcher, so the prepare hook below can ask it whether a query
    # changed. nil when not watching.
    attr_accessor :watcher

    # What has been hidden from Zeitwerk, resolved. Zeitwerk only reads its
    # ignore list at setup, so anything that arrives later isn't hidden by
    # calling ignore again — check_generated_ignored! refuses instead.
    attr_accessor :ignored_dirs

    # The outputs left to Zeitwerk, resolved — the trees whose every module is
    # the constant Zeitwerk infers from its path, so hiding them would be
    # hiding code that already works. Decided beside the sweep, because it is
    # what the sweep must not hide.
    attr_accessor :autoloaded_dirs

    # Whether hiding an output right now would actually hide it: false until
    # the initializer below has swept (it picks up anything declared so far),
    # and false again from the moment Zeitwerk sets the main autoloader up.
    attr_accessor :hiding_outputs
  end

  rake_tasks do
    require "graph_weaver/tasks"
  end

  # ONE initializer, and it declares no `after:` — see the note on the class.
  # The `before:` that is left is inert: it only says "not after Zeitwerk's
  # setup", and this is emitted at its own place in the railties block anyway,
  # so nothing moves. It records the deadline.
  #
  # What it sweeps is what config/application.rb configured. A graph declared
  # in config/initializers is later than this and hides its own output as it is
  # declared (ignore_output!) — which is where that knowledge arrives, and so
  # needs no edge to wait for.
  initializer "graph_weaver.ignore_generated", before: :setup_main_autoloader do
    GraphWeaver::Railtie.hide_generated!
  end

  # ONE rule: a generated tree Zeitwerk would name correctly is left to
  # Zeitwerk; any other is hidden from it and required at boot.
  #
  # generated/person_query.rb defines ::PersonQuery, but Zeitwerk infers
  # Generated::PersonQuery from the path — and app/graphql/generated is inside
  # an autoload root by default, so eager loading raised "uninitialized
  # constant Generated::PersonQuery" in production while development (lazy) was
  # fine. prepare_generated! requires those instead. A graph whose `namespace:`
  # is the constant its output path spells has no such mismatch, and requiring
  # it at boot would define its whole parent chain before a query is ever used.
  def self.hide_generated!
    self.ignored_dirs = []
    self.autoloaded_dirs = []
    self.hiding_outputs = true
    # the aligned trees first: they are what the sweep must NOT hide, and
    # generated_paths' own globs cover a graph's output (app/graphql/*/generated
    # matches app/graphql/billing/generated)
    GraphWeaver.graphs.each { |graph| consider_output!(graph) }
    GraphWeaver::Internal::Util.generated_dirs.each { |path| ignore_output!(path) }

    # Zeitwerk reads its ignore list once, at setup, and nothing in Rails
    # announces that moment — Zeitwerk itself does. With no such signal, shut
    # the window here: an ignore registered after setup hides nothing, and
    # check_generated_ignored! has to be the one to say so.
    main = Rails.autoloaders.main if Rails.autoloaders.respond_to?(:main)
    if main.respond_to?(:on_setup)
      main.on_setup do
        GraphWeaver::Railtie.hiding_outputs = false
        GraphWeaver::Railtie.check_alignment!
      end
    else
      self.hiding_outputs = false
    end
  end

  # Which side of the rule one graph's output falls, and say so in a line at
  # debug: a user who set `namespace:` and expected laziness learns here why
  # they didn't get it. True when the tree is Zeitwerk's to load.
  def self.consider_output!(graph)
    dir = autoload_path(graph.output)
    return true if autoloaded_dirs.include?(dir)
    # already hidden by an earlier pass, and an ignore can't be taken back
    return false if ignored_dirs.include?(dir)

    reason = misalignment(graph, dir)
    subject, = describe_output(dir)
    if reason
      GraphWeaver::Internal::Log.log(:debug) do
        "#{subject} is hidden from Zeitwerk and required at boot — #{reason}"
      end
      # here rather than back in ignore_output!, so the decision is recorded
      # the moment it is made and the sweep doesn't reach it a second time
      hide!(dir)
      return false
    end

    autoloaded_dirs << dir
    # types.rb requires its own directory — one file per type, in the order the
    # runtime needs — so Zeitwerk never autoloads those files one at a time.
    # Only eager loading walks them, and it would want a constant name for each
    # that the generator's own inflection doesn't promise: HTTPHeaderInput
    # writes httpheader_input.rb, which Zeitwerk reads as HttpheaderInput.
    # Loading types.rb is what loads them, and types.rb is eager loaded.
    Rails.autoloaders.each { |loader| loader.do_not_eager_load(File.join(dir, "types")) }
    GraphWeaver::Internal::Log.log(:debug) do
      "#{subject} is left to Zeitwerk — every module it generates is the constant Zeitwerk reads " \
        "off the path, so it autoloads on first reference and reloads with the app"
    end
    true
  end

  # Why Zeitwerk would NOT name what this graph generates the way its files do
  # — nil when it would, which is the aligned case. The first disagreement is
  # the whole answer: one namespace settles every file, so the fix for one is
  # the fix for all of them.
  def self.misalignment(graph, dir)
    main = Rails.autoloaders.main if Rails.respond_to?(:autoloaders) && Rails.autoloaders.respond_to?(:main)
    # 2.6.2 is where cpath_expected_at arrives, and with it the only answer
    # that can confirm this one at setup — without it nothing is left to
    # Zeitwerk, which is what every app got before.
    unless main.respond_to?(:cpath_expected_at)
      return "no autoloader here answers cpath_expected_at (Zeitwerk 2.6.2 and up does)"
    end

    if ignored_by_app?(dir)
      return "it is already hidden from autoloading — a GraphWeaver.generated_paths pattern reaches " \
        "it, or the app ignored it itself"
    end

    namespace = expected_cpath(dir)
    return "it is not under an autoload path, so nothing but this would load it" unless namespace
    unless namespace == graph.namespace
      return "Zeitwerk reads that directory as #{namespace}, and this graph's constants are " \
        "#{graph.namespace || "top-level"} (namespace #{namespace.inspect} makes them agree)"
    end

    types = expected_cpath(File.join(dir, "types.rb"))
    return "types.rb defines #{graph.types_module}, Zeitwerk expects #{types}" unless types == graph.types_module

    first_mismatch(graph, dir)
  end

  # The first query module whose name isn't the one Zeitwerk reads off its
  # file. Only reached once the namespace agrees, so what is left is a file
  # name the app's inflector camelizes differently from the generator.
  def self.first_mismatch(graph, dir)
    GraphWeaver::Internal::Util.query_files(graph.queries).each do |query|
      name, filename = graph.generated_names(query, File.read(query))
      expected = expected_cpath(File.join(dir, filename))
      next if expected == name

      return "#{filename} defines #{name}, Zeitwerk expects #{expected}"
    end
    nil
  end

  # The constant Zeitwerk will expect at an absolute path, or nil when nothing
  # will autoload it.
  #
  # Zeitwerk answers this itself, with cpath_expected_at — but only once Rails
  # has pushed the main loader's roots, and Rails does that INSIDE
  # :setup_main_autoloader, whose start is the deadline for `ignore`. So the
  # roots here are the list Rails is about to push, and every constant name
  # comes from the loader's own inflector, which an app's `inflect`/`acronym`
  # is already on. check_alignment! re-asks Zeitwerk the moment it can answer.
  def self.expected_cpath(path)
    main = Rails.autoloaders.main
    roots = autoload_roots
    cnames = []
    dir = path
    if path.end_with?(".rb")
      cnames << main.inflector.camelize(File.basename(path, ".rb"), path)
      dir = File.dirname(path)
    end
    until roots.key?(dir)
      parent = File.dirname(dir)
      return if parent == dir || ignored_by_app?(dir)

      cnames << main.inflector.camelize(File.basename(dir), dir)
      dir = parent
    end
    return if ignored_by_app?(dir)

    [roots[dir], *cnames.reverse].compact.join("::")
  end

  # Every directory the main autoloader will have as a root, and the name of
  # the namespace each sits under (nil for Object): the paths Rails is about to
  # push, plus any the app pushed itself — which is the only way a root gets a
  # namespace, and the one thing Rails leaves alone when it pushes the rest.
  def self.autoload_roots
    roots = {}
    if defined?(ActiveSupport::Dependencies) && ActiveSupport::Dependencies.respond_to?(:autoload_paths)
      once = Rails.autoloaders.respond_to?(:once) ? Rails.autoloaders.once.dirs : []
      ActiveSupport::Dependencies.autoload_paths.each do |path|
        path = path.to_s
        # through autoload_path, so a root and an output under it are spelled
        # the same way — a symlinked checkout (Capistrano's current/) otherwise
        # has the root as Rails wrote it and the output as realpath saw it
        roots[autoload_path(path)] = nil unless once.include?(path)
      end
    end
    Rails.autoloaders.main.dirs(namespaces: true).each do |dir, namespace|
      roots[autoload_path(dir)] = (namespace == Object) ? nil : namespace.name
    end
    roots
  end

  # An app that hid the directory itself has a tree Zeitwerk will not load
  # however it is named — so it is one to require at boot, exactly as before.
  def self.ignored_by_app?(dir)
    asked = IGNORES.find { |name| Rails.autoloaders.main.respond_to?(name) }
    asked && Rails.autoloaders.main.public_send(asked, dir)
  end

  # The prediction above, against the one answer that is authoritative. A
  # `collapse` between the autoload root and the output, or a root pushed under
  # its own namespace after this railtie looked, changes the name — and neither
  # is readable before setup. Left unsaid, that surfaces as Zeitwerk's own
  # error on the first eager load in production.
  def self.check_alignment!
    main = Rails.autoloaders.main
    Array(autoloaded_dirs).each do |dir|
      # the top level only: types/ is excluded from eager loading, so what
      # Zeitwerk reads off those files never comes up
      Dir[File.join(dir, "*.rb")].sort.each do |file|
        expected = main.cpath_expected_at(file)
        # nil is "I don't see that file" — which is what Zeitwerk answers for a
        # path spelled through a symlink its own roots aren't, so it is not an
        # answer to compare against
        next if expected.nil? || expected == expected_cpath(file)

        subject, short = describe_output(dir)
        raise GraphWeaver::Error,
          "#{subject} was left to Zeitwerk because the constants it generates are the ones its path " \
          "spells — but Zeitwerk reads #{GraphWeaver::Internal::Util.relative(file)} as " \
          "#{expected.inspect}, not #{expected_cpath(file).inspect}. A `collapse`, or an autoload root " \
          "pushed under its own namespace, over #{short} changes that name: move the output out from " \
          "under it, or set namespace: to what Zeitwerk reads."
      end
    end
  end

  # Whether this generated directory is one Zeitwerk is loading — what
  # Internal::Util.required_dirs asks, so the boot-time require skips it.
  def self.left_to_zeitwerk?(path)
    Array(autoloaded_dirs).include?(autoload_path(path))
  end

  # Hide one output from Zeitwerk, the moment it is named — a graph declared in
  # config/initializers says where it writes long after the sweep above ran.
  # Waiting for it instead is what `after: :load_config_initializers` used to
  # buy, at the cost of the whole app's boot order.
  #
  # Outside the window this is a no-op on purpose: before it, the sweep will
  # pick the path up; after it, calling Zeitwerk's `ignore` would only teach
  # check_generated_ignored! a lie.
  def self.ignore_output!(path)
    return unless hiding_outputs

    # a graph saying where it writes is also the moment the rule can be applied
    # to it: config/initializers is later than the sweep above, so this is
    # where an app's second graph is first heard of
    graph = GraphWeaver.graphs.find { |candidate| autoload_path(candidate.output) == autoload_path(path) }
    return if graph && consider_output!(graph)

    hidden_for(path).each { |dir| hide!(dir) }
  end

  # Hide one resolved directory, once.
  def self.hide!(dir)
    return if ignored_dirs.include?(dir)

    check_autoload_once!([dir])
    ignored_dirs << dir
    Rails.autoloaders.each { |loader| loader.ignore(dir) }
  end

  # What hiding one generated path means. Normally the pattern itself —
  # generated_paths may be globs, and Zeitwerk expands its own at setup, so a
  # directory a pattern will match is hidden however late it appears; that is
  # what the window stays open until. The exception is a pattern that also
  # covers a tree Zeitwerk is keeping (app/graphql/*/generated matches a
  # namespaced graph's own output), since a glob can't say "all but this one":
  # then it is expanded here and the aligned directories left out.
  def self.hidden_for(path)
    dir = autoload_path(path)
    kept = Array(autoloaded_dirs)
    return [dir] if kept.empty?

    expanded = Dir[GraphWeaver::Internal::Util.resolve(path)]
      .select { |found| File.directory?(found) }.map { |found| autoload_path(found) }
    return [dir] if (expanded & kept).empty?

    expanded - kept
  end

  # The `once` autoloader is set up in bootstrap, before any of this — and
  # Zeitwerk reads its ignore list only at setup, so `loader.ignore` hides
  # nothing from it however the output is spelled. The generic advice ("name it
  # in GraphWeaver.generated_paths from config/initializers") produced
  # byte-identical output for this one, so it gets its own refusal, naming the
  # place that is still early enough.
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
    # the default graph has no name to say, and "graph :'s output" is worse
    # than the path on its own
    ["#{graph&.name ? "graph #{graph.name.inspect}'s output" : "generated path"} #{short}", short]
  end

  # A graph declared from to_prepare — what the docs say to do when its block
  # names an autoloaded constant — is declared after Zeitwerk is set up, and
  # Zeitwerk reads its ignore list only then. So an output that arrives that
  # late can't be hidden: its files load as ordinary autoloads and raise on the
  # constant they don't define, in a Zeitwerk error that blames a dropped
  # extend_type. Refuse, and name what actually happened — unless the tree is
  # one Zeitwerk names correctly, which needed no hiding at any point and is as
  # true declared late as declared early.
  def self.check_generated_ignored!
    # no autoloaders, no Zeitwerk, nothing to refuse
    return unless Rails.respond_to?(:autoloaders)

    late = GraphWeaver::Internal::Util.generated_dirs.map { autoload_path(_1) } -
      Array(ignored_dirs) - Array(autoloaded_dirs)
    return if late.empty?

    late.each do |dir|
      next unless Rails.autoloaders.any? { |loader| autoloaded?(loader, dir) }
      next if aligned_late?(dir)

      subject, short = describe_output(dir)
      raise GraphWeaver::Error,
        "#{subject} was declared after Rails " \
        "set Zeitwerk up on it, so it can't be hidden from autoloading and its modules can't load. Declare " \
        "the graph in config/initializers (schema -> { MyApp::Schema } resolves an autoloaded class when " \
        "generation asks), or name #{short.inspect} in GraphWeaver.generated_paths there."
    end
  end

  # A graph declared after setup, whose tree Zeitwerk already names correctly:
  # nothing had to be hidden, so nothing was missed. Recorded on the way past,
  # so the boot-time require skips it too.
  def self.aligned_late?(dir)
    graph = GraphWeaver.graphs.find { autoload_path(_1.output) == dir }
    return false unless graph && misalignment(graph, dir).nil?

    self.autoloaded_dirs = Array(autoloaded_dirs) | [dir]
    true
  end

  # The two auto-wires an app gets for free, and the only two it can turn off
  # by assigning nil.
  #
  # before_initialize runs in Rails' own :bootstrap_hook — after
  # :initialize_logger and before the first railtie initializer, so the default
  # is in place for anything that boots, and config/initializers still runs
  # later and still wins. That timing used to be a `before:
  # :load_config_initializers` edge, and getting it wrong shipped: declared
  # without one, these ran AFTER config/initializers, so the `if nil?` fallback
  # overwrote an app that had just said nil — the documented PII opt-out did
  # nothing, silently, while queries and variables kept reaching a debug
  # Rails.logger.
  config.before_initialize { GraphWeaver::Railtie.default_logger! }

  # Rails.logger, unless the app already chose one (set GraphWeaver.logger =
  # nil in an initializer to silence)
  def self.default_logger!
    GraphWeaver.logger = Rails.logger if GraphWeaver.logger.nil?
  end

  # An APM sees every GraphQL call without the app configuring anything:
  # the ActiveSupport::Notifications adapter from docs/logging.md, plus the
  # LogSubscriber that turns its event into one line. Measured at ~4.5µs per
  # execution all told (0.13µs of that ActiveSupport::Notifications itself
  # with nothing subscribed; the rest is its Event machinery) — 0.05% of a
  # 10ms round trip, so there is nothing to weigh.
  #
  # An instrumenter the app set is never replaced: assigned before this (in
  # config/application.rb) the nil check leaves it, and config/initializers runs
  # later, so one assigned there wins on its own — including
  # `GraphWeaver.instrumenter = nil` to opt out.
  config.before_initialize { GraphWeaver::Railtie.default_instrumenter! }

  def self.default_instrumenter!
    return unless defined?(ActiveSupport::Notifications)

    if GraphWeaver.instrumenter.nil?
      GraphWeaver.instrumenter = lambda do |event, payload, &block|
        ActiveSupport::Notifications.instrument(event, payload, &block)
      end
    end

    # ActiveSupport::LogSubscriber is one of ActiveSupport's own eager
    # autoloads, so naming it is enough — no require of theirs needed
    require "graph_weaver/log_subscriber"
    # idempotent — Subscriber.add_event_subscriber skips a pattern it already has
    GraphWeaver::LogSubscriber.attach_to :graph_weaver
  end

  # The app already declared what is sensitive, so variables logged at debug
  # honour the same list as its request logs — including the Procs and dotted
  # paths only ParameterFilter understands. after_initialize, since
  # filter_parameter_logging.rb is where an app adds to it.
  config.after_initialize { |app| GraphWeaver::Railtie.adopt_filter_parameters!(app) }

  def self.adopt_filter_parameters!(app)
    filters = app.config.filter_parameters
    return if filters.empty? || GraphWeaver.filter_parameters != GraphWeaver::DEFAULT_FILTER_PARAMETERS

    GraphWeaver.filter_parameters = ActiveSupport::ParameterFilter.new(filters)
  end

  # Watch mode. A .graphql edit should reach the next request the way a route
  # or a locale change does, so the query directories and the schema dump
  # become one of Rails' own reloaders: a change there alone triggers a reload
  # cycle, and the prepare hook below regenerates before it loads. Off with
  #
  #      config.graph_weaver.watch = false
  #
  # after_initialize, because every graph has to be declared before the watcher
  # is built: a graph declared from a to_prepare block (what the docs say to do
  # when its block names an autoloaded constant) isn't declared until the
  # prepare callbacks have run, and a watcher built before it watched the
  # default queries_paths — an edit to that graph's .graphql silently never
  # regenerated. app.reloaders is read per request, so joining it this late
  # still counts.
  config.after_initialize { |app| GraphWeaver::Railtie.watch!(app) }

  # Registers the watcher, and says so: this is the one thing GraphWeaver does
  # that writes a checked-in file outside a rake task. Returns it, or nil when
  # nothing is being watched.
  def self.watch!(app)
    # exactly one watcher per app, however many times this is called — a second
    # one is a second reloader polling the same files
    app.reloaders.delete(watcher) if watcher

    watch = app.config.graph_weaver.watch
    watch = Rails.env.development? if watch.nil?
    # with reloading off nothing re-runs the prepare hook, so a watcher could
    # only promise something it can't do
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
  # can't load until that constant resolves — and both Zeitwerk's setup and the
  # app's own to_prepare blocks (where extend_type/register_enum are told to
  # register, Codegen::AUTOLOAD_HINT) happen after config/initializers.
  # after_initialize is past all of them, and past the watcher above.
  #
  # Except where the app eager loads: an eager-loaded class may name a
  # generated constant in its class body, and Zeitwerk can't resolve one (the
  # directory is ignored, by design), so the modules have to be in place before
  # Rails' :eager_load! rather than after it. before_eager_load is that point,
  # and Rails only runs it when config.eager_load is on — which is exactly when
  # after_initialize must not do the work a second time.
  config.before_eager_load { GraphWeaver::Railtie.prepare_generated! }

  config.after_initialize do |app|
    GraphWeaver::Railtie.prepare_generated! unless app.config.eager_load
    # and again on every dev reload, which picks up a module generated since
    # boot and re-requires one whose namespace Zeitwerk just unloaded. On the
    # reloader itself, not config.to_prepare: the :add_to_prepare_blocks
    # finisher has already drained that list by now.
    ActiveSupport::Reloader.to_prepare { GraphWeaver::Railtie.prepare_generated! }
  end

  def self.prepare_generated!
    # The graph_weaver tasks write these files and need none of them loaded.
    # Loading them would let a stale one block its own repair: a dropped
    # extend_type leaves a dangling include, and generate depends on
    # :environment, so boot failed before the task that would regenerate it.
    return if GraphWeaver.skip_generated_load

    # every graph is declared by now, and this is the last point before one of
    # them loads
    check_generated_ignored!

    # Regenerate first, then load — and here rather than in the watcher's own
    # to_run, so an extend_type or register_enum the app registers in its own
    # to_prepare is already in place. A run that regenerated has already
    # reloaded what it wrote.
    return if watcher&.execute_if_updated

    # entries may be globs, so Dir[] rather than Dir.exist?. required_dirs, not
    # generated_dirs: a tree left to Zeitwerk loads on first reference, and not
    # requiring its whole parent chain here is the point of leaving it there.
    generated = GraphWeaver::Internal::Util.required_dirs.any? do |dir|
      Dir[GraphWeaver::Internal::Util.resolve(dir)].any?
    end
    return unless generated

    # `require` no-ops on a file it has already read — which is what we want,
    # except when the constant that file defined is gone. A graph's
    # `namespace:` is normally a module Zeitwerk owns (app/graphql/accounts/
    # implies Accounts), and unloading it on a dev reload takes the generated
    # module nested inside it with it; require then restores nothing and every
    # request 500s on "uninitialized constant Accounts::PersonQuery" until a
    # .graphql edit happens to trigger the watcher. An un-namespaced module
    # defines a top-level constant Zeitwerk never manages, so it survives.
    if GraphWeaver.graphs.any? { |graph| graph.namespace && !left_to_zeitwerk?(graph.output) }
      GraphWeaver.reload_generated!
    else
      GraphWeaver.load_generated!
    end
  end
end
