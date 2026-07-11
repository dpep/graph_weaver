require "tmpdir"



# Both formats a remote service can hand you — introspection JSON or SDL —
# load into schemas that generate byte-identical output to the live class.
describe GraphWeaver::SchemaLoader do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  def codegen_parity(schema)
    root = File.expand_path("..", __dir__)

    %w[add_pet named person search].each do |base|
      source = GraphWeaver::Codegen.new(
        schema:,
        executor: "Demo::Schema",
        query: File.read(File.join(root, "spec/queries/#{base}.graphql")),
        module_name: "#{base.split("_").map(&:capitalize).join}Query",
      ).generate

      expect(source).to eq File.read(File.join(root, "spec/generated/#{base}_query.rb"))
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

  describe ".introspect" do
    it "fetches a schema through an executor" do
      # a schema class is itself an executor, so this exercises the same
      # path a live HTTP endpoint would
      codegen_parity(described_class.introspect(Demo::Schema))
    end

    it "surfaces introspection failures" do
      failing = Class.new do
        def execute(_query, variables:)
          { "errors" => [{ "message" => "introspection disabled" }] }
        end
      end

      expect {
        described_class.introspect(failing.new)
      }.to raise_error(GraphWeaver::Error, /introspection failed/)
    end
  end
end
