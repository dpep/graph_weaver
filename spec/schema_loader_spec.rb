require "tmpdir"
require_relative "../lib/schema_loader"
require_relative "../lib/struct_codegen"

# Both formats a remote service can hand you — introspection JSON or SDL —
# load into schemas that generate byte-identical output to the live class.
describe SchemaLoader do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  def codegen_parity(schema)
    root = File.expand_path("..", __dir__)

    %w[person search].each do |base|
      source = StructCodegen.new(
        schema:,
        executor_const: "Demo::Schema",
        query: File.read(File.join(root, "queries/#{base}.graphql")),
        module_name: "#{base.capitalize}Query",
      ).generate

      expect(source).to eq File.read(File.join(root, "lib/generated/#{base}_query.rb"))
    end
  end

  it "loads an introspection dump (.json)" do
    path = File.join(@dir, "schema.json")
    File.write(path, JSON.generate(Demo::Schema.as_json))

    codegen_parity(described_class.load(path))
  end

  it "loads SDL (.graphql)" do
    path = File.join(@dir, "schema.graphql")
    File.write(path, Demo::Schema.to_definition)

    codegen_parity(described_class.load(path))
  end

  it "rejects other formats" do
    expect { described_class.load("schema.yaml") }.to raise_error(ArgumentError)
  end
end
