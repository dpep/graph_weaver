require_relative "lib/graph_weaver/version"

Gem::Specification.new do |s|
  s.authors     = ["Daniel Pepper"]
  # the README tagline, verbatim — the two pitches drifted apart once already,
  # so spec/gemspec_spec.rb pins them together
  s.description = "A typed GraphQL client for Ruby: per-query Sorbet types, schema-correct fakes for your specs, and rake tasks for the whole schema lifecycle. Federation included."
  # ".yardopts" explicitly: `git ls-files *` skips dotfiles, and
  # rubydoc.info needs it shipped to render docstrings as markdown
  s.files       = `git ls-files * ':!:spec' ':!:sorbet' ':!:bin' ':!:examples'`.split("\n") + [".yardopts"]
  s.homepage    = "https://github.com/dpep/graph_weaver"
  s.license     = "MIT"
  s.name        = "graph_weaver"
  s.summary     = "GraphWeaver"
  s.version     = GraphWeaver::VERSION

  s.required_ruby_version = ">= 3.3"

  # 2.6.7 fills defaulted directive arguments when building from SDL
  # (rmosolgo/graphql-ruby#5659) — needed since we dropped our own patch for it
  s.add_dependency "graphql", ">= 2.6.7"
  s.add_dependency "sorbet-runtime"

  s.add_development_dependency "apollo-federation" # federation integration subgraphs
  s.add_development_dependency "bigdecimal"
  s.add_development_dependency "debug"
  s.add_development_dependency "faker"
  s.add_development_dependency "faraday"
  s.add_development_dependency "rake"
  s.add_development_dependency "redcarpet" # yard --markup markdown
  s.add_development_dependency "rspec"
  s.add_development_dependency "simplecov"
  s.add_development_dependency "sorbet"
  s.add_development_dependency "tapioca"
  s.add_development_dependency "webrick"
  s.add_development_dependency "yard"
end
