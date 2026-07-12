# typed: false
# frozen_string_literal: true

# List this repo's stargazers with checked-in generated modules — and
# maybe join them:
#
#      ruby examples/github/run.rb          # who starred graph_weaver?
#      ruby examples/github/run.rb --star   # add yours ⭐ (thanks!)
require_relative "setup"

# the checked-in typed modules (regenerate: ruby examples/github/generate.rb)
Dir[File.join(__dir__, "generated", "*.rb")].sort.each { |file| require file }

repo = StargazersQuery.execute!(owner: "dpep", name: "graph_weaver", first: 10).repository
abort "repository not found" unless repo

puts "#{repo.name_with_owner} — ⭐ #{repo.stargazer_count}"
repo.stargazers.edges&.each do |edge|
  gazer = edge&.node
  next unless gazer

  who = gazer.name ? "#{gazer.login} (#{gazer.name})" : gazer.login
  puts "  ⭐ #{who} — #{edge.starred_at&.strftime("%Y-%m-%d")}"
end

if ARGV.include?("--star")
  starrable = StarQuery.execute!(id: repo.id).add_star&.starrable
  abort "starring failed" unless starrable

  puts "\nThanks for the star! ⭐ now at #{starrable.stargazer_count}"
end
