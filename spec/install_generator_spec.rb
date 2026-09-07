# typed: ignore — stubs the Rails::Generators constants sorbet can't resolve
require "yaml"


# `rails` isn't a dependency, so — as in railtie_spec — the Rails DSL the
# generator sits on is stood in for, and the real generator runs against
# it. Thor invokes a generator's public instance methods in definition
# order, which is what run_generator reproduces.
describe "GraphWeaver::Generators::InstallGenerator" do
  # Loaded ONCE — reloading a file resets Ruby's per-file coverage counters,
  # so loading per example left only the last example's execution measured
  # (see railtie_spec/rake_tasks_spec). The base class below doesn't depend
  # on anything test-local, so nothing here needs a fresh copy per example.
  #
  # records what the generator asks Thor to do, and nothing else: the
  # stub has no way to write to disk, so a write that bypassed create_file
  # would fail here rather than silently overwrite a real file
  INSTALL_GENERATOR_BASE = Class.new do
    def self.desc(*); end

    def self.class_options = @class_options ||= {}

    def self.class_option(name, **opts) = class_options[name] = opts

    # Thor exposes a declared argument as a reader on the instance
    def self.argument(name, **) = attr_reader(name)

    # Thor::Group collects its commands in method_added, in definition
    # order — reflection order isn't guaranteed, so mirror that rather
    # than reading it back off the class
    def self.commands = @commands ||= []

    def self.method_added(name)
      super
      commands << name if name != :initialize && public_method_defined?(name)
    end

    attr_reader :options, :actions

    def initialize(source, options = {})
      defaults = self.class.class_options.to_h { |name, opts| [name, opts[:default]] }
      @source = source
      @options = defaults.merge(options)
      @actions = []
    end

    def create_file(*args) = @actions << [:create_file, *args]

    def say_status(*args) = @actions << [:say_status, *args]

    def say(*args) = @actions << [:say, *args]
  end

  module Rails; end unless defined?(Rails)
  Rails.const_set(:Generators, Module.new) unless Rails.const_defined?(:Generators, false)
  Rails::Generators.const_set(:Base, INSTALL_GENERATOR_BASE)

  load File.expand_path("../lib/generators/graph_weaver/install_generator.rb", __dir__)
  INSTALL_GENERATOR_CLASS = GraphWeaver::Generators::InstallGenerator

  def run_generator(source = URL, **options)
    generator = INSTALL_GENERATOR_CLASS.new(source, options)
    INSTALL_GENERATOR_CLASS.commands.each { |name| generator.public_send(name) }
    generator.actions
  end

  def created(actions)
    actions.filter_map { |kind, path, content| [path, content] if kind == :create_file }.to_h
  end

  def initializer(actions) = created(actions)["config/initializers/graph_weaver.rb"]

  URL = "https://api.example.com/graphql"

  before do
    # the generator refuses bad input with Thor::Error; thor is not a dependency here
    stub_const("Thor::Error", Class.new(StandardError))
    allow(GraphWeaver::SchemaLoader).to receive(:refresh!).and_return(["app/graphql/schema.json", URL])
    allow(GraphWeaver::SchemaLoader).to receive(:introspect)
  end

  it "scaffolds the conventional layout" do
    files = created(run_generator)

    expect(files.keys).to eq [
      "config/initializers/graph_weaver.rb",
      "app/graphql/queries/.keep",
      "app/graphql/generated/.keep",
      "graphql.config.yml",
    ]
  end

  it "writes an editor config the plugins can read, fragments included" do
    config = YAML.safe_load(created(run_generator)["graphql.config.yml"])

    expect(config["schema"]).to eq GraphWeaver.schema_path
    # fragments too, or an editor reports `Unknown fragment`
    expect(config["documents"]).to eq [
      "app/graphql/queries/**/*.{graphql,gql}",
      "app/graphql/fragments/**/*.{graphql,gql}",
    ]
  end

  it "leaves conflicts to Thor rather than forcing them" do
    # create_file prompts with a diff on a re-run — unless it's handed
    # force:, which would silently clobber an edited initializer
    writes = run_generator.select { |kind,| kind == :create_file }

    expect(writes.map(&:size)).to all(eq(3)) # [:create_file, path, content] — no options
  end

  context "a url" do
    it "wires the initializer to the url and auth var it was given" do
      expect(initializer(run_generator(auth: "GITHUB_TOKEN"))).to include <<~RUBY.chomp
        GraphWeaver.client = GraphWeaver.new(
          "#{URL}",
          auth: ENV["GITHUB_TOKEN"],
      RUBY
    end

    it "points at GRAPHWEAVER_AUTH by default" do
      expect(initializer(run_generator)).to include 'ENV["GRAPHWEAVER_AUTH"]'
      expect(initializer(run_generator)).to include "register_scalar", "extend_type" # pointers, not a wall of options
    end

    it "bootstraps the schema dump through the refresh path" do
      ENV["GITHUB_TOKEN"] = "s3cret"
      actions = run_generator(auth: "GITHUB_TOKEN")

      # the var NAME, not the resolved token — it lands in the dump's
      # provenance so schema:refresh/:diff read the same one the
      # initializer does, rather than defaulting to GRAPHWEAVER_AUTH
      expect(GraphWeaver::SchemaLoader).to have_received(:refresh!).with(url: URL, auth_env: "GITHUB_TOKEN")
      expect(actions).to include([:say_status, :introspect, "app/graphql/schema.json from #{URL}"])
    ensure
      ENV.delete("GITHUB_TOKEN")
    end

    it "skips the fetch on --no-schema" do
      run_generator(schema: false)

      expect(GraphWeaver::SchemaLoader).not_to have_received(:refresh!)
    end

    it "keeps the scaffolded files when introspection fails" do
      allow(GraphWeaver::SchemaLoader).to receive(:refresh!).and_raise(GraphWeaver::Error, "401 Unauthorized")
      actions = run_generator

      expect(created(actions).keys).to include "config/initializers/graph_weaver.rb"
      expect(actions.flatten.join).to include "401 Unauthorized", "rake graph_weaver:schema:refresh"
    end
  end

  context "a schema class" do
    before { stub_const("MyApp::Schema", Class.new { def self.execute(*) = {} }) }

    # the class is autoloaded and replaced on every dev reload, so the
    # initializer resolves it per reload rather than capturing one copy
    it "resolves the class at boot, not at install" do
      expect(initializer(run_generator("MyApp::Schema"))).to include <<~RUBY.chomp
        Rails.application.config.to_prepare do
      RUBY
      expect(initializer(run_generator("MyApp::Schema"))).to include "GraphWeaver.new(MyApp::Schema)"
    end

    it "dumps the schema the class already is" do
      actions = run_generator("MyApp::Schema")

      expect(GraphWeaver::SchemaLoader).to have_received(:introspect)
        .with(MyApp::Schema, cache: GraphWeaver.schema_path, ttl: 0)
      expect(actions).to include([:say_status, :introspect, "app/graphql/schema.json from MyApp::Schema"])
    end

    it "names the fix for a constant that isn't one, before writing anything" do
      expect { run_generator("MyApp::Shcema") }
        .to raise_error Thor::Error, /uninitialized constant MyApp::Shcema.*rails g graphql:install/m
    end

    it "rejects a class that can't execute" do
      stub_const("MyApp::Pet", Class.new)

      expect { run_generator("MyApp::Pet") }.to raise_error Thor::Error, /isn't a graphql-ruby schema/
    end
  end

  context "a schema dump" do
    it "points at the dump the app already has rather than writing another" do
      actions = run_generator("db/schema.graphql")

      expect(initializer(actions)).to include 'GraphWeaver.schema_path = "db/schema.graphql"'
      expect(YAML.safe_load(created(actions)["graphql.config.yml"])["schema"]).to eq "db/schema.graphql"
      expect(GraphWeaver::SchemaLoader).not_to have_received(:refresh!)
      expect(GraphWeaver::SchemaLoader).not_to have_received(:introspect)
      expect(initializer(actions)).to include "Point the app default at whatever serves this API"
    end

    # the install run is the one moment a user is guaranteed to be reading,
    # and a composed supergraph changes what the next steps are
    it "says what a composed supergraph means, rather than treating it as any dump" do
      actions = run_generator(RouterGraph::SUPERGRAPH)
      told = actions.filter_map { |kind, text| text if kind == :say }.join("\n")

      expect(initializer(actions)).to include "A composed supergraph", "graphql: :router"
      expect(told).to include "3 subgraphs: accounts, products, reviews"
      expect(told).to include "rake graph_weaver:federation:diff", "graphql: :router"
    end
  end

  it "refuses --auth for a source that never authenticates" do
    expect { run_generator("db/schema.graphql", auth: "TOKEN") }
      .to raise_error Thor::Error, /--auth applies to a url/
  end
end
