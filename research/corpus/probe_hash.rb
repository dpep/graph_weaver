$LOAD_PATH.unshift("/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib")
require "graph_weaver"

schema = GraphQL::Schema.from_definition(<<~SDL)
  type Comment { id: ID }
  type Query { comment(hash: String, id: String,): Comment }
SDL
src = GraphWeaver::Codegen.generate(
  schema:,
  query: 'query Input($hash: String = "d", $id: String) { comment(hash: $hash, id: $id) { id } }',
  name: "Q",
)
puts src.lines.grep(/def self\.execute|"hash"|"class"/).join
