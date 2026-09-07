# typed: ignore

require "graph_weaver/testing"
require_relative "support/federation_chain_graph"

# a.w -> b.mid @requires "w" -> c.top @requires "mid", every field set flat.
describe GraphWeaver::Testing::Router do
  subject(:router) do
    described_class.new(supergraph: Chain::SUPERGRAPH, subgraphs: Chain::SUBGRAPHS)
  end

  it "satisfies a one-hop @requires" do
    expect(router.execute('{ thing(id: "t") { mid } }'))
      .to eq({ "data" => { "thing" => { "mid" => 11 } } })
  end

  # A prefetch sends the entity's own @key and nothing else, so the inner
  # requirement never arrives: top used to answer 100 (from a missing mid)
  # while mid answered 11 in the same response.
  it "refuses a @requires that names another @requires field" do
    expect { router.execute('{ thing(id: "t") { top } }') }
      .to refuse_to_plan(:chained_requires)
      .with_detail(a_string_including('Thing.top @requires "mid", and Thing.mid itself @requires "w"'))
  end

  it "refuses it even when the inner field is also selected" do
    expect { router.execute('{ thing(id: "t") { mid top } }') }
      .to refuse_to_plan(:chained_requires)
  end

  # the injected alias is ours; a caller keying on the path gets a real field
  it "reports an error path without the internal alias" do
    result = router.execute('{ thing(id: "bad") { mid } }')

    expect(result.dig("errors", 0, "path")).to eq %w[thing w]
  end
end
