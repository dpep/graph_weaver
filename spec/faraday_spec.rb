require "graph_weaver/faraday_executor"
require_relative "generated/person_query"

describe GraphWeaver::FaradayExecutor do
  include_context "graphql http server"

  it "builds a default connection from a url" do
    executor = described_class.new(url)
    result = PersonQuery.execute(id: "1", executor:)

    expect(result.person&.name).to eq "Daniel"
    expect(result.person&.birthday).to eq Date.new(1990, 6, 15)
  end

  it "accepts an existing Faraday connection" do
    connection = Faraday.new(url:, headers: { "X-Client" => "custom" })
    executor = described_class.new(connection)

    expect(PersonQuery.execute(id: "1", executor:).person&.name).to eq "Daniel"
    expect(@requests.last[:headers]["x-client"]).to eq ["custom"]
  end

  it "lets callers add middleware while building" do
    executor = described_class.new(url) do |conn|
      conn.request :authorization, "Bearer", "t0ken"
    end

    PersonQuery.execute(id: "1", executor:)
    expect(@requests.last[:headers]["authorization"]).to eq ["Bearer t0ken"]
  end

  it "surfaces transport errors" do
    executor = described_class.new("http://127.0.0.1:#{@port}/nope")

    expect { PersonQuery.execute(id: "1", executor:) }.to raise_error(/HTTP 404/)
  end
end
