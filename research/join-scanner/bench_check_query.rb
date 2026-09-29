# frozen_string_literal: true

# What one `check_query` costs on a federated dump, and how much of it is the
# routing table being rebuilt from the file each call.
require_relative "../../lib/graph_weaver"
require_relative "synth"
require "tmpdir"

Loader = GraphWeaver::SchemaLoader

def time
  t = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  yield
  (Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - t) * 1000
end

n = (ARGV[0] || 2000).to_i

Dir.mktmpdir("cq") do |dir|
  path = File.join(dir, "supergraph.graphql")
  File.write(path, Synth.supergraph(n))

  client = GraphWeaver::Client.new(path)
  query = "query { type0(id: \"1\") { id field0 } }"
  client.check_query(query) # warm

  [1, 2, 4].each do |calls|
    GC.start
    total = time { calls.times { client.check_query(query) } }
    puts format("%d check_query calls: %7.0f ms  (%.0f ms each)", calls, total, total / calls)
  end

  GC.start
  table_only = time { Loader.routing_table(path) }
  read_only = time { File.read(path) }
  puts format("one routing_table:   %7.0f ms", table_only)
  puts format("one File.read:       %7.1f ms", read_only)
end
