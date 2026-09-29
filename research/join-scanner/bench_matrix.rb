# frozen_string_literal: true

# Both readers under both parsers, interleaved in ONE process. This box runs
# other lanes' benchmarks; only a within-process comparison is trustworthy,
# and only CPU time — wall clock here measures the scheduler.
#
#   bundle exec ruby research/join-scanner/bench_matrix.rb [SIZES] [REPS] [--describe]
describe = !ARGV.delete("--describe").nil?

dir = Gem.path.flat_map { |r| Dir["#{r}/gems/graphql-c_parser-*/lib"] }.first
abort "needs `gem install graphql-c_parser`" unless dir

$LOAD_PATH.unshift(dir)
require_relative "../../lib/graph_weaver"
require "graphql/c_parser"
require_relative "synth"

RUBY_PARSER = GraphQL::Language::Parser
C_PARSER = GraphQL::CParser
RT = GraphWeaver::SchemaLoader::RoutingTable

DESCRIPTION = <<~TEXT
  """
  A domain object in the composed graph. Descriptions travel from the
  subgraph SDL into the supergraph verbatim, which is why a real composed
  artifact is mostly prose by byte count.
  """
TEXT

def describe(sdl)
  sdl.gsub(/^type (\w+)/) { "#{DESCRIPTION}type #{$1}" }
    .gsub(/^  (field\d):/) { "  \"What #{$1} is for, said at some length so the byte counts are realistic.\"\n  #{$1}:" }
end

def time
  t = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  yield
  (Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - t) * 1000
end

def med(a) = a.sort[a.size / 2]
def ms(v) = v < 100 ? format("%.1f", v) : v.round.to_s

reps = (ARGV[1] || 11).to_i

(ARGV[0] || "500,2000").split(",").map(&:to_i).each do |n|
  sdl = Synth.supergraph(n)
  sdl = describe(sdl) if describe

  cells = { %i[ruby ast] => [], %i[ruby scan] => [], %i[c ast] => [], %i[c scan] => [] }
  cells.each_key { |(p, r)| GraphQL.default_parser = (p == :c ? C_PARSER : RUBY_PARSER); RT.new(sdl, reader: r) }

  reps.times do
    cells.each do |(parser, reader), samples|
      GraphQL.default_parser = (parser == :c ? C_PARSER : RUBY_PARSER)
      GC.start
      samples << time { RT.new(sdl, reader:) }
    end
  end

  puts
  puts "#{n} types#{" + descriptions" if describe} — #{sdl.bytesize / 1024} KB, #{reps} reps, " \
    "load #{`uptime`[/averages?: *([\d.]+)/, 1]}"
  puts format("  %-14s %10s %10s %10s", "", ":ast", ":scan", "scan wins")
  %i[ruby c].each do |parser|
    a = med(cells[[parser, :ast]])
    s = med(cells[[parser, :scan]])
    puts format("  %-14s %10s %10s %9.2fx", "#{parser} parser", ms(a), ms(s), a / s)
  end
  ruby_ast = med(cells[%i[ruby ast]])
  puts format("  %-14s %9.2fx", "c parser wins", ruby_ast / med(cells[%i[c ast]]))
end
