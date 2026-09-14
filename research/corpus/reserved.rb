# The three name rules, measured on the corpus.
#
#   prop_name renames  — output fields and input-object fields (they become PROPS)
#   kwarg refusals     — root-field arguments (they become execute KWARGS, which
#                        are refused only for a Ruby keyword or client/variables)
#   constant collisions — type names camelizing onto MODULE_RESERVED
require_relative "/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib/graph_weaver"

CG = GraphWeaver::Codegen
KWARGS = %w[client variables].freeze
KEYWORDS = %w[
  alias and begin break case class def defined? do else elsif end
  ensure false for if in module next nil not or redo rescue retry
  return self super then true undef unless until when while yield
  BEGIN END __FILE__ __LINE__ __ENCODING__
].freeze
MODULE_RESERVED = %w[Result QUERY Representations].freeze

def renamed?(name) = CG.prop_name(name) != GraphWeaver::Inflect.underscore(name)

renamed = Hash.new { |h, k| h[k] = [] }
kwarg_refusals = Hash.new { |h, k| h[k] = [] }
module_hits = []

ARGV.each do |path|
  label = File.basename(path).sub(/\.(json|graphql)\z/, "")
  schema = GraphWeaver::SchemaLoader.load(path)
  roots = [schema.query, schema.mutation].compact.map(&:graphql_name)

  schema.types.each_value do |type|
    next if type.graphql_name.start_with?("__")

    case type.kind.name
    when "OBJECT", "INTERFACE"
      type.fields.each_value do |field|
        prop = CG.prop_name(field.graphql_name)
        renamed[prop] << "#{label} #{type.graphql_name}.#{field.graphql_name}" if renamed?(field.graphql_name)
        next unless roots.include?(type.graphql_name) # only root args become kwargs

        field.arguments.each_value do |arg|
          kwarg = GraphWeaver::Inflect.underscore(arg.graphql_name)
          next unless KEYWORDS.include?(kwarg) || KWARGS.include?(kwarg)

          kwarg_refusals[kwarg] << "#{label} #{type.graphql_name}.#{field.graphql_name}(#{arg.graphql_name}:)"
        end
      end
    when "INPUT_OBJECT"
      type.arguments.each_value do |arg|
        prop = CG.prop_name(arg.graphql_name)
        renamed[prop] << "#{label} input #{type.graphql_name}.#{arg.graphql_name}" if renamed?(arg.graphql_name)
      end
    end

    camel = GraphWeaver::Inflect.camelize(GraphWeaver::Inflect.underscore(type.graphql_name))
    module_hits << "#{label} #{type.kind.name.downcase} #{type.graphql_name}" if MODULE_RESERVED.include?(camel)
  end
end

puts "== prop_name renames: #{renamed.values.sum(&:size)} coordinates, #{renamed.size} props"
renamed.sort_by { |prop, list| [-list.size, prop] }.each do |prop, list|
  puts format("%-14s %3d  %s", prop, list.size, list.join("; "))
end

puts "\n== root arguments a kwarg rule refuses: #{kwarg_refusals.values.sum(&:size)}"
kwarg_refusals.sort_by { |_, list| -list.size }.each do |kwarg, list|
  puts format("%-14s %3d  %s", kwarg, list.size, list.first(8).join("; "))
end

puts "\n== type names camelizing onto a generated constant: #{module_hits.size}"
module_hits.each { |line| puts "    #{line}" }
