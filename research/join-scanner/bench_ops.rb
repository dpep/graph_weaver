# frozen_string_literal: true

# The two per-node costs in the AST reader, measured on their own — the whole
# table is too noisy on a loaded box to separate them there.
require_relative "../../lib/graph_weaver"
require_relative "synth"

if ARGV.delete("--c-parser")
  dir = Gem.path.flat_map { |r| Dir["#{r}/gems/graphql-c_parser-*/lib"] }.first
  $LOAD_PATH.unshift(dir)
  require "graphql/c_parser"
end

Ast = GraphWeaver::SchemaLoader::JoinSource::Ast

def time
  t = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  yield
  (Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - t) * 1000
end

def med(a) = a.sort[a.size / 2]

n = (ARGV[0] || 2000).to_i
reps = (ARGV[1] || 15).to_i

doc = GraphQL.parse(Synth.supergraph(n))
fields = doc.definitions.flat_map { |d| d.respond_to?(:fields) && d.fields ? d.fields : [] }
directives = fields.flat_map(&:directives) +
  doc.definitions.flat_map { |d| d.respond_to?(:directives) && d.directives ? d.directives : [] }

# what a routing table asks of a @join__field / @join__type
ASKS = %w[graph key resolvable isInterfaceObject requires provides override
  external usedOverridden overrideLabel contextArguments].freeze

puts "#{n} types: #{fields.size} fields, #{directives.size} directive applications, #{reps} reps"

printer = Array.new(reps) { GC.start; time { fields.each { |f| f.type.to_query_string } } }
mine = Array.new(reps) { GC.start; time { fields.each { |f| Ast.signature(f.type) } } }

linear = Array.new(reps) do
  GC.start
  time do
    directives.each do |d|
      ASKS.each { |name| d.arguments.find { |a| a.name == name }&.value }
    end
  end
end

hashed = Array.new(reps) do
  GC.start
  time do
    directives.each do |d|
      args = Ast.arguments(d)
      ASKS.each { |name| args[name] }
    end
  end
end

# every @key in the graph, as the table sees them
RT = GraphWeaver::SchemaLoader::RoutingTable
keys = directives.filter_map do |d|
  next unless d.name == "join__type"

  d.arguments.find { |a| a.name == "key" }&.value
end

field_sets = Array.new(reps) { GC.start; time { keys.each { |k| RT.parse_field_set(k) } } }
memo = {}
memoized = Array.new(reps) do
  memo.clear
  GC.start
  time { keys.each { |k| memo[k] ||= RT.parse_field_set(k) } }
end
puts "  (#{keys.size} @key field sets, #{keys.uniq.size} distinct)"

rows = {
  "field sets: parsed each time" => field_sets,
  "field sets: memoized by text" => memoized,
  "signature: to_query_string" => printer,
  "signature: 5-line printer" => mine,
  "args: linear find x#{ASKS.size}" => linear,
  "args: build Hash + lookups" => hashed,
}
Scan = GraphWeaver::SchemaLoader::JoinSource::Scan
sdl = Synth.supergraph(n)
rows["read: GraphQL.parse only"] = Array.new(reps) { GC.start; time { GraphQL.parse(sdl) } }
rows["read: Ast.read (parse+project)"] = Array.new(reps) { GC.start; time { Ast.read(sdl) } }
rows["read: Scan.read (text only)"] = Array.new(reps) { GC.start; time { Scan.read(sdl) } }

rows.each { |label, s| puts format("  %-32s %8.1f ms (min %.1f)", label, med(s), s.min) }
puts format("  %-32s %8.1f ms", "saved by the 5-line printer", med(printer) - med(mine))
puts format("  %-32s %8.1f ms", "saved by the argument Hash", med(linear) - med(hashed))
