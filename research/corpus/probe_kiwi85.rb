$LOAD_PATH.unshift("/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib")
require "graph_weaver"
require_relative "/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/spec/support/round_trip"

schema = GraphWeaver::SchemaLoader.load("/tmp/claude/graph_weaver/corpus/kiwi.json")
GraphWeaver::Codegen.reset_registrations!
RoundTrip.register_scalars!(schema)
query = RoundTrip::Fuzzer.new(schema, Random.new(85)).query
puts query
puts "---"
begin
  GraphWeaver::Codegen.generate(schema:, query:, name: "Q")
  puts "OK"
rescue StandardError => e
  puts "#{e.class}: #{e.message}"
end
