# typed: ignore — conditional simplecov requires
#
# Naming things in a spec file: `describe` is a block, not a class body, so a
# constant written inside one lands on Object — and the second file to want
# that name silently reassigns the first ("warning: already initialized
# constant"), leaving whichever ran last as the one every file sees. So a
# spec file names things in a module of its own (`module DraftsDemo`, in
# rspec_spec.rb), or in a `let`/local when one example is the only reader.
# Something two spec files share is neither: it belongs in spec/support,
# under its own module, loaded once from here.
require "debug"
require "rspec"
require "simplecov"

SimpleCov.start do
  add_filter "/spec/"
end

if ENV["CI"] == "true" || ENV["CODECOV_TOKEN"]
  require "simplecov_json_formatter"
  SimpleCov.formatter = SimpleCov::Formatter::JSONFormatter
end

# load this gem
gem_name = Dir.glob("*.gemspec")[0].split(".")[0]
require gem_name

# Rake keeps a task's `desc` only while this is on — it turns it on for
# `rake -T` and nothing else. Set before any spec loads tasks.rb, so a spec
# can ask which tasks a user is meant to see.
require "rake"
Rake::TaskManager.record_task_metadata = true

RSpec.configure do |config|
  # allow "fit" examples
  config.filter_run_when_matching :focus

  # network-touching specs (spec/integration) are opt-in:
  #   make integration
  config.filter_run_excluding :integration unless ENV["INTEGRATION"]
end

Dir["./spec/support/**/*.rb"].sort.each { |f| require f }
