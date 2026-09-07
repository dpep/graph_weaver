# typed: ignore — Gem::Specification.load is untyped
# frozen_string_literal: true

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
end
