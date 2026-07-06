require "debug"
require "rspec"

require_relative "../lib/client"

RSpec.configure do |config|
  # allow "fit" examples
  config.filter_run_when_matching :focus
end
