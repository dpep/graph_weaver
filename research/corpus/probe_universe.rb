require_relative "/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib/graph_weaver"

schema = GraphWeaver::SchemaLoader.load("/tmp/claude/graph_weaver/corpus/universe.json")
%w[Message WrstbndIntegration].each do |t|
  type = schema.get_type(t)
  next puts("#{t}: missing") unless type
  type.fields.each_value { |f| puts "#{t}.#{f.graphql_name}: #{f.type.to_type_signature}" }
end
puts "--- scalars ---"
schema.types.each_value { |t| puts "scalar #{t.graphql_name}" if t.kind.name == "SCALAR" }
