require "graph_weaver/testing"
require_relative "generated/find_pets_query"

# JSON.generate renders anything it doesn't know as the value's #to_s — right
# for a Date, a memory address for a File. The refusal used to sit in the
# transport, so the same call was wire corruption over HTTP and a silent
# success under `graphql: :in_process` or `:fake`, which is where a suite
# proves an upload works. It now sits where every mode passes: the dispatch a
# generated module makes, before any client is even chosen.
describe "a variable with no JSON form" do
  include_context "raw http server"

  let(:file) { File.open(__FILE__) }
  after { file.close }

  # what the four tags put in the client slot; a real socket stands for both
  # `graphql: :wire` (the same transport, stubbed) and a live endpoint
  def clients
    {
      in_process: GraphWeaver::InProcess.new(Demo::Schema),
      fake: GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1),
      wire: GraphWeaver::Transport::HTTP.new(serving { |socket| socket.write(http_response(200, "{}")) }),
    }
  end

  it "is refused with the same sentence whichever client would have carried it" do
    messages = clients.transform_values do |client|
      FindPetsQuery.execute(client:, where: { metadata: file })
      nil
    rescue GraphWeaver::Error => e
      e.message
    end

    expect(messages.values.uniq.size).to eq 1
    expect(messages[:in_process]).to eq(
      "$where.metadata is a File — graph_weaver posts application/json and doesn't implement " \
      "the GraphQL multipart request spec, so a file can't ride along; send what the server " \
      "expects as JSON, or POST the upload with your own transport",
    )
    expect(raw_requests).to be_empty # refused before anything was sent
  end

  # the value that never said what it is — the memory address is the point
  it "refuses an object JSON would render as its debug form, in every mode" do
    anonymous = Class.new.new

    clients.each_value do |client|
      expect { FindPetsQuery.execute(client:, where: { metadata: anonymous }) }
        .to raise_error(GraphWeaver::Error, /\$where\.metadata is a #<Class.*>, which has no JSON form/)
    end
  end
end
