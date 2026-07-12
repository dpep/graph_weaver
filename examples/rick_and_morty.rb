#!/usr/bin/env ruby
# typed: false
# frozen_string_literal: true

# One notch up from countries.rb: filtered search, pagination, and a
# block-built type helper — against the Rick and Morty API (free, no
# auth, wubba lubba dub dub):
#
#      examples/rick_and_morty.rb [NAME]
#      examples/rick_and_morty.rb morty
require_relative "../lib/graph_weaver"

api = GraphWeaver.new("https://rickandmortyapi.com/graphql")

# decorate every Character struct this client generates — derived values
# live as methods, the wire data stays honest
api.register_type("Character") do
  def emoji
    { "Alive" => "🟢", "Dead" => "💀" }.fetch(status, "❓")
  end
end

CharacterQuery = api.parse(<<~GRAPHQL)
  query($name: String, $page: Int) {
    characters(page: $page, filter: { name: $name }) {
      info { count pages next }
      results {
        name
        status
        species
        origin { name }
        episode { name }
      }
    }
  }
GRAPHQL

name = ARGV.first || "smith"
page = 1
total = nil

loop do
  characters = CharacterQuery.execute!(name:, page:).characters
  abort "no characters match #{name.inspect}" if characters&.results.to_a.empty?

  total ||= characters.info&.count
  characters.results.compact.each do |character|
    debut = character.episode.compact.first&.name
    puts "#{character.emoji} #{character.name} — #{character.species} from #{character.origin&.name}, debuted in #{debut.inspect}"
  end

  page = characters.info&.next
  break unless page
end

puts "\n#{total} character(s) matched #{name.inspect}"
