# Why codegen refuses the fuzzer's queries on a schema, bucketed.
#   fuzz_refusals.rb <schema> [count] [seed]
$LOAD_PATH.unshift("/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib")
require "graph_weaver"
require_relative "/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/spec/support/round_trip"

path, count, seed = ARGV
count = (count || 100).to_i
seed = (seed || 1).to_i
schema = GraphWeaver::SchemaLoader.load(path)
GraphWeaver::Codegen.reset_registrations!
RoundTrip.register_scalars!(schema)

buckets = Hash.new { |h, k| h[k] = [] }
count.times do |i|
  rng = Random.new(seed + i)
  query = RoundTrip::Fuzzer.new(schema, rng).query
  next unless query && schema.validate(query).empty?

  trip = RoundTrip.check(schema:, query:, name: "Case#{i}", rng:)
  next unless trip.refused

  buckets[trip.refused.gsub(/`[^`]*`|"[^"]*"|\b[A-Z]\w+\b/) { "X" }[0, 100]] << [seed + i, trip.refused, query]
end

puts "#{buckets.values.sum(&:size)} refusals in #{buckets.size} buckets"
buckets.sort_by { |_, v| -v.size }.each do |_, list|
  puts "\n=== #{list.size}x  [seed #{list.first[0]}]"
  puts "  #{list.first[1][0, 400]}"
  puts "  query: #{list.first[2].gsub(/\s+/, " ")[0, 300]}"
end
