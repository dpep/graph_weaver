# typed: ignore — stubs the Rails::Generators constants sorbet can't resolve
require "yaml"


# `rails` isn't a dependency, so — as in railtie_spec — the Rails DSL the
# generator sits on is stood in for, and the real generator runs against
# it. Thor invokes a generator's public instance methods in definition
# order, which is what run_generator reproduces.
describe "GraphWeaver::Generators::InstallGenerator" do
  # records what the generator asks Thor to do, and nothing else: the
  # stub has no way to write to disk, so a write that bypassed create_file
  # would fail here rather than silently overwrite a real file
  def generator_class
    base = Class.new do
      def self.desc(*); end

      def self.class_options = @class_options ||= {}

      def self.class_option(name, **opts) = class_options[name] = opts

      # Thor::Group collects its commands in method_added, in definition
      # order — reflection order isn't guaranteed, so mirror that rather
      # than reading it back off the class
      def self.commands = @commands ||= []

      def self.method_added(name)
        super
        commands << name if name != :initialize && public_method_defined?(name)
      end

      attr_reader :options, :actions

      def initialize(options = {})
        defaults = self.class.class_options.to_h { |name, opts| [name, opts[:default]] }
        @options = defaults.merge(options)
        @actions = []
      end

      def create_file(*args) = @actions << [:create_file, *args]

      def say_status(*args) = @actions << [:say_status, *args]

      def say(*args) = @actions << [:say, *args]
    end

    stub_const("Rails::Generators::Base", base)
    load File.expand_path("../lib/generators/graph_weaver/install_generator.rb", __dir__)
    GraphWeaver::Generators::InstallGenerator
  end

  def run_generator(**options)
    klass = generator_class
    generator = klass.new({ url: "https://api.example.com/graphql" }.merge(options))
    klass.commands.each { |name| generator.public_send(name) }
    generator.actions
  ensure
    GraphWeaver.send(:remove_const, :Generators) if GraphWeaver.const_defined?(:Generators, false)
  end

  def created(actions)
    actions.filter_map { |kind, path, content| [path, content] if kind == :create_file }.to_h
  end

  before { allow(GraphWeaver::SchemaLoader).to receive(:refresh!).and_return(["app/graphql/schema.json", "https://api.example.com/graphql"]) }

  it "scaffolds the conventional layout" do
    files = created(run_generator)

    expect(files.keys).to eq [
      "config/initializers/graph_weaver.rb",
      "app/graphql/queries/.keep",
      "app/graphql/generated/.keep",
      "graphql.config.yml",
    ]
  end

  it "wires the initializer to the url and auth var it was given" do
    initializer = created(run_generator(auth: "GITHUB_TOKEN"))["config/initializers/graph_weaver.rb"]

    expect(initializer).to include <<~RUBY.chomp
      GraphWeaver.client = GraphWeaver.new(
        "https://api.example.com/graphql",
        auth: ENV["GITHUB_TOKEN"],
    RUBY
    expect(initializer).to include "register_scalar", "extend_type" # pointers, not a wall of options
  end

  it "writes an editor config the plugins can read, fragments included" do
    config = YAML.safe_load(created(run_generator)["graphql.config.yml"])

    expect(config["schema"]).to eq GraphWeaver.schema_path
    # fragments too, or an editor reports `Unknown fragment`
    expect(config["documents"]).to eq [
      "app/graphql/queries/**/*.graphql",
      "app/graphql/fragments/**/*.graphql",
    ]
  end

  it "bootstraps the schema dump through the refresh path" do
    ENV["GITHUB_TOKEN"] = "s3cret"
    actions = run_generator(auth: "GITHUB_TOKEN")

    expect(GraphWeaver::SchemaLoader).to have_received(:refresh!)
      .with(url: "https://api.example.com/graphql", auth: "s3cret")
    expect(actions).to include([:say_status, :introspect, "app/graphql/schema.json from https://api.example.com/graphql"])
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

  it "leaves conflicts to Thor rather than forcing them" do
    # create_file prompts with a diff on a re-run — unless it's handed
    # force:, which would silently clobber an edited initializer
    writes = run_generator.select { |kind,| kind == :create_file }

    expect(writes.map(&:size)).to all(eq(3)) # [:create_file, path, content] — no options
  end
end
