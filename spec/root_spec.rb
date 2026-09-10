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
end
