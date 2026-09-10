#!/usr/bin/env ruby
# typed: false
# frozen_string_literal: true

# Regenerate the checked-in typed modules from queries/*.graphql —
# the same workflow `rake graph_weaver:generate` runs in an app:
#
#      examples/github/generate.rb
require_relative "setup"

GraphWeaver.generate!(
  schema: GraphWeaver.client.schema,
  queries: File.join(__dir__, "queries"),
  output: File.join(__dir__, "generated"),
)
changed = GraphWeaver.changed_files
changed.each { |path| puts "wrote #{path}" }
puts "already up to date" if changed.empty?
