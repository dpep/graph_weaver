# typed: ignore — stubs Rails/Rake constants sorbet can't resolve
require "rake"
require "tmpdir"


describe "GraphWeaver::Railtie" do
  # Loaded ONCE — reloading a file resets Ruby's per-file coverage counters,
  # so loading per example left only the last example's execution measured.
  # A minimal Rails::Railtie stand-in captures the registration blocks;
  # examples that need their own Rails singleton methods (`.autoloaders`,
  # `.logger`, ...) stub_const a fresh module for just their own duration.
  module Rails; end unless defined?(Rails)

  # activesupport isn't a dependency of this gem, but OrderedOptions is what
  # every railtie hands an app, so a stand-in of the same shape stands in.
  unless defined?(ActiveSupport::OrderedOptions)
    Object.const_set(:ActiveSupport, Module.new) unless defined?(ActiveSupport)
    ActiveSupport.const_set(:OrderedOptions, Class.new(Hash) do
      def method_missing(name, *args)
        name.end_with?("=") ? self[:"#{name[0..-2]}"] = args.first : self[name]
      end

      def respond_to_missing?(*) = true
    end)
  end

  RAILTIE_RAKE_TASKS = []
  RAILTIE_INITIALIZERS = {}
  RAILTIE_INITIALIZER_OPTIONS = {}
  RAILTIE_CONFIG = ActiveSupport::OrderedOptions.new
  railtie_base = Class.new do
    define_singleton_method(:config) { RAILTIE_CONFIG }
    define_singleton_method(:rake_tasks) { |&block| RAILTIE_RAKE_TASKS << block }
    define_singleton_method(:initializer) do |name, **options, &block|
      RAILTIE_INITIALIZERS[name] = block
      RAILTIE_INITIALIZER_OPTIONS[name] = options
    end
  end
  Rails.const_set(:Railtie, railtie_base)
  load File.expand_path("../lib/graph_weaver/railtie.rb", __dir__)

  # Shared with every other spec file that exercises these tasks (see
  # rake_tasks_spec's header comment on TASKS for why this must be a single
  # process-wide load rather than one per file).
  unless defined?(TASKS)
    TASKS = Rake::Application.new
    begin
      previous, Rake.application = Rake.application, TASKS
      require "graph_weaver/tasks"
    ensure
      Rake.application = previous
    end
  end

  # calling the captured block does `require "graph_weaver/tasks"` — already
  # required (once, above) by the time this runs, so it's a no-op here and
  # the registration this proves happened is the one already in TASKS
  it "registers the rake tasks with Rails when present" do
    original = Rake.application
    Rake.application = TASKS

    expect(RAILTIE_RAKE_TASKS.size).to eq 1
    RAILTIE_RAKE_TASKS.first.call
    expect(Rake::Task.task_defined?("graph_weaver:generate")).to be true
    expect(Rake::Task.task_defined?("graph_weaver:schema:diff")).to be true
  ensure
    Rake.application = original
  end

  # Rails defines :environment AFTER every railtie's rake_tasks block, so the
  # tasks can only ask for it when they run — asking at load time left every
  # Rails app generating without its initializer's registrations.
  it "boots the app before generating, however late Rails defines :environment" do
    original = Rake.application
    Rake.application = TASKS
    TASKS.tasks.each(&:reenable) # rake runs a task once per process otherwise

    expect(Rake::Task["graph_weaver:generate"].prerequisites).to eq %w[environment]

    booted = false
    Rake::Task.define_task(:environment) { booted = true }
    Rake::Task["graph_weaver:environment"].invoke

    expect(booted).to be true
  ensure
    Rake.application = original
  end

  # Rails leaves config.rake_eager_load false in every environment, and
  # subgraph detection only sees LOADED schema classes — so a stock app got
  # "checked 0 of 4 subgraphs" and exit 0 from a task sold as a CI gate.
  it "eager-loads the app before every federation task" do
    original = Rake.application
    Rake.application = TASKS
    TASKS.tasks.each(&:reenable)

    %w[diff subgraphs coverage].each do |name|
      expect(Rake::Task["graph_weaver:federation:#{name}"].prerequisites).to eq(%w[loaded]), name
    end

    eager = false
    application = Object.new
    application.define_singleton_method(:eager_load!) { eager = true }
    rails = Module.new
    rails.define_singleton_method(:application) { application }
    stub_const("Rails", rails)
    Rake::Task["graph_weaver:federation:loaded"].invoke

    expect(eager).to be true
  ensure
    Rake.application = original
  end

  # generated/person_query.rb defines ::PersonQuery, not the
  # Generated::PersonQuery Zeitwerk infers from the path — and the default
  # the generated directory is inside an autoload root, so eager loading (production)
  # raised until the loader was told to skip it.
  it "hides the generated directory from Zeitwerk, before it is set up" do
    expect(RAILTIE_INITIALIZER_OPTIONS["graph_weaver.ignore_generated"]).to eq(before: :setup_main_autoloader)

    ignored = []
    loader = Object.new
    loader.define_singleton_method(:ignore) { |path| ignored << path }
    stub_const("Rails", Module.new)
    Rails.define_singleton_method(:autoloaders) { [loader] }
    Rails.define_singleton_method(:root) { Pathname.new("/app") }

    RAILTIE_INITIALIZERS["graph_weaver.ignore_generated"].call

    expect(ignored).to eq GraphWeaver.generated_paths.map { |path| "/app/#{path}" }
  end

  # The initializer only registers; the to_prepare block it hands back is what
  # loads. Returns the registered blocks.
  def register_generated_load
    prepared = []
    config = Object.new
    config.define_singleton_method(:to_prepare) { |&block| prepared << block }
    app = Object.new
    app.define_singleton_method(:config) { config }

    RAILTIE_INITIALIZERS["graph_weaver.load_generated"].call(app)
    prepared
  end

  it "loads generated modules at boot when the directory exists" do
    expect(RAILTIE_INITIALIZERS.keys).to eq %w[
      graph_weaver.ignore_generated graph_weaver.logger
      graph_weaver.filter_parameters graph_weaver.watch graph_weaver.load_generated
    ]

    Dir.mktmpdir do |dir|
      GraphWeaver.generated_paths = dir
      File.write(File.join(dir, "boot_probe_query.rb"), "module RailtieBootProbe; end")

      register_generated_load.each(&:call)

      expect(defined?(RailtieBootProbe)).to be_truthy
    ensure
      GraphWeaver.generated_paths = nil
      Object.send(:remove_const, :RailtieBootProbe) if Object.const_defined?(:RailtieBootProbe)
    end
  end

  # A generated file includes the type helper it was generated with, and
  # Zeitwerk's setup and the app's own to_prepare registrations both happen
  # after config/initializers — so loading from the initializer body raised
  # NameError at every boot. `after:` a finisher initializer isn't the fix
  # either: tsort hoists whichever one is named ahead of the app's own
  # config/initializers.
  it "loads generated modules from a to_prepare block, not from the initializer" do
    expect(RAILTIE_INITIALIZER_OPTIONS["graph_weaver.load_generated"]).to eq(after: :load_config_initializers)

    Dir.mktmpdir do |dir|
      GraphWeaver.generated_paths = dir
      File.write(File.join(dir, "deferred_query.rb"), "module RailtieDeferProbe; end")

      prepared = register_generated_load
      expect(defined?(RailtieDeferProbe)).to be_nil

      prepared.each(&:call)
      expect(defined?(RailtieDeferProbe)).to be_truthy
    ensure
      GraphWeaver.generated_paths = nil
      Object.send(:remove_const, :RailtieDeferProbe) if Object.const_defined?(:RailtieDeferProbe)
    end
  end

  # the rake tasks write these files, so requiring them first would let a
  # stale one block its own repair
  it "skips loading generated modules when a graph_weaver task is booting" do
    Dir.mktmpdir do |dir|
      GraphWeaver.generated_paths = dir
      File.write(File.join(dir, "skipped_query.rb"), "module RailtieSkipProbe; end")
      GraphWeaver.skip_generated_load = true

      register_generated_load.each(&:call)

      expect(defined?(RailtieSkipProbe)).to be_nil
    ensure
      GraphWeaver.skip_generated_load = false
      GraphWeaver.generated_paths = nil
    end
  end

  it "boots quietly when there is nothing generated" do
    GraphWeaver.generated_paths = "no/such/dir"
    expect { register_generated_load.each(&:call) }.not_to raise_error
  ensure
    GraphWeaver.generated_paths = nil
  end

  # a Rails app says what is sensitive once, in filter_parameter_logging.rb
  describe "filter_parameters" do
    # activesupport isn't a dependency of this gem, so ParameterFilter — which
    # exists wherever a railtie actually runs — stands in. What's under test is
    # the wiring: the app's list reaches GraphWeaver as a filter object.
    before do
      stub_const("ActiveSupport", Module.new)
      ActiveSupport.const_set(:ParameterFilter, Class.new do
        def initialize(filters) = @filters = filters.map { |f| f.to_s.downcase }
        def filter(hash)
          hash.to_h { |k, v| [k, @filters.any? { |f| k.to_s.downcase.include?(f) } ? "[FILTERED]" : v] }
        end
      end)
    end

    def boot(filters)
      app = Object.new
      app.define_singleton_method(:config) do
        Struct.new(:filter_parameters).new(filters)
      end
      RAILTIE_INITIALIZERS["graph_weaver.filter_parameters"].call(app)
    end

    after { GraphWeaver.filter_parameters = GraphWeaver::DEFAULT_FILTER_PARAMETERS }

    it "adopts the app's list" do
      boot([:passw, :ssn])

      expect(GraphWeaver.filter_variables("passwordConfirmation" => "x", "name" => "d"))
        .to eq("passwordConfirmation" => "[FILTERED]", "name" => "d")
    end

    it "leaves a list the app set on GraphWeaver itself alone" do
      GraphWeaver.filter_parameters = [:only_this]
      boot([:passw])

      expect(GraphWeaver.filter_parameters).to eq [:only_this]
    end
  end

  # A .graphql edit should reach the next request, so the query directories
  # join Rails' own reloaders and the to_prepare block regenerates first.
  describe "watch mode" do
    # what watch! asks of app.config.file_watcher, plus a switch for "a file
    # changed" — the real one polls mtimes
    class WatcherSpy
      attr_reader :files, :dirs
      attr_writer :updated

      def initialize(files, dirs, &block)
        @files, @dirs, @block = files, dirs, block
      end

      def execute_if_updated
        return false unless @updated

        @updated = false
        @block.call
        true
      end
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        GraphWeaver.queries_paths = File.join(dir, "queries")
        GraphWeaver.generated_paths = File.join(dir, "generated")
        GraphWeaver.fragments_paths = File.join(dir, "fragments")
        # its own namespace, so reloading can't remove a constant another
        # spec file's fixtures defined
        GraphWeaver.types_module = "WatchTypes"
        GraphWeaver.schema_path = File.join(dir, "schema.graphql")
        File.write(GraphWeaver.schema_path, Demo::Schema.to_definition)
        FileUtils.mkdir_p(GraphWeaver.queries_paths.first)
        example.run
      ensure
        %i[queries_paths generated_paths fragments_paths types_module schema_path]
          .each { |setting| GraphWeaver.public_send(:"#{setting}=", nil) }
        GraphWeaver::Railtie.watcher = nil
        Object.send(:remove_const, :WatchProbeQuery) if Object.const_defined?(:WatchProbeQuery)
      end
    end

    Env = Struct.new(:name) { def development? = name == "development" }

    before do
      @env = Env.new("development")
      root, env = Pathname.new(@dir), -> { @env }
      rails = Module.new
      rails.define_singleton_method(:root) { root }
      rails.define_singleton_method(:env) { env.call }
      stub_const("Rails", rails)
    end

    # the pieces watch! reads off a Rails app
    def app(watch: nil, reloading: true)
      config = ActiveSupport::OrderedOptions.new
      config.graph_weaver = ActiveSupport::OrderedOptions.new
      config.graph_weaver.watch = watch
      config.file_watcher = WatcherSpy
      config.define_singleton_method(:reloading_enabled?) { reloading }

      Struct.new(:config, :reloaders).new(config, [])
    end

    def write_query(selection)
      File.write(File.join(@dir, "queries/watch_probe.graphql"), "query { person(id: 1) { #{selection} } }\n")
    end

    it "watches the query directories and the schema dump" do
      host = app
      watcher = GraphWeaver::Railtie.watch!(host)

      expect(watcher.dirs).to eq(
        File.join(@dir, "queries") => %w[graphql gql],
        File.join(@dir, "fragments") => %w[graphql gql],
      )
      expect(watcher.files).to eq [File.join(@dir, "schema.graphql")]
      # without this a .graphql edit on its own never re-runs to_prepare
      expect(host.reloaders).to eq [watcher]
    end

    it "watches in development only, unless the app says otherwise" do
      expect(GraphWeaver::Railtie.watch!(app)).to be_a WatcherSpy

      @env = Env.new("production")
      expect(GraphWeaver::Railtie.watch!(app)).to be_nil
      expect(GraphWeaver::Railtie.watch!(app(watch: true))).to be_a WatcherSpy
    end

    # a file-writing side effect on request needs an off switch, and promising
    # one where nothing re-runs to_prepare would be a promise it can't keep
    it "doesn't watch when told not to, or when nothing would reload" do
      expect(GraphWeaver::Railtie.watch!(app(watch: false))).to be_nil
      expect(GraphWeaver::Railtie.watch!(app(reloading: false))).to be_nil
    end

    it "replaces the loaded module when its query changes" do
      write_query("name")
      GraphWeaver::Railtie.regenerate!
      expect(WatchProbeQuery::Result::Person.props.keys).to eq %i[name]

      write_query("name birthday")
      GraphWeaver::Railtie.regenerate!

      # require would have no-op'd on the rewritten file
      expect(WatchProbeQuery::Result::Person.props.keys).to eq %i[name birthday]
    end

    # a query saved mid-edit shouldn't take the dev server down
    it "logs and keeps the loaded module when a query no longer compiles" do
      write_query("name")
      GraphWeaver::Railtie.regenerate!

      logged = []
      GraphWeaver.logger = Logger.new(File::NULL).tap do |logger|
        logger.define_singleton_method(:error) { |_progname, &block| logged << block.call }
      end
      write_query("nam")
      expect { GraphWeaver::Railtie.regenerate! }.not_to raise_error

      expect(WatchProbeQuery::Result::Person.props.keys).to eq %i[name]
      expect(logged.join).to include("keeping the modules already loaded", "watch_probe.graphql", "'nam'")
    ensure
      GraphWeaver.logger = nil
    end

    # regenerate first, then load — and only load again when nothing did
    it "asks the watcher before loading, and skips the load when it regenerated" do
      write_query("name")
      host = app
      GraphWeaver::Railtie.watch!(host)
      prepared = []
      config = Object.new
      config.define_singleton_method(:to_prepare) { |&block| prepared << block }
      rails_app = Object.new
      rails_app.define_singleton_method(:config) { config }
      RAILTIE_INITIALIZERS["graph_weaver.load_generated"].call(rails_app)

      # nothing changed: no generation, just the load
      prepared.each(&:call)
      expect(Dir[File.join(@dir, "generated/*.rb")]).to be_empty

      GraphWeaver::Railtie.watcher.updated = true
      prepared.each(&:call)
      expect(WatchProbeQuery::Result::Person.props.keys).to eq %i[name]
    end
  end

  it "wires Rails.logger unless the app already chose one" do
    stub_const("Rails", Module.new)
    rails_logger = Logger.new(File::NULL)
    Rails.define_singleton_method(:logger) { rails_logger }

    RAILTIE_INITIALIZERS["graph_weaver.logger"].call
    expect(GraphWeaver.logger).to be rails_logger

    mine = Logger.new(File::NULL)
    GraphWeaver.logger = mine
    RAILTIE_INITIALIZERS["graph_weaver.logger"].call
    expect(GraphWeaver.logger).to be mine
  ensure
    GraphWeaver.logger = nil
  end
end
