#!/usr/bin/env ruby
# typed: false
# frozen_string_literal: true

# The simplest possible GraphWeaver session: a public API, no auth, no
# build step — everything dynamic and in memory.
#
#      examples/countries.rb [CODE ...]
#      examples/countries.rb JP BR
#
# (https://countries.trevorblades.com — a free public GraphQL API)
require_relative "../lib/graph_weaver"

api = GraphWeaver.new("https://countries.trevorblades.com/")

# parse once: a typed module bound to the client's schema + transport
CountryQuery = api.parse(<<~GRAPHQL)
  query($code: ID!) {
    country(code: $code) {
      name
      emoji
      capital
      continent { name }
    }
  }
GRAPHQL

codes = ARGV.empty? ? %w[US JP] : ARGV
codes.each do |code|
  country = CountryQuery.execute!(code: code.upcase).country
  abort "unknown country code: #{code}" unless country

  puts "#{country.emoji}  #{country.name} — capital #{country.capital}, #{country.continent.name}"
end

# or skip the module entirely — a one-shot with variables as kwargs
continents = api.execute!("query { continents { name countries { code } } }").continents
biggest = continents.max_by { |c| c.countries.size }
puts "\n#{continents.size} continents; #{biggest.name} has the most countries (#{biggest.countries.size})"
