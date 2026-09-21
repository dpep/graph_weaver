# typed: ignore — Gem::Specification.load is untyped
# frozen_string_literal: true

require "open3"
require "tmpdir"

# The gem's pitch appears twice — rubygems.org reads the gemspec, GitHub reads
# the README — and nothing but this keeps them the same pitch.
describe "graph_weaver.gemspec" do
  let(:root) { File.expand_path("..", __dir__) }

  it "describes the gem in the README's own words" do
    # the bold line under the badges, wherever it lands — pinning the opening
    # phrase instead is what broke last time the pitch was rewritten
    tagline = File.read(File.join(root, "README.md"))[/^\*\*(.+)\*\*$/, 1].delete("`")
    spec = Gem::Specification.load(File.join(root, "graph_weaver.gemspec"))

    expect(spec.description).to eq tagline
  end

  # An unpacked gem, a vendored copy or a shallow CI export is a checkout with
  # no .git. Bundler evaluates this gemspec in every subprocess, so `git
  # ls-files` writing "fatal: not a git repository" to stderr landed in the
  # output of the three specs that capture a child with 2>&1 — and read as the
  # failure.
  it "is quiet outside a git repo, and still names its files" do
    script = <<~RUBY
      spec = Gem::Specification.load(#{File.join(root, "graph_weaver.gemspec").inspect})
      print spec.files.include?("lib/graph_weaver.rb")
      print " "
      print spec.files.none? { |path| path.start_with?("spec/") }
    RUBY

    Dir.mktmpdir do |dir|
      out, err, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: dir)

      expect(err).to eq ""
      expect(status).to be_success
      expect(out).to eq "true true"
    end
  end
end
