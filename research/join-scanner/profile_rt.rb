# frozen_string_literal: true

# Where does routing_table's time actually go? Phase timers that sum to the
# total, plus counters.
require_relative "../../lib/graph_weaver"
require_relative "synth"
require "tmpdir"

Loader = GraphWeaver::SchemaLoader
RT = Loader::RoutingTable

def time
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = yield
  [(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000, r]
end

def med(a) = a.sort[a.size / 2]

sizes = (ARGV.empty? ? [500, 2000, 8000] : ARGV.map(&:to_i))

Dir.mktmpdir("prof-rt") do |dir|
  sizes.each do |n|
    path = File.join(dir, "s#{n}.graphql")
    File.write(path, Synth.supergraph(n))
    sdl = File.read(path)

    # warm
    Loader.routing_table(path)

    reps = 7
    phases = Hash.new { |h, k| h[k] = [] }
    reps.times do
      GC.start
      t_read, = time { File.read(path) }
      t_fed, = time { Loader.federation_sdl?(sdl) }
      t_parse, doc = time { GraphQL.parse(sdl) }
      t_total, = time { Loader.routing_table(path) }
      phases["File.read"] << t_read
      phases["federation_sdl?"] << t_fed
      phases["GraphQL.parse"] << t_parse
      phases["routing_table TOTAL"] << t_total
      doc = nil # rubocop:disable Lint/UselessAssignment
    end

    puts
    puts "#{n} types — #{File.size(path) / 1024} KB"
    phases.each { |k, v| puts format("  %-24s %8.1f ms", k, med(v)) }
    named = %w[File.read federation_sdl? GraphQL.parse].sum { |k| med(phases[k]) }
    puts format("  %-24s %8.1f ms", "(named)", named)
    puts format("  %-24s %8.1f ms", "post-parse walk", med(phases["routing_table TOTAL"]) - named)

    # counters
    doc = GraphQL.parse(sdl)
    keys = 0
    doc.definitions.each do |d|
      next unless d.respond_to?(:directives) && d.directives

      d.directives.each { |x| keys += 1 if x.name == "join__type" && x.arguments.any? { |a| a.name == "key" } }
    end
    fields = doc.definitions.sum { |d| d.respond_to?(:fields) && d.fields ? d.fields.size : 0 }
    puts format("  counters: definitions=%d fields=%d join__type-with-key=%d", doc.definitions.size, fields, keys)
  end
end
