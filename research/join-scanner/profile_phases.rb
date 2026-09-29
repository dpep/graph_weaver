# frozen_string_literal: true

# Phase timers inside RoutingTable#initialize, summing to its total.
require_relative "../../lib/graph_weaver"
require_relative "synth"
require "tmpdir"

Loader = GraphWeaver::SchemaLoader
RT = Loader::RoutingTable

TIMES = Hash.new(0.0)

module Probe
  def self.wrap(mod, name)
    orig = mod.instance_method(name)
    mod.define_method(name) do |*a, **k, &b|
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      r = orig.bind(self).call(*a, **k, &b)
      TIMES[name] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
      r
    end
  end
end

%i[read_graphs read_abstracts read_types read_fields read_keys read_possible].each { |m| Probe.wrap(RT, m) }

# parse_field_set is a class method
class << RT
  alias_method :orig_pfs, :parse_field_set
  def parse_field_set(text)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = orig_pfs(text)
    TIMES[:parse_field_set] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
    r
  end
end

# signatures: time to_query_string separately
module GraphQL::Language::Nodes
  class AbstractNode
    alias_method :orig_tqs, :to_query_string
    def to_query_string(*a, **k)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      r = orig_tqs(*a, **k)
      TIMES[:to_query_string] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
      r
    end
  end
end

n = (ARGV[0] || 2000).to_i
Dir.mktmpdir("ph") do |dir|
  path = File.join(dir, "s.graphql")
  File.write(path, Synth.supergraph(n))
  sdl = File.read(path)
  Loader.routing_table(path) # warm
  TIMES.clear

  reps = 5
  parse_ms = []
  total_ms = []
  reps.times do
    GC.start
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    GraphQL.parse(sdl)
    parse_ms << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Loader.routing_table(path)
    total_ms << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
  end

  puts "#{n} types, #{reps} reps — mean ms per routing_table call"
  puts format("  %-22s %8.1f", "GraphQL.parse (alone)", parse_ms.sum / reps)
  puts format("  %-22s %8.1f", "routing_table TOTAL", total_ms.sum / reps)
  puts "  --- inside (nested, so they overlap) ---"
  TIMES.sort_by { |_, v| -v }.each { |k, v| puts format("  %-22s %8.1f", k, v / reps) }
end
