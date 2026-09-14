$LOAD_PATH.unshift("/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib")
require "graph_weaver"

schema = GraphQL::Schema.from_definition(<<~SDL)
  input Result { id: ID }
  type Query { ping(r: Result!): String }
SDL
query = "query Q($r: Result!) { ping(r: $r) }"
puts GraphWeaver::Codegen.new(schema:, query:, name: "Probe").generate
puts "=== Representations ==="
schema2 = GraphQL::Schema.from_definition(<<~SDL)
  input Representations { id: ID }
  type Query { ping(r: Representations!): String }
SDL
begin
  puts GraphWeaver::Codegen.new(schema: schema2, query: "query Q($r: Representations!) { ping(r: $r) }", name: "Probe").generate[0, 600]
rescue StandardError => e
  puts "#{e.class}: #{e.message[0, 200]}"
end
