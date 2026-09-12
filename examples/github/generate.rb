#!/usr/bin/env ruby
# typed: false
# frozen_string_literal: true

# Regenerate the checked-in typed modules from queries/*.graphql —
# the same workflow `rake graph_weaver:generate` runs in an app:
#
#      examples/github/generate.rb
require_relative "setup"

GraphWeaver.graph :github do
  schema GraphWeaver.client.schema
  queries File.join(__dir__, "queries")
  output File.join(__dir__, "generated")
end

GraphWeaver.generate!
changed = GraphWeaver.changed_files
changed.each { |path| puts "wrote #{path}" }
puts "already up to date" if changed.empty?
