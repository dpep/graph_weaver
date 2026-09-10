# typed: ignore — the generated constant only exists once an example runs
require "fileutils"
require "tmpdir"
require "graph_weaver/testing"

# One rule for every relative path setting: it resolves against
# GraphWeaver.root, so a dev server or an rspec run started from a
# subdirectory reads the same files a rake task does.
describe "GraphWeaver.root" do
  after { GraphWeaver.root = nil }

  it "follows the working directory when nothing else says otherwise" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { expect(GraphWeaver.root).to eq Dir.pwd }
    end
  end

  it "is Rails.root in a Rails app" do
    rails = Module.new
    rails.define_singleton_method(:root) { Pathname.new("/srv/app") }
    stub_const("Rails", rails)

    expect(GraphWeaver.root).to eq "/srv/app"
  end

  # railtie_spec leaves a bare `Rails` behind, and an app may name something
  # else Rails entirely
  it "ignores a Rails that isn't a Rails app" do
    stub_const("Rails", Module.new)

    expect(GraphWeaver.root).to eq Dir.pwd
  end

  it "can be set, and nil restores the default" do
    GraphWeaver.root = "/srv/app"
    expect(GraphWeaver.root).to eq "/srv/app"

    GraphWeaver.root = nil
    expect(GraphWeaver.root).to eq Dir.pwd
  end
  describe "path settings" do
    around do |example|
      Dir.mktmpdir do |app|
        @app = app
        FileUtils.mkdir_p(File.join(app, "app/graphql/queries"))
        File.write(File.join(app, "app/graphql/schema.graphql"), Demo::Schema.to_definition)
        File.write(File.join(app, "app/graphql/queries/root_probe.graphql"),
          "query { person(id: 1) { name } }\n")
        GraphWeaver.root = app

        # every default setting is relative; the point is that none of them
        # is read against the working directory
        Dir.mktmpdir { |elsewhere| Dir.chdir(elsewhere) { example.run } }
      ensure
        GraphWeaver.types_module = nil
        Object.send(:remove_const, :RootProbeQuery) if Object.const_defined?(:RootProbeQuery)
        Object.send(:remove_const, :RootTypes) if Object.const_defined?(:RootTypes)
      end
    end

    # the install generator writes queries_paths.first into graphql.config.yml,
    # a committed file — an absolute path there is wrong for everyone but its author
    it "keeps returning what was configured" do
      expect(GraphWeaver.queries_paths).to eq ["app/graphql/queries"]
      expect(GraphWeaver.schema_path).to eq "app/graphql/schema.json"
    end

    it "finds the queries and the schema dump" do
      expect(GraphWeaver::Internal::Util.query_files)
        .to eq [File.join(@app, "app/graphql/queries/root_probe.graphql")]
      expect(GraphWeaver::SchemaLoader.locate_path).to eq File.join(@app, "app/graphql/schema.graphql")
      expect(GraphWeaver::SchemaLoader.locate).to be_a Class
    end

    it "generates, verifies and loads under the root" do
      GraphWeaver.types_module = "RootTypes"
      written = GraphWeaver.generate!

      expect(written).to eq [File.join(@app, "app/graphql/generated/root_probe_query.rb")]
      expect { GraphWeaver.verify_generated! }.not_to raise_error
      expect(GraphWeaver.load_generated!).to eq written
      expect(RootProbeQuery::Result::Person.props.keys).to eq %i[name]

      GraphWeaver.reload_generated!
      expect(defined?(RootProbeQuery)).to be_truthy
    end

    it "leaves an absolute setting alone" do
      Dir.mktmpdir do |other|
        File.write(File.join(other, "schema.graphql"), Demo::Schema.to_definition)
        GraphWeaver.schema_path = File.join(other, "schema.graphql")

        expect(GraphWeaver::SchemaLoader.locate_path).to eq File.join(other, "schema.graphql")
      ensure
        GraphWeaver.schema_path = nil
      end
    end
  end
end
