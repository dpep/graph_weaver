# typed: ignore — declares graphs and loads generated constants per example
require "fileutils"
require "tmpdir"

# Which directories the generated modules are hidden from Zeitwerk in, and read
# back from. Both answers have to agree with Dir.glob, which is what expands
# these patterns everywhere else — a directory dropped here is neither ignored
# nor loaded, and nothing says so.
describe "GraphWeaver::Internal::Util.generated_dirs" do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      GraphWeaver.root = @root
      example.run
    ensure
      GraphWeaver.root = nil
      GraphWeaver.reset_graphs!
    end
  end

  def declare(path)
    where = path
    GraphWeaver.graph :nested_probe do
      schema Demo::Schema
      output where
    end
  end

  # File.fnmatch? lets * cross a / unless it is told not to; Dir.glob never
  # does. So app/graphql/a/b/generated read as "already covered" by the default
  # app/graphql/*/generated, and was then neither ignored nor loaded — a
  # production boot died on a Zeitwerk NameError naming a constant nobody wrote.
  it "keeps an output the default glob does not actually reach" do
    declare "app/graphql/a/b/generated"

    expect(GraphWeaver::Internal::Util.generated_dirs).to include "app/graphql/a/b/generated"
  end

  it "names an output the default glob does reach only once" do
    declare "app/graphql/billing/generated"

    expect(GraphWeaver::Internal::Util.generated_dirs).to eq GraphWeaver.generated_paths
  end

  # the half a development boot sees: no error, just modules that never arrived
  it "loads from an output the default glob does not reach" do
    FileUtils.mkdir_p(File.join(@root, "app/graphql/a/b/generated"))
    File.write(File.join(@root, "app/graphql/a/b/generated/nested_probe_query.rb"),
      "module NestedDirsProbe; end")
    declare "app/graphql/a/b/generated"

    expect(GraphWeaver.load_generated!).to eq ["app/graphql/a/b/generated/nested_probe_query.rb"]
  ensure
    Object.send(:remove_const, :NestedDirsProbe) if Object.const_defined?(:NestedDirsProbe)
  end
end
