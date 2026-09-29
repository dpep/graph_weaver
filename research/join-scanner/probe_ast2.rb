# frozen_string_literal: true

require_relative "../../lib/graph_weaver"

SDL = <<~SDL
  type Empty @join__type(graph: A)
  type Body @join__type(graph: A) { a: Int }
  enum E @join__type(graph: A) { X }
  union U @join__type(graph: A) = Body
  input I @join__type(graph: A) { a: Int = 3 }
  interface Iface @join__type(graph: A) { a: Int }
  scalar S @join__type(graph: A)
SDL

doc = GraphQL.parse(SDL)
doc.definitions.each do |d|
  puts format("%-28s fields?=%-5s fields=%-18s interfaces=%s types=%s",
    d.class.name.split("::").last,
    d.respond_to?(:fields),
    d.respond_to?(:fields) ? d.fields.inspect[0, 16] : "-",
    d.respond_to?(:interfaces) ? d.interfaces.map(&:name).inspect : "-",
    d.respond_to?(:types) ? d.types.map(&:name).inspect : "-")
end

puts
# what does the argument reader return for each value kind?
d2 = GraphQL.parse(<<~S).definitions.first
  type T @x(s: "str", i: 1, f: 1.5, b: true, n: null, e: ENUMV, l: [1, "a"], o: { k: "v" })
S
d2.directives.first.arguments.each do |a|
  puts format("  %-3s %-46s %p", a.name, a.value.class, a.value.is_a?(GraphQL::Language::Nodes::Enum) ? a.value.name : a.value)
end

puts
puts "block string as arg value:"
blocky = "type T @x(s: \"\"\"\n  hi ( there\n  \"\"\")  { a: Int }"
d3 = GraphQL.parse(blocky).definitions.first
puts d3.directives.first.arguments.first.value.inspect

puts
puts "escapes:"
d4 = GraphQL.parse(%(type T @x(s: "a\\nb\\u0041")  { a: Int })).definitions.first
puts d4.directives.first.arguments.first.value.inspect
