$LOAD_PATH.unshift("/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib")
require "graph_weaver"
require "json"

schema = GraphWeaver::SchemaLoader.load("/tmp/claude/graph_weaver/corpus/gitlab.json")
query = <<~GQL
  query Q($sort: MergeRequestSort) {
    project(fullPath: "a") { mergeRequests(sort: $sort) { count } }
  }
GQL
puts schema.validate(query).map(&:message).inspect
begin
  GraphWeaver::Codegen.generate(schema:, query:, name: "Q")
  puts "OK — generated"
rescue StandardError => e
  puts "#{e.class}: #{e.message}"
end

# and the output side: an enum FIELD of a case-colliding enum
out = <<~GQL
  query Q { project(fullPath: "a") { mergeRequests { nodes { state } } } }
GQL
puts schema.validate(out).map(&:message).inspect
begin
  GraphWeaver::Codegen.generate(schema:, query: out, name: "Q2")
  puts "output enum OK"
rescue StandardError => e
  puts "#{e.class}: #{e.message}"
end
