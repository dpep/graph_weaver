$LOAD_PATH.unshift("/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib")
require "graph_weaver"
require_relative "/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/spec/support/round_trip"

SCHEMA = GraphQL::Schema.from_definition(<<~GRAPHQL)
  scalar Time
  input TimeFilter { gt: Time, lt: Time }
  type Event { at: Time! }
  type Query { event(at: Time, between: TimeFilter): Event }
GRAPHQL

RoundTrip.register_scalars!(SCHEMA)
field = SCHEMA.query.fields["event"]
(0...40).each do |i|
  trip = RoundTrip.check_input(schema: SCHEMA, field:, name: "T#{i}", rng: Random.new(i))
  next if trip.failures.empty?
  puts "seed #{i}: #{trip.failures.first.detail}"
end
puts "--- kwargs samples ---"
(0...10).each do |i|
  inputs = RoundTrip::Inputs.new(SCHEMA, Random.new(i))
  puts "#{i}: #{inputs.build(field.arguments["at"].type).inspect}"
end
