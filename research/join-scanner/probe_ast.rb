# frozen_string_literal: true

require_relative "../../lib/graph_weaver"

SDL = <<~SDL
  "a description"
  schema @link(url: "https://specs.apollo.dev/link/v1.0") @join__weird { query: Query }
  directive @inaccessible on FIELD_DEFINITION
  directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
  scalar join__FieldSet
  scalar MyScalar @join__type(graph: A)
  enum join__Graph { A @join__graph(name: "a", url: "http://a") }
  type Query @join__type(graph: A) { hi: String }
  extend type Query { bye: String }
  input Inp @join__type(graph: A) { a: Int = 3 }
  union U @join__type(graph: A) @join__unionMember(graph: A, member: "Query") = Query
SDL

doc = GraphQL.parse(SDL)
doc.definitions.each do |d|
  puts format("%-52s name=%-18s dirs=%-3s fields=%s",
    d.class.name.split("::").last,
    d.respond_to?(:name) ? d.name.inspect : "-",
    d.respond_to?(:directives) ? d.directives.size : "-",
    d.respond_to?(:fields) ? (d.fields ? d.fields.size : "nil") : "-")
end

t = GraphWeaver::SchemaLoader.routing_table(SDL)
puts
puts "subgraphs:  #{t.subgraphs.inspect}"
puts "types:      #{t.types.inspect}"
puts "unsupported:"
t.unsupported.each { |u| puts "  - #{u}" }
puts "Query fields: #{t.declared_fields('Query').inspect}"
puts "Query sig hi: #{t.signature('Query', 'hi').inspect}"
puts "Inp fields:   #{t.declared_fields('Inp').inspect} sig a=#{t.signature('Inp', 'a').inspect}"
