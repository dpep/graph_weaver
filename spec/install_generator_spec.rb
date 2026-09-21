# typed: ignore — stubs the Rails::Generators constants sorbet can't resolve
require "tmpdir"
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

    def append_to_file(*args) = @actions << [:append_to_file, *args]

    def insert_into_file(*args, **opts) = @actions << [:insert_into_file, *args, opts]

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

  # GraphWeaver.root is where the generator reads the app's OWN files — the
  # rubocop config, the spec helper. An empty app, so no example is answered
  # by this repo's copy of either.
  around do |example|
    Dir.mktmpdir do |app|
      @app = app
      GraphWeaver.root = app
      example.run
    ensure
      GraphWeaver.root = nil
    end
  end

  it "scaffolds the conventional layout" do
    files = created(run_generator)

    expect(files.keys).to eq [
      "config/initializers/graph_weaver.rb",
      "app/graphql/queries/.keep",
      # fragments too: graphql.config.yml globs it, so an editor that follows
      # the config would be pointed at a directory nothing had created
      "app/graphql/fragments/.keep",
      "app/graphql/generated/.keep",
      "graphql.config.yml",
      ".gitattributes",
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

  # docs/editors.md exists to be copy-pasted by someone who never runs the
  # generator, so it prints this file — every conventional path in one block,
  # and the one place they'd notice a default had moved.
  it "writes what docs/editors.md tells you to write" do
    written = created(run_generator)["graphql.config.yml"]
    docs = File.read(File.expand_path("../docs/editors.md", __dir__))
    printed = docs[/```yaml\n(.*?)```/m, 1] or raise "docs/editors.md no longer prints the config"

    expect(YAML.safe_load(printed)).to eq YAML.safe_load(written)
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

    # --auth is what says this API takes a token. Wiring one anyway read as
    # setup a public API needs, and pointed every install at an ENV var
    # nobody had set — while docs/getting_started.md said the flag was
    # "omitted entirely for a public API that needs no token".
    it "shows the auth line rather than wiring it when no --auth was given" do
      written = initializer(run_generator)

      expect(written).not_to match(/^\s*auth:/)
      expect(written).to include %(  # auth: ENV["GRAPHWEAVER_AUTH"],)
      expect(written).to include "register_scalar", "extend_type" # pointers, not a wall of options
    end

    # The one registration a new app copies, so it has to be the current
    # spelling of one that's actually needed: the example named DateTime,
    # which needs no registration, with the keywords 0.6.1 made unnecessary.
    it "shows a scalar that needs registering, named the way it is now" do
      example = initializer(run_generator)[/^#\s+GraphWeaver\.register_scalar.*$/]

      expect(example).to eq %(#   GraphWeaver.register_scalar("Money", BigDecimal))
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

    # `rake graph_weaver:schema:refresh` was the retry it named, and with no
    # dump written that task has no url to read — so the advice failed too,
    # while the next steps still pointed at a generate that can't run either
    it "keeps the scaffolded files when introspection fails, and names a retry that works" do
      allow(GraphWeaver::SchemaLoader).to receive(:refresh!).and_raise(GraphWeaver::Error, "401 Unauthorized")
      actions = run_generator(URL, auth: "MY_TOKEN")

      expect(created(actions).keys).to include "config/initializers/graph_weaver.rb"
      expect(actions.flatten.join).to include "401 Unauthorized",
        "rails g graph_weaver:install #{URL} --auth MY_TOKEN",
        "no schema dump yet"
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

  # Generated code is machine-written and says "do not edit", but plain
  # `rubocop` lints it anyway — Style/Documentation on every struct,
  # Metrics/* on every from_h.
  # The dump is the one file the generator doesn't write through create_file,
  # so Thor can't prompt on it — declining every conflict on a re-run still
  # replaced it, and with it the source url it records, while the docs said
  # every file went through the conflict prompt.
  describe "a dump the app already has" do
    def dump(body)
      FileUtils.mkdir_p(File.join(@app, "app/graphql"))
      File.write(File.join(@app, "app/graphql/schema.json"), body)
    end

    def told(actions) = actions.filter_map { |kind, *rest| rest.join(" ") if kind == :say_status }.join("\n")

    it "is kept, not re-introspected, and named with the way to replace it" do
      dump("{}")
      actions = run_generator

      expect(GraphWeaver::SchemaLoader).not_to have_received(:refresh!)
      expect(told(actions)).to include "app/graphql/schema.json", "delete it and re-run"
    end

    it "is kept for a schema class too" do
      stub_const("MyApp::Schema", Class.new { def self.execute(*) = {} })
      dump("{}")
      run_generator("MyApp::Schema")

      expect(GraphWeaver::SchemaLoader).not_to have_received(:introspect)
    end

    # answering a re-run that names a new endpoint with the old dump, silently,
    # is the worst of the three outcomes
    it "says where it came from when that isn't the source just given" do
      dump(JSON.generate("graph_weaver" => { "url" => "https://old.example.com/graphql" }))

      expect(told(run_generator)).to include "introspected from https://old.example.com/graphql"
    end

    it "still introspects when there is no dump" do
      run_generator

      expect(GraphWeaver::SchemaLoader).to have_received(:refresh!)
    end
  end

  # A `graphql:` tag does nothing without this require, and the advice used
  # to be "put it in spec/support/graph_weaver.rb" — which rspec-rails ships
  # commented out of rails_helper, so it silently never ran.
  describe "the rspec require" do
    REQUIRE_LINE = %(require "graph_weaver/rspec")

    before { FileUtils.mkdir_p(File.join(@app, "spec")) }

    def spec_helper(name, body) = File.write(File.join(@app, "spec", name), body)

    # rspec-rails' own rails_helper, trimmed to the lines that matter —
    # single-quoted, the way it really writes them
    RAILS_HELPER = <<~RUBY
      require 'spec_helper'
      ENV['RAILS_ENV'] ||= 'test'
      require_relative '../config/environment'
      require 'rspec/rails'

      RSpec.configure do |config|
      end
    RUBY

    def wiring(actions)
      actions.select { |kind,| %i[insert_into_file append_to_file].include?(kind) }
    end

    # Thor's semantics, so the assertion is the file the app ends up with —
    # asserting the anchor alone missed a require landing on the end of the
    # line it anchored to.
    def applied(actions, body)
      wiring(actions).reduce(body) do |text, (kind, _path, content, options)|
        kind == :append_to_file ? text + content : text.sub(options[:after]) { _1 + content }
      end
    end

    it "goes into rails_helper on its own line, under rspec-rails' own require" do
      spec_helper("rails_helper.rb", RAILS_HELPER)
      actions = run_generator

      expect(wiring(actions).map { _1.first(3) })
        .to eq [[:insert_into_file, "spec/rails_helper.rb", "#{REQUIRE_LINE}\n"]]
      expect(applied(actions, RAILS_HELPER)).to eq <<~RUBY
        require 'spec_helper'
        ENV['RAILS_ENV'] ||= 'test'
        require_relative '../config/environment'
        require 'rspec/rails'
        #{REQUIRE_LINE}

        RSpec.configure do |config|
        end
      RUBY
    end

    # rspec-rails writes both; only rails_helper has Rails booted by then
    it "prefers rails_helper when both are there" do
      spec_helper("rails_helper.rb", RAILS_HELPER)
      spec_helper("spec_helper.rb", "RSpec.configure do |config|\nend\n")

      expect(wiring(run_generator).map { _1[1] }).to eq ["spec/rails_helper.rb"]
    end

    # rspec's generated spec_helper has no requires at all to sit under
    it "appends to spec_helper when there is no rails_helper" do
      body = "RSpec.configure do |config|\nend\n"
      spec_helper("spec_helper.rb", body)
      actions = run_generator

      expect(wiring(actions).map { _1.first(2) }).to eq [[:append_to_file, "spec/spec_helper.rb"]]
      expect(applied(actions, body)).to eq "#{body}\n#{REQUIRE_LINE}\n"
    end

    it "does nothing on a re-run, whichever quotes the require is in" do
      spec_helper("rails_helper.rb", "#{RAILS_HELPER}require 'graph_weaver/rspec'\n")

      expect(wiring(run_generator)).to be_empty
    end

    # an app with no rspec yet — the line still has to reach someone
    it "names the line when there is no spec helper to put it in" do
      expect(wiring(run_generator)).to be_empty
      expect(run_generator.filter_map { |kind, text| text if kind == :say }.join)
        .to include(REQUIRE_LINE)
    end
  end

  # The third telling of "generated/ is generated", after the do-not-edit
  # header and the rubocop Exclude — this one for GitHub's review UI. Display
  # only: the files stay versioned, and a local `git diff` is untouched.
  describe "the linguist mark" do
    GITATTRIBUTES = ".gitattributes"
    MARK = "app/graphql/generated/** linguist-generated"

    def gitattributes(body) = File.write(File.join(@app, GITATTRIBUTES), body)

    def written(actions)
      actions.filter_map do |kind, path, content|
        content if %i[create_file append_to_file].include?(kind) && path == GITATTRIBUTES
      end
    end

    # unlike .rubocop.yml, a .gitattributes turns nothing on — so there is no
    # app whose tooling writing one could surprise
    it "creates the file when the app has none" do
      expect(written(run_generator).join).to include MARK
    end

    it "keeps what an existing file says and adds the mark under it" do
      gitattributes("*.rb text eol=lf\n")
      actions = run_generator

      expect(actions).to include([:append_to_file, GITATTRIBUTES, a_string_including(MARK)])
      # appended, not rewritten — the app's own lines aren't ours to restate
      expect(written(actions).join).not_to include "text eol=lf"
    end

    it "does nothing on a re-run" do
      gitattributes("#{MARK}\n")

      expect(written(run_generator)).to be_empty
    end

    # `dir/**`, `dir/*`, `dir/` and `dir` are the same directory to git, so a
    # mark added by hand in any of those spellings is already the mark
    it "recognises the directory spelled without the glob" do
      gitattributes("app/graphql/generated/ linguist-generated\n")

      expect(written(run_generator)).to be_empty
    end

    # reading the body as one string meant any mention suppressed the mark —
    # including the comment the generator writes above it in prose
    it "doesn't take a comment that mentions the path as having marked it" do
      gitattributes("# app/graphql/generated/** is machine-written, do not edit\n")

      expect(written(run_generator).join).to include MARK
    end

    it "marks every graph's output directory" do
      GraphWeaver.graph(:pets) { output "app/graphql/pets/generated" }
      GraphWeaver.graph(:billing) { output "app/graphql/billing/generated" }

      expect(written(run_generator).join.scan(/^\S+ linguist-generated$/)).to eq [
        "app/graphql/pets/generated/** linguist-generated",
        "app/graphql/billing/generated/** linguist-generated",
      ]
    ensure
      GraphWeaver.reset_graphs!
    end

    # `-diff` would change what `git diff` shows locally; linguist is GitHub's
    # reader and nothing else's
    it "changes nothing about a local diff" do
      expect(written(run_generator).join).not_to include "-diff"
    end
  end

  describe "the rubocop exclude" do
    def rubocop_config(body) = File.write(File.join(@app, ".rubocop.yml"), body)

    def appended(actions)
      actions.filter_map { |kind, path, content| content if kind == :append_to_file && path == ".rubocop.yml" }
    end

    # inherit_mode is load-bearing, not decoration: rubocop REPLACES an Exclude
    # array on merge, so without it the appended block wipes the effective list —
    # rubocop's own vendor/node_modules/tmp defaults, and any Exclude the app
    # inherited from a shared config the generator can't see. Verified against
    # real RuboCop::ConfigLoader resolution in the hunt (rubocop isn't a
    # dev dependency here — the gem doesn't lint itself), so the spec pins the
    # directive the generator must write.
    it "excludes every graph's output directory from an app that lints, unioning with what's there" do
      rubocop_config("Style/StringLiterals:\n  EnforcedStyle: double_quotes\n")

      expect(YAML.safe_load(appended(run_generator).join)).to eq(
        "AllCops" => {
          "inherit_mode" => { "merge" => ["Exclude"] },
          "Exclude" => ["app/graphql/generated/**/*"],
        }
      )
    end

    # rubocop reads only the first document of a multi-document file, so the
    # append lands where nothing will ever read it
    it "names the lines rather than appending to a second YAML document" do
      rubocop_config("Style/StringLiterals:\n  EnforcedStyle: double_quotes\n---\nStyle/Documentation:\n  Enabled: false\n")
      actions = run_generator

      expect(appended(actions)).to be_empty
      expect(actions.filter_map { |kind, text| text if kind == :say }.join)
        .to include("more than one YAML document", %(- "app/graphql/generated/**/*"))
    end

    it "does nothing on a re-run" do
      rubocop_config("AllCops:\n  Exclude:\n    - \"app/graphql/generated/**/*\"\n")
      actions = run_generator

      expect(appended(actions)).to be_empty
      expect(actions.filter_map { |kind, text| text if kind == :say }.join).not_to include "AllCops"
    end

    # writing one would turn rubocop on for a project that never asked for it
    it "does not create the file when the app doesn't lint" do
      expect(appended(run_generator)).to be_empty
    end

    # rubocop takes the last of two duplicate keys, so a second AllCops:
    # would replace the app's own rather than add to it
    it "names the lines rather than replacing an AllCops the app already has" do
      rubocop_config("AllCops:\n  NewCops: enable\n")
      actions = run_generator

      expect(appended(actions)).to be_empty
      expect(actions.filter_map { |kind, text| text if kind == :say }.join)
        .to include(%(- "app/graphql/generated/**/*"))
    end
  end
end
