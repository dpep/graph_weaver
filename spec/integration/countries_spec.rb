# Manual integration checks against the public Countries GraphQL API
# (https://countries.trevorblades.com — no auth needed). Run with:
#
#   make integration
describe "Countries API", :integration do
  let(:executor) { GraphWeaver::HttpExecutor.new("https://countries.trevorblades.com/") }

  let(:schema) do
    INTEGRATION_SCHEMAS[:countries] ||= GraphWeaver::SchemaLoader.introspect(executor)
  end

  it "introspects the schema and runs a typed query with variables" do
    country_query = GraphWeaver.parse(
      schema:,
      executor:,
      query: <<~GRAPHQL,
        query($code: ID!) {
          country(code: $code) {
            name
            capital
            emoji
            continent { name }
          }
        }
      GRAPHQL
    )

    country = country_query.execute!(code: "JP").country

    expect(country&.name).to eq "Japan"
    expect(country&.capital).to eq "Tokyo"
    expect(country&.continent&.name).to eq "Asia"
  end

  it "handles lists and one-shot execution" do
    result = GraphWeaver.execute(
      schema:,
      executor:,
      query: "query { continents { name } }",
    )

    expect(result.data!.continents.map(&:name)).to include("Africa", "Europe", "Oceania")
  end
end
