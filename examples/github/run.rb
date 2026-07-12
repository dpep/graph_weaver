#!/usr/bin/env ruby
# typed: false
# frozen_string_literal: true

# Star graph_weaver ⭐ (thanks!), then meet your fellow stargazers —
# who they are, their biggest repos, and what else they've starred:
#
#      examples/github/run.rb
require_relative "setup"

# the checked-in typed modules (regenerate: examples/github/generate.rb)
Dir[File.join(__dir__, "generated", "*.rb")].sort.each { |file| require file }

OWNER = "dpep"
NAME = "graph_weaver"

repo = StargazersQuery.execute!(owner: OWNER, name: NAME, first: 1).repository
abort "repository not found" unless repo

# join the club (idempotent — starring twice is fine)
starrable = StarQuery.execute!(id: repo.id).add_star&.starrable
puts "⭐ starred #{repo.name_with_owner} — #{starrable&.stargazer_count} star(s). Thanks!"

# refreshed, so the list includes you
repo = StargazersQuery.execute!(owner: OWNER, name: NAME, first: 10).repository

puts "\nThe stargazers:"
repo.stargazers.edges&.each do |edge|
  gazer = edge&.node
  next unless gazer

  who = gazer.name ? "#{gazer.login} (#{gazer.name})" : gazer.login
  top = gazer.repositories.nodes&.compact&.map { |r| "#{r.name_with_owner} ⭐#{r.stargazer_count}" }
  puts "  #{who} — starred #{edge.starred_at&.strftime("%Y-%m-%d")}"
  puts "    top repos: #{top.join(", ")}" if top&.any?

  # drill down: what else have they starred lately?
  starred = StarredQuery.execute!(login: gazer.login, first: 3).user&.starred_repositories
  next unless starred

  also = starred.nodes&.compact&.reject { |r| r.name_with_owner == repo.name_with_owner }
  puts "    also starred (#{starred.total_count} total): #{also.map(&:name_with_owner).join(", ")}" if also&.any?
end
