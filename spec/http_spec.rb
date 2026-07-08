require_relative "generated/person_query"

# Generated modules run against a remote server by swapping the executor:
# same structs, same casting, HTTP transport.
describe GraphWeaver::HttpExecutor do
  include_context "graphql http server"

  let(:executor) { described_class.new(url) }

  it "runs generated queries over HTTP" do
    result = PersonQuery.execute(id: "1", executor:)
    person = result.person

    expect(person&.name).to eq "Daniel"
    expect(person&.birthday).to eq Date.new(1990, 6, 15)
    expect(person&.pets&.map(&:name)).to eq %w[Shelby Brownie]
  end

  it "surfaces transport errors" do
    bad = described_class.new("http://127.0.0.1:#{@port}/nope")

    expect { PersonQuery.execute(id: "1", executor: bad) }.to raise_error(/HTTP 404/)
  end
end
