require_relative "../lib/struct_codegen"

# What __type / __schema metadata is available, and can codegen run
# against a schema rebuilt purely from an introspection dump (i.e. a
# remote API we only know via introspection)?
describe "introspection" do
  it "exposes type metadata via __type" do
    result = Demo::Schema.execute(<<~GRAPHQL).to_h
      {
        __type(name: "Person") {
          name
          kind
          fields {
            name
            type { kind name ofType { name } }
          }
        }
      }
    GRAPHQL

    type = result.dig("data", "__type")
    expect(type["kind"]).to eq "OBJECT"
    expect(type["fields"].map { |field| field["name"] }).to include("name", "birthday", "pets")
  end

  it "exposes the union's possible types via __schema" do
    result = Demo::Schema.execute(<<~GRAPHQL).to_h
      {
        __type(name: "SearchResult") {
          kind
          possibleTypes { name }
        }
      }
    GRAPHQL

    type = result.dig("data", "__type")
    expect(type["kind"]).to eq "UNION"
    expect(type["possibleTypes"].map { |t| t["name"] }).to eq %w[Person Pet]
  end

  it "codegen works against a schema rebuilt from an introspection dump" do
    dump = Demo::Schema.as_json
    rebuilt = GraphQL::Schema.from_introspection(dump)

    %w[person search].each do |base|
      source = StructCodegen.new(
        schema: rebuilt,
        executor_const: "Demo::Schema",
        query: File.read(File.expand_path("../queries/#{base}.graphql", __dir__)),
        module_name: "#{base.capitalize}Query",
      ).generate

      checked_in = File.read(File.expand_path("../lib/generated/#{base}_query.rb", __dir__))
      expect(source).to eq checked_in
    end
  end
end
