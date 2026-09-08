# typed: ignore — conditional simplecov requires
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
