require "tmpdir"



# Both formats a remote service can hand you — introspection JSON or SDL —
# load into schemas that generate byte-identical output to the live class.
describe GraphWeaver::SchemaLoader do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  def codegen_parity(schema)
    root = File.expand_path("..", __dir__)

    %w[add_pet adopt named person search].each do |base|
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

  it "loads raw content: introspection JSON, SDL strings, and Hashes" do
    codegen_parity(described_class.load(Demo::Schema.to_definition))
    codegen_parity(described_class.load(Demo::Schema.as_json))
  end

  it "rejects other formats" do
    expect { described_class.load("schema.yaml") }.to raise_error(ArgumentError)
    expect { described_class.load("not a schema at all") }.to raise_error(ArgumentError)
  end

  describe ".introspect" do
    # counts how many introspections actually hit the "network"
    let(:counting_executor) do
      Class.new do
        attr_reader :calls

        def initialize
          @calls = 0
        end

        def execute(query, variables:)
          @calls += 1
          Demo::Schema.execute(query, variables:)
        end
      end.new
    end

    it "fetches a schema through an executor" do
      # a schema class is itself an executor, so this exercises the same
      # path a live HTTP endpoint would
      codegen_parity(described_class.introspect(Demo::Schema))
    end

    it "round-trips schemas through their own to_json for external caches" do
      # the Rails.cache pattern: introspect(...).to_json, then load
      schema = described_class.introspect(Demo::Schema)

      codegen_parity(described_class.load(schema.to_json))
    end

    it "caches the introspection result to a file" do
      path = File.join(@dir, "schema-cache.json")

      first = described_class.introspect(counting_executor, cache: path)
      second = described_class.introspect(counting_executor, cache: path)

      expect(counting_executor.calls).to eq 1
      expect(File).to exist(path)
      codegen_parity(first)
      codegen_parity(second)
    end

    it "cache: true defaults to GraphWeaver.schema_path" do
      path = File.join(@dir, "schema.json")
      GraphWeaver.schema_path = path

      described_class.introspect(counting_executor, cache: true)
      described_class.introspect(counting_executor, cache: true)

      expect(counting_executor.calls).to eq 1
      expect(File).to exist(path)

      expect {
        described_class.introspect(counting_executor, cache: File.join(@dir, "schema.yaml"))
      }.to raise_error(ArgumentError, /\.json or \.graphql/)
    ensure
      GraphWeaver.schema_path = nil
    end

    it "caches as SDL when the path says .graphql — reviewable dumps" do
      path = File.join(@dir, "schema.graphql")

      first = described_class.introspect(counting_executor, cache: path)
      expect(File.read(path)).to match(/^type Person/m) # SDL, not JSON

      cached = described_class.introspect(counting_executor, cache: path)
      expect(counting_executor.calls).to eq 1
      codegen_parity(first)
      codegen_parity(cached) # SDL round-trip generates identically
    end

    it "refreshes the cache when the ttl has elapsed" do
      path = File.join(@dir, "schema-cache.json")

      described_class.introspect(counting_executor, cache: path, ttl: 60)
      stale = Time.now - 3600
      File.utime(stale, stale, path)
      described_class.introspect(counting_executor, cache: path, ttl: 60)

      expect(counting_executor.calls).to eq 2
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
