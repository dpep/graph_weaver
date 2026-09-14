# What codegen refuses, and why, over a directory of real operations.
#   refusals.rb <schema> <queries-dir>
$LOAD_PATH.unshift("/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib")
require "graph_weaver"
require_relative "/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/spec/support/round_trip"
require "json"

schema_path, dir = ARGV
schema = schema_path.end_with?(".json") ?
  GraphQL::Schema.from_introspection(JSON.parse(File.read(schema_path)).then { |r| r.key?("data") ? r : { "data" => r } }) :
  GraphQL::Schema.from_definition(File.read(schema_path))

GraphWeaver::Codegen.reset_registrations!
RoundTrip.register_scalars!(schema)

buckets = Hash.new { |h, k| h[k] = [] }
invalid = 0
Dir[File.join(dir, "**/*.graphql")].sort.each do |file|
  text = File.read(file)
  errors = schema.validate(text)
  next invalid += 1 unless errors.empty?

  GraphWeaver::Codegen.parse(schema:, query: text, name: "Q#{File.basename(file, ".graphql").gsub(/[^a-zA-Z0-9]/, "").sub(/\A[a-z]/, &:upcase)}")
rescue GraphWeaver::Error, ArgumentError => e
  buckets[e.message.gsub(/'[^']*'|"[^"]*"|\b[A-Z]\w+\b/) { "X" }[0, 110]] << [File.basename(file), e.message]
end

puts "#{invalid} files the schema rejects outright"
puts "#{buckets.values.sum(&:size)} refusals in #{buckets.size} buckets"
buckets.sort_by { |_, v| -v.size }.each do |key, list|
  puts "\n=== #{list.size}x"
  puts "  #{list.first[0]}: #{list.first[1][0, 500]}"
end
