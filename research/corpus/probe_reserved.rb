$LOAD_PATH.unshift("/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib")
require "graph_weaver"

def try(label, sdl, query)
  schema = GraphQL::Schema.from_definition(sdl)
  mod = GraphWeaver::Codegen.parse(schema:, query:, name: "Probe")
  puts "#{label}: OK  #{mod.inspect}"
rescue StandardError => e
  puts "#{label}: #{e.class}: #{e.message.to_s[0, 300]}"
end

try("input named Result", <<~SDL, "query Q($r: Result!) { ping(r: $r) }")
  input Result { id: ID }
  type Query { ping(r: Result!): String }
SDL

try("input named QUERY", <<~SDL, "query Q($r: QUERY!) { ping(r: $r) }")
  input QUERY { id: ID }
  type Query { ping(r: QUERY!): String }
SDL

try("enum named Result", <<~SDL, "{ pick }")
  enum Result { A B }
  type Query { pick: Result }
SDL

try("object named Result", <<~SDL, "{ thing { id } }")
  type Result { id: ID }
  type Query { thing: Result }
SDL

try("field named _", <<~SDL, "{ _ }")
  type Query { _: String }
SDL

try("input field named _", <<~SDL, "query Q($f: F!) { ping(f: $f) }")
  input F { _: String }
  type Query { ping(f: F!): String }
SDL
