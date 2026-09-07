# typed: ignore — Gem::Specification.load is untyped
# frozen_string_literal: true

# The gem's pitch appears twice — rubygems.org reads the gemspec, GitHub reads
# the README — and nothing but this keeps them the same pitch.
describe "graph_weaver.gemspec" do
  let(:root) { File.expand_path("..", __dir__) }

  it "describes the gem in the README's own words" do
    tagline = File.read(File.join(root, "README.md"))[/^A typed GraphQL client.*$/]
    spec = Gem::Specification.load(File.join(root, "graph_weaver.gemspec"))

    expect(spec.description).to eq tagline
  end
end
