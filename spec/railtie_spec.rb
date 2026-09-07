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

  RAILTIE_RAKE_TASKS = []
  RAILTIE_INITIALIZERS = {}
  RAILTIE_INITIALIZER_OPTIONS = {}
  railtie_base = Class.new do
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

  it "loads generated modules at boot when the directory exists" do
    expect(RAILTIE_INITIALIZERS.keys).to eq %w[graph_weaver.ignore_generated graph_weaver.logger graph_weaver.load_generated]

    Dir.mktmpdir do |dir|
      GraphWeaver.generated_paths = dir
      File.write(File.join(dir, "boot_probe_query.rb"), "module RailtieBootProbe; end")

      RAILTIE_INITIALIZERS["graph_weaver.load_generated"].call

      expect(defined?(RailtieBootProbe)).to be_truthy
    ensure
      GraphWeaver.generated_paths = nil
      Object.send(:remove_const, :RailtieBootProbe) if Object.const_defined?(:RailtieBootProbe)
    end
  end

  # the rake tasks write these files, so requiring them first would let a
  # stale one block its own repair
  it "skips loading generated modules when a graph_weaver task is booting" do
    Dir.mktmpdir do |dir|
      GraphWeaver.generated_paths = dir
      File.write(File.join(dir, "skipped_query.rb"), "module RailtieSkipProbe; end")
      GraphWeaver.skip_generated_load = true

      RAILTIE_INITIALIZERS["graph_weaver.load_generated"].call

      expect(defined?(RailtieSkipProbe)).to be_nil
    ensure
      GraphWeaver.skip_generated_load = false
      GraphWeaver.generated_paths = nil
    end
  end

  it "boots quietly when there is nothing generated" do
    GraphWeaver.generated_paths = "no/such/dir"
    expect { RAILTIE_INITIALIZERS["graph_weaver.load_generated"].call }.not_to raise_error
  ensure
    GraphWeaver.generated_paths = nil
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
