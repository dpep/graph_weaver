require_relative "lib/graph_weaver/version"

Gem::Specification.new do |s|
  s.authors     = ["Daniel Pepper"]
  # the README tagline, verbatim — the two pitches drifted apart once already,
  # so spec/gemspec_spec.rb pins them together
  s.description = "Your .graphql files, compiled into Sorbet types — and the fakes to test them."
  # CLAUDE.md/PLAN.md/REVIEW.md/NOTES.md/DECISIONS.md are written for whoever
  # works on the gem, not whoever installs it — and REVIEW.md carries examples
  # from before the API it describes was rewritten
  # examples/ ships (small plain text) so the README's links to it resolve for
  # someone who only has the installed gem, not a checkout
  # CHANGELOG.md doesn't (259 KB, ~16% of the package) — changelog_uri below
  # points at the GitHub copy instead
  unpackaged = %w[spec sorbet bin design research CLAUDE.md PLAN.md REVIEW.md
    NOTES.md DECISIONS.md CHANGELOG.md Makefile]
  # git knows what is tracked; a checkout that isn't a repo — an unpacked gem,
  # a vendored copy, a shallow CI export — has no such answer, and git's
  # "fatal:" on stderr lands in the output of every subprocess a spec captures.
  # So ask quietly, and walk the tree rather than ship nothing.
  files = `git ls-files * #{unpackaged.map { |path| "':!:#{path}'" }.join(" ")} 2>/dev/null`.split("\n")
  if files.empty?
    files = Dir.glob("**/*", base: __dir__).reject do |path|
      unpackaged.include?(path.split("/").first) || File.directory?(File.join(__dir__, path))
    end
  end
  # ".yardopts" explicitly: neither list carries a dotfile, and rubydoc.info
  # needs it shipped to render docstrings as markdown
  s.files       = files + [".yardopts"]
  s.homepage    = "https://github.com/dpep/graph_weaver"
  s.license     = "MIT"
  s.name        = "graph_weaver"
  # rubygems.org shows summary as the headline, description below it
  s.summary     = "A typed GraphQL client for Ruby"
  s.version     = GraphWeaver::VERSION

  s.metadata = {
    "bug_tracker_uri" => "#{s.homepage}/issues",
    # pinned to the release tag, not main — CHANGELOG.md isn't packaged, and
    # main drifts ahead of whatever version this metadata shipped with
    "changelog_uri" => "#{s.homepage}/blob/v#{s.version}/CHANGELOG.md",
    "documentation_uri" => "#{s.homepage}/tree/main/docs",
    # no separate homepage_uri: identical to s.homepage, and `gem build` warns
    # that rubygems.org only shows one of two metadata keys with the same uri
    "rubygems_mfa_required" => "true",
    "source_code_uri" => s.homepage,
  }

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
  s.add_development_dependency "rack" # WebMock's to_rack needs it; webmock doesn't depend on it
  s.add_development_dependency "rake"
  # spec/railtie_spec.rb boots a real Rails application: the railtie's bug of
  # record was Rails' initializer TSort putting graph_weaver.logger after
  # config/initializers, which a stand-in cannot model. Brings activesupport,
  # which LogSubscriber is checked against for the same reason.
  s.add_development_dependency "railties"
  s.add_development_dependency "redcarpet" # yard --markup markdown
  s.add_development_dependency "rspec"
  s.add_development_dependency "simplecov"
  s.add_development_dependency "sorbet"
  s.add_development_dependency "tapioca"
  s.add_development_dependency "webmock" # graphql: :wire serves its Rack app through it
  s.add_development_dependency "webrick"
  s.add_development_dependency "yard"
end
