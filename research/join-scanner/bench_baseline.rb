# frozen_string_literal: true

# `routing_table` as main has it, measured the same way — load a graph_weaver
# from another checkout.
#
#   bundle exec ruby tmp/exp/bench_baseline.rb LIB_ROOT [-t N] [-r N] [--c-parser]
require "optparse"

options = { sizes: [2000], reps: 9 }
root = ARGV.shift
OptionParser.new do |o|
  o.on("-t N", Integer) { |v| (options[:sizes] = []) << v }
  o.on("-r N", Integer) { |v| options[:reps] = v }
  o.on("--c-parser") { options[:c] = true }
end.parse!

if options[:c]
  dir = Gem.path.flat_map { |r| Dir["#{r}/gems/graphql-c_parser-*/lib"] }.first
  $LOAD_PATH.unshift(dir)
end

require File.join(root, "lib/graph_weaver")
require "graphql/c_parser" if options[:c]
require_relative "synth"

puts "lib:    #{root}"
puts "parser: #{GraphQL.default_parser.name}"

def time
  t = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  yield
  (Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - t) * 1000
end

def med(a) = a.sort[a.size / 2]

RT = GraphWeaver::SchemaLoader::RoutingTable

options[:sizes].each do |n|
  sdl = Synth.supergraph(n)
  RT.new(sdl)
  samples = Array.new(options[:reps]) { GC.start; time { RT.new(sdl) } }
  puts format("%d types: RoutingTable.new  median %.0f ms  min %.0f ms  (load %s)",
    n, med(samples), samples.min, `uptime`[/averages?: *([\d.]+)/, 1])
end
