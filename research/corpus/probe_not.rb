$LOAD_PATH.unshift("/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib")
require "graph_weaver"

schema = GraphWeaver::SchemaLoader.load("/tmp/claude/graph_weaver/corpus/gitlab.json")
arg = schema.query.fields["issues"].arguments["not"]
sig = arg.type.to_type_signature
[["$not", "not"], ["$notFilter", "notFilter"]].each do |label, var|
  query = "query Q($#{var}: #{sig}) { issues(not: $#{var}) { count } }"
  GraphWeaver::Codegen.generate(schema:, query:, name: "Q")
  puts "#{label}: OK"
rescue StandardError => e
  puts "#{label}: #{e.class}: #{e.message[0, 200]}"
end
