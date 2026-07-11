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

RSpec.configure do |config|
  # allow "fit" examples
  config.filter_run_when_matching :focus

  # network-touching specs (spec/integration) are opt-in:
  #   make integration
  config.filter_run_excluding :integration unless ENV["INTEGRATION"]
end

Dir["./spec/support/**/*.rb"].sort.each { |f| require f }
