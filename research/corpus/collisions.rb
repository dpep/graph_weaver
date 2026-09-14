# Every static refusal the corpus could trigger, counted: enum values that
# differ only in case (one T::Enum constant), fields that underscore onto one
# prop, and type names that camelize onto a generated constant.
$LOAD_PATH.unshift("/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib")
require "graph_weaver"

CG = GraphWeaver::Codegen
RESERVED_CONSTANTS = %w[Result QUERY Representations].freeze

enum_case = []
prop_collisions = []
constant_collisions = []
kwarg_collisions = []

ARGV.each do |path|
  label = File.basename(path).sub(/\.(json|graphql)\z/, "")
  schema = GraphWeaver::SchemaLoader.load(path)

  schema.types.each_value do |type|
    next if type.graphql_name.start_with?("__")

    camel = GraphWeaver::Inflect.camelize(GraphWeaver::Inflect.underscore(type.graphql_name))
    kind = type.kind.name
    if RESERVED_CONSTANTS.include?(camel) && %w[ENUM INPUT_OBJECT].include?(kind)
      constant_collisions << "#{label} #{kind.downcase} #{type.graphql_name}"
    end

    case kind
    when "ENUM"
      by_constant = type.values.keys.group_by { |v| GraphWeaver::Inflect.camelize(v.downcase) }
      by_constant.each_value do |names|
        enum_case << "#{label} #{type.graphql_name}: #{names.join(", ")}" if names.size > 1
      end
    when "OBJECT", "INTERFACE"
      by_prop = type.fields.keys.group_by { |f| CG.prop_name(f) }
      by_prop.each { |prop, names| prop_collisions << "#{label} #{type.graphql_name} -> #{prop}: #{names.join(", ")}" if names.size > 1 }
      type.fields.each_value do |field|
        args = field.arguments.keys.group_by { |a| CG.prop_name(a) }
        args.each { |prop, names| prop_collisions << "#{label} #{type.graphql_name}.#{field.graphql_name}(#{prop}): #{names.join(", ")}" if names.size > 1 }
        field.arguments.each_key do |arg|
          kwarg_collisions << "#{label} #{type.graphql_name}.#{field.graphql_name}(#{arg}:)" if %w[client variables].include?(GraphWeaver::Inflect.underscore(arg))
        end
      end
    when "INPUT_OBJECT"
      by_prop = type.arguments.keys.group_by { |a| CG.prop_name(a) }
      by_prop.each { |prop, names| prop_collisions << "#{label} input #{type.graphql_name} -> #{prop}: #{names.join(", ")}" if names.size > 1 }
    end
  end
end

{
  "enum values that differ only in case" => enum_case,
  "fields/arguments that underscore onto one prop" => prop_collisions,
  "enum or input type names that camelize onto a generated constant" => constant_collisions,
  "arguments named client/variables" => kwarg_collisions,
}.each do |what, list|
  puts "\n== #{what}: #{list.size}"
  list.first(30).each { |line| puts "    #{line}" }
  puts "    … #{list.size - 30} more" if list.size > 30
end
