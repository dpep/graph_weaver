# frozen_string_literal: true

# Both readers over a corpus, compared field by field.
#
#   bundle exec ruby tmp/exp/equality.rb [extra-supergraph.graphql ...]
require_relative "../../lib/graph_weaver"
require_relative "synth"
require_relative "corpus"

Loader = GraphWeaver::SchemaLoader
RT = Loader::RoutingTable
Scan = Loader::JoinSource::Scan
Ast = Loader::JoinSource::Ast

failures = 0
refusals = []
checked = 0

def diff(a, b, path = "")
  return [] if a == b

  if a.is_a?(Hash) && b.is_a?(Hash)
    (a.keys | b.keys).flat_map { |k| diff(a[k], b[k], "#{path}/#{k}") }
  elsif a.is_a?(Array) && b.is_a?(Array) && a.size == b.size
    a.each_with_index.flat_map { |v, i| diff(v, b[i], "#{path}[#{i}]") }
  else
    ["#{path}: scan=#{a.inspect[0, 120]} ast=#{b.inspect[0, 120]}"]
  end
end

Corpus.each do |label, sdl|
  checked += 1
  reason = +""
  scanned = Scan.read(sdl, reason:)

  if scanned.nil?
    refusals << [label, reason]
    next
  end

  # 1. the source records themselves — sharper than the table, which folds
  #    several records into one answer
  ast_defns = Ast.read(sdl)
  record_diff = diff(scanned.map(&:to_a), ast_defns.map(&:to_a), "defns")

  # 2. the tables
  scan_table = RT.new(sdl, reader: :scan)
  ast_table = RT.new(sdl, reader: :ast)
  table_diff = diff(scan_table.to_h, ast_table.to_h, "table")

  # 3. the signature printer against graphql-ruby's own
  printer_diff = []
  GraphQL.parse(sdl).definitions.each do |defn|
    next unless defn.respond_to?(:fields) && defn.fields

    defn.fields.each do |field|
      mine = Ast.signature(field.type)
      theirs = field.type.to_query_string
      printer_diff << "#{defn.name}.#{field.name}: #{mine} != #{theirs}" if mine != theirs
    end
  end

  problems = record_diff + table_diff + printer_diff
  next if problems.empty?

  failures += 1
  puts "MISMATCH  #{label}"
  problems.first(8).each { |p| puts "    #{p}" }
  puts "    (#{problems.size - 8} more)" if problems.size > 8
end

ARGV.each do |path|
  sdl = File.read(path)
  reason = +""
  scanned = Scan.read(sdl, reason:)
  checked += 1
  if scanned.nil?
    refusals << [path, reason]
    next
  end

  d = diff(RT.new(sdl, reader: :scan).to_h, RT.new(sdl, reader: :ast).to_h, "table")
  next if d.empty?

  failures += 1
  puts "MISMATCH  #{path}"
  d.first(8).each { |p| puts "    #{p}" }
end

puts
puts "checked #{checked} supergraphs, #{failures} mismatched, #{refusals.size} refused"
refusals.each { |label, reason| puts "  refused  #{label}: #{reason}" }
exit(failures.zero? ? 0 : 1)
