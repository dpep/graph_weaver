# typed: false

# The runtime half of a generated module: the client chain, and the one call
# `execute` makes through it. Generated files here are the real thing
# (spec/generated); these build the bare shape dispatch actually reads — the
# constants, nothing else — so a behavior isn't pinned to one fixture query.
describe GraphWeaver::QueryModule do
  def query_module(query: "query Q { ok }", operation: "Q")
    mod = Module.new { extend GraphWeaver::QueryModule }
    mod.const_set(:QUERY, query)
    mod.const_set(:OPERATION_NAME, operation)
    mod
  end

  # what every client in the slot answers
  def recorder(response = { "data" => { "ok" => true } })
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }
      define_method(:execute) do |query, variables: {}, operation_name: nil|
        @calls << { query:, variables:, operation_name: }
        response
      end
    end.new
  end

  describe "#dispatch" do
    it "runs the module's own QUERY and OPERATION_NAME through the client" do
      client = recorder
      mod = query_module(query: "query Named { ok }", operation: "Named")

      raw = mod.send(:dispatch, { "id" => "1" }, client:)

      expect(client.calls).to eq [{ query: "query Named { ok }", variables: { "id" => "1" },
                                    operation_name: "Named" }]
      # the raw response, for from_response to wrap
      expect(raw).to eq("data" => { "ok" => true })
    end

    it "prefers the per-call client over the module's" do
      per_call = recorder
      mod = query_module
      mod.client = recorder

      mod.send(:dispatch, {}, client: per_call)

      expect(per_call.calls.size).to eq 1
      expect(mod.client.calls).to be_empty
    end

    it "falls back to the module's client when the call names none" do
      mod = query_module
      mod.client = recorder

      mod.send(:dispatch, {}, client: nil)

      expect(mod.client.calls.size).to eq 1
    end

    it "names the contract when the client can't execute" do
      expect { query_module.send(:dispatch, {}, client: Object.new) }
        .to raise_error(GraphWeaver::Error, /client must respond to #execute/)
    end
  end
end
