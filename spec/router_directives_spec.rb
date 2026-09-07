# typed: ignore

require "graph_weaver/testing"

# @skip/@include are evaluated where the variables are, so the values in hand
# have to be the ones graphql-ruby would use — including the defaults the
# operation declares for variables the caller didn't pass.
describe GraphWeaver::Testing::Router do
  subject(:router) do
    described_class.new(supergraph: RouterGraph::SUPERGRAPH, subgraphs: RouterGraph::SUBGRAPHS)
  end

  let(:included) { 'query($show: Boolean = true) { me { username reviews @include(if: $show) { body } } }' }

  it "applies a variable's declared default when the caller passes none" do
    expect(router.execute(included, variables: {}))
      .to eq router.execute(included, variables: { "show" => true })
    expect(router.execute(included, variables: {}).dig("data", "me", "reviews")).to be_an Array
  end

  it "still lets an explicit value beat the default" do
    expect(router.execute(included, variables: { "show" => false }))
      .to eq({ "data" => { "me" => { "username" => "dpep" } } })
  end

  it "applies a @skip default too" do
    skipped = 'query($hide: Boolean = true) { me { username reviews @skip(if: $hide) { body } } }'

    expect(router.execute(skipped, variables: {}))
      .to eq({ "data" => { "me" => { "username" => "dpep" } } })
  end
end
