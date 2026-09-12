# typed: ignore — deliberate bad method names
require_relative "generated/person_query"

describe GraphWeaver::Hints do
  let(:person) do
    PersonQuery::Result.from_h("person" => { "id" => "1", "name" => "Daniel", "pets" => [] }).person
  end

  it "hints at the prop that does exist when a near-miss is actually called" do
    expect { person.nmae }.to raise_error(NoMethodError, /did you mean 'name'\?/)
  end

  # respond_to? is a question about the object's shape, and the hint is an
  # answer about a call that was actually made. Saying true here broke the
  # standard guard — `obj.pet if obj.respond_to?(:pet)` raised on the near
  # miss — which costs more than `#method(:nmae)` raising a bare NameError.
  it "answers respond_to? about the props that exist, and nothing else" do
    expect(person.respond_to?(:name)).to be true
    expect(person.respond_to?(:nmae)).to be false
    expect(person.respond_to?(:utterly_unrelated)).to be false

    guarded = person.nmae if person.respond_to?(:nmae)
    expect(guarded).to be_nil
  end
end
