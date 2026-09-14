# Split a multi-operation GraphQL document into one file per operation, each
# carrying the transitive closure of the fragments it spreads — the shape
# bin/round-trip -q expects (one file, one operation, no unused fragments).
#
#   split_ops.rb <document.graphql> <outdir> [limit]
require "graphql"

src, outdir, limit = ARGV
limit = (limit || 200).to_i
require "fileutils"
::FileUtils.mkdir_p(outdir)

doc = GraphQL.parse(File.read(src))
fragments = doc.definitions.grep(GraphQL::Language::Nodes::FragmentDefinition).to_h { |f| [f.name, f] }
operations = doc.definitions.grep(GraphQL::Language::Nodes::OperationDefinition)

def spreads(node, found = [])
  node.children.each do |child|
    found << child.name if child.is_a?(GraphQL::Language::Nodes::FragmentSpread)
    spreads(child, found)
  end
  found
end

closure = lambda do |node, seen|
  spreads(node).each do |name|
    next if seen.include?(name) || !$fragments.key?(name)

    seen << name
    closure.call($fragments[name], seen)
  end
  seen
end
$fragments = fragments

written = 0
operations.each do |op|
  break if written >= limit
  next unless op.name

  needed = closure.call(op, [])
  text = ([op] + needed.map { |n| fragments[n] }).map(&:to_query_string).join("\n\n")
  File.write(File.join(outdir, "#{op.name}.graphql"), text)
  written += 1
end
puts "#{written} operations written to #{outdir} (of #{operations.size}, #{fragments.size} fragments)"
