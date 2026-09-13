# typed: false
# frozen_string_literal: true

# Only under `bundle exec mutant` — no effect on a plain rspec run.
if defined?(Mutant)
  # mutant picks which tests to run against a mutation from the first word of
  # each example's description, parsed as a subject expression. That pattern
  # accepts a lowercase word, so `describe "input errors"` selects the
  # namespace `input`, which matches no subject — and a mutation those
  # examples would have caught is reported alive. Tagging every example with
  # the whole gem's namespace makes selection say what is true: any spec can
  # kill any mutant. Narrow a run by naming spec files on the command line
  # (`--integration-argument spec/foo_spec.rb`), not by hoping.
  RSpec.configure do |config|
    config.define_derived_metadata do |metadata|
      metadata[:mutant_expression] ||= "GraphWeaver*"
    end
  end
end
