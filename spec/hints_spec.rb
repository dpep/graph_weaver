# typed: ignore — deliberate bad method names
require_relative "generated/person_query"

describe GraphWeaver::Hints do
  let(:person) do
    PersonQuery::Result.from_h("person" => { "id" => "1", "name" => "Daniel", "pets" => [] }).person
  end

  it "answers respond_to? the way method_missing behaves" do
    expect(person.respond_to?(:name)).to be true
    expect(person.respond_to?(:nmae)).to be true      # method_missing hints on this one
    expect(person.respond_to?(:utterly_unrelated)).to be false
  end

  # the point of the predicate: #method used to raise a bare NameError while
  # the same call through method_missing got the hint
  it "routes #method to the same hint" do
    expect { person.method(:nmae).call }.to raise_error(NoMethodError, /did you mean 'name'\?/)
    expect { person.method(:utterly_unrelated) }.to raise_error(NameError)
  end
end
