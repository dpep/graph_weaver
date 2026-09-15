# typed: false

# The runtime half of a generated module: the client chain, and the one call
# `execute` makes through it. Generated files here are the real thing
# (spec/generated); these build the bare shape dispatch actually reads — three
# constants — so a behavior isn't pinned to one fixture query.
describe GraphWeaver::QueryModule do
  def query_module(graph: nil, query: "query Q { ok }", operation: "Q", client: nil)
    mod = Module.new { extend GraphWeaver::QueryModule }
    mod.const_set(:QUERY, query)
    mod.const_set(:OPERATION_NAME, operation)
    mod.const_set(:GRAPH, graph) if graph
    # bound the way GraphWeaver.parse binds a parsed module — there is no
    # setter an app can reach
    mod.send(:client=, client) if client
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
      mod = query_module(client: recorder)

      mod.send(:dispatch, {}, client: per_call)

      expect(per_call.calls.size).to eq 1
      expect(mod.client.calls).to be_empty
    end

    it "falls back to the module's client when the call names none" do
      mod = query_module(client: recorder)

      mod.send(:dispatch, {}, client: nil)

      expect(mod.client.calls.size).to eq 1
    end

    it "names the contract when the client can't execute" do
      expect { query_module.send(:dispatch, {}, client: Object.new) }
        .to raise_error(GraphWeaver::Error, /client must respond to #execute/)
    end

    # plumbing, like the constants it reads: generated code is the only
    # caller, and a generated module offers execute/from_response, not this
    it "stays private, so it isn't a method every generated module offers" do
      expect(query_module).not_to respond_to(:dispatch)
    end
  end

  # The graph is a label on the request a dispatch makes, and only on that
  # one — see docs/logging.md. Asserted through the payload, since the
  # instrumenter is the only thing that reads it.
  describe "the graph it labels a request with" do
    let(:events) { [] }

    around do |example|
      GraphWeaver.instrumenter = lambda do |event, payload, &block|
        events << payload
        block.call
      end
      example.run
    ensure
      GraphWeaver.instrumenter = nil
    end

    # what a transport does: one instrumented request, which may reach a
    # server that does more work inside it
    def instrumented_client(&inside)
      Class.new do
        define_method(:execute) do |_query, variables: {}, operation_name: nil|
          payload = { operation: operation_name, client: self.class }
          GraphWeaver::Internal::Log.instrument(GraphWeaver::EXECUTE_EVENT, payload) do
            inside&.call
            { "data" => {} }
          end
        end
      end.new
    end

    it "labels the request with the graph the module was generated from" do
      query_module(graph: :billing).send(:dispatch, {}, client: instrumented_client)

      expect(events.map { |p| p[:graph] }).to eq [:billing]
    end

    it "labels a module that declares no graph with nil rather than a guess" do
      query_module.send(:dispatch, {}, client: instrumented_client)

      expect(events.first).to include(graph: nil)
    end

    # the resolver serving a billing query calls some other API: that request
    # is its own, and :billing on it would be a wrong label
    it "does not leak the label into a request made while the first is served" do
      inner = instrumented_client
      query_module(graph: :billing)
        .send(:dispatch, {}, client: instrumented_client { inner.execute("query { x }") })

      expect(events.map { |p| p[:graph] }).to eq [:billing, nil]
    end

    it "labels a nested dispatch with its own graph, and restores the outer" do
      nested = query_module(graph: :catalog)
      outer = instrumented_client { nested.send(:dispatch, {}, client: instrumented_client) }
      after = instrumented_client

      query_module(graph: :billing).send(:dispatch, {}, client: outer)
      query_module(graph: :billing).send(:dispatch, {}, client: after)

      expect(events.map { |p| p[:graph] }).to eq %i[billing catalog billing]
    end

    it "leaves nothing behind when the request raises" do
      boom = Class.new { def execute(*, **) = raise(GraphWeaver::Error, "nope") }.new
      mod = query_module(graph: :billing)

      expect { mod.send(:dispatch, {}, client: boom) }.to raise_error(GraphWeaver::Error)

      query_module.send(:dispatch, {}, client: instrumented_client)
      expect(events.map { |p| p[:graph] }).to eq [nil]
    end
  end
end
