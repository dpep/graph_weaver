# frozen_string_literal: true

# routing_table, scanner vs parser, interleaved.
#
#   bundle exec ruby tmp/exp/bench_scan.rb [-t N]... [-r REPS] [--describe] [--c-parser]
require "optparse"

options = { sizes: [], reps: 7 }
OptionParser.new do |o|
  o.on("-t N", Integer) { |v| options[:sizes] << v }
  o.on("-r N", Integer) { |v| options[:reps] = v }
  o.on("--describe", "give every type and field a description") { options[:describe] = true }
  o.on("--c-parser", "load graphql-c_parser first") { options[:c] = true }
  o.on("--printer", "signatures via Printer#to_query_string, as main does") { options[:printer] = true }
  o.on("--find-args", "directive arguments by linear find, as main does") { options[:find] = true }
end.parse!

if options[:c]
  dir = Gem.path.flat_map { |root| Dir["#{root}/gems/graphql-c_parser-*/lib"] }
    .max_by { |p| Gem::Version.new(p[%r{graphql-c_parser-([\d.]+)/lib\z}, 1]) }
  abort "--c-parser needs `gem install graphql-c_parser`" unless dir

  $LOAD_PATH.unshift(dir)
end

require_relative "../../lib/graph_weaver"
require "graphql/c_parser" if options[:c]
require_relative "synth"
require "tmpdir"

Loader = GraphWeaver::SchemaLoader
RT = Loader::RoutingTable

parser = GraphQL.default_parser.name
puts "parser: #{parser}#{" +printer" if options[:printer]}#{" +find-args" if options[:find]}"

# Put main's two per-node costs back, one at a time, so the reader refactor
# and the scanner can be told apart.
if options[:printer]
  def (Loader::JoinSource::Ast).signature(node) = node.to_query_string
end

if options[:find]
  # main looks each argument up with a linear `find` over the node's
  # arguments, once per argument it asks for
  class LinearArgs
    def initialize(pairs) = @pairs = pairs
    def [](name) = @pairs.find { |(n, _)| n == name }&.last
    def ==(other) = to_h == (other.respond_to?(:to_h) ? other.to_h : other)
    def to_h = @pairs.to_h
  end

  def (Loader::JoinSource::Ast).arguments(node)
    seen = {}
    pairs = node.arguments.filter_map do |arg|
      next if seen.key?(arg.name)

      seen[arg.name] = true
      [arg.name, value(arg.value)]
    end
    LinearArgs.new(pairs)
  end
end

# Apollo prints the subgraphs' descriptions into the supergraph; the
# synthesizer has none, which is the scanner's best case for the wrong reason.
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

# CPU time, not wall: this box runs other lanes' benchmarks, and wall clock
# on a loaded machine measures the scheduler. CPU time still counts our own
# GC, which is the part that matters here.
def time
  t = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  yield
  (Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - t) * 1000
end

def med(a) = a.sort[a.size / 2]
def ms(v) = v < 10 ? format("%.2f", v) : (v < 100 ? format("%.1f", v) : v.round.to_s)

sizes = options[:sizes].empty? ? [500, 2000, 8000] : options[:sizes]

sizes.each do |n|
  sdl = Synth.supergraph(n)
  sdl = describe(sdl) if options[:describe]

  RT.new(sdl, reader: :scan)
  RT.new(sdl, reader: :ast)
  raise "scanner refused the synthesized graph" unless RT.new(sdl).reader == :scan

  scan = []
  ast = []
  parse = []
  options[:reps].times do
    GC.start
    scan << time { RT.new(sdl, reader: :scan) }
    ast << time { RT.new(sdl, reader: :ast) }
    parse << time { GraphQL.parse(sdl) }
  end

  puts
  puts "#{n} types#{" + descriptions" if options[:describe]} — #{sdl.bytesize / 1024} KB, " \
    "#{options[:reps]} reps, load #{File.read("/proc/loadavg")[/\S+/] rescue `uptime`[/averages?: *([\d.]+)/, 1]}"
  puts format("  %-26s %9s %9s", "", "median", "min")
  [["routing_table (:ast)", ast], ["routing_table (:scan)", scan],
    ["  GraphQL.parse alone", parse]].each do |label, samples|
    puts format("  %-26s %9s %9s", label, ms(med(samples)), ms(samples.min))
  end
  puts format("  %-26s %9s %9s", "speedup (ast/scan)",
    format("%.2fx", med(ast) / med(scan)), format("%.2fx", ast.min / scan.min))
  puts format("  %-26s %9s %9s  ms/1000 types", "marginal",
    ms(med(ast) / n * 1000), ms(scan.min / n * 1000))
end
