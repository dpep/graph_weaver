require_relative "lib/graph_weaver/version"

Gem::Specification.new do |s|
  s.authors     = ["Daniel Pepper"]
  s.description = "A typed GraphQL client for Ruby — generate Sorbet T::Structs from queries, with federation, extensibility, and testing in mind"
  s.files       = `git ls-files * ':!:spec' ':!:sorbet' ':!:bin'`.split("\n")
  s.homepage    = "https://github.com/dpep/graph_weaver"
  s.license     = "MIT"
  s.name        = "graph_weaver"
  s.summary     = "GraphWeaver"
  s.version     = GraphWeaver::VERSION

  s.required_ruby_version = ">= 3.3"

  s.add_dependency "graphql", ">= 2"
  s.add_dependency "sorbet-runtime"

  s.add_development_dependency "bigdecimal"
  s.add_development_dependency "debug"
  s.add_development_dependency "faraday"
  s.add_development_dependency "rspec"
  s.add_development_dependency "simplecov"
  s.add_development_dependency "sorbet"
  s.add_development_dependency "tapioca"
  s.add_development_dependency "webrick"
end
