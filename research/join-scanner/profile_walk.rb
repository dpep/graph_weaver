# frozen_string_literal: true

# Break the post-parse walk down: stackprof over RoutingTable.new on a
# pre-parsed document is not possible (it parses internally), so profile
# routing_table itself and read the frames.
require_relative "../../lib/graph_weaver"
require_relative "synth"
require "tmpdir"

def load_stackprof!
  require "stackprof"
rescue LoadError
  dir = Gem.path.flat_map { |root| Dir["#{root}/gems/stackprof-*/lib"] }
    .max_by { |p| Gem::Version.new(p[%r{stackprof-([\d.]+)/lib\z}, 1]) }
  abort "needs stackprof: gem install stackprof" unless dir

  $LOAD_PATH.unshift(dir)
  require "stackprof"
end

load_stackprof!
Loader = GraphWeaver::SchemaLoader
n = (ARGV[0] || 2000).to_i

Dir.mktmpdir("prof") do |dir|
  path = File.join(dir, "s.graphql")
  File.write(path, Synth.supergraph(n))
  Loader.routing_table(path) # warm
  result = StackProf.run(mode: :wall, interval: 200) { 5.times { Loader.routing_table(path) } }
  puts "top frames (wall, 5 routing_table at #{n} types)"
  StackProf::Report.new(result).print_text(false, 22)
end
