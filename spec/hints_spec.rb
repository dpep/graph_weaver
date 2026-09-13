# typed: ignore — deliberate bad method names
require_relative "generated/person_query"

describe GraphWeaver::Hints do
  let(:person) do
    PersonQuery::Result.from_h("person" => { "id" => "1", "name" => "Daniel", "pets" => [] }).person
  end

  it "hints at the prop that does exist when a near-miss is actually called" do
    expect { person.nmae }.to raise_error(NoMethodError, /did you mean 'name'\?/)
  end

  # a name that resembles nothing is not this module's business: inventing
  # "did you mean ''?" for it is worse than Ruby's own answer
  it "leaves a name that resembles no prop to Ruby's own NoMethodError" do
    expect { person.utterly_unrelated }.to raise_error(NoMethodError) { |error|
      expect(error.message).not_to include "did you mean"
    }
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

  # A server that changed a field's shape is the drift this library exists to
  # catch, and sorbet checks the child's `data` parameter in the CALLER's
  # frame — so the parent brands the error, and nothing in the message says
  # which key. `pets` as an object is worse still: Hash#map has already turned
  # it into pairs, so sorbet reports a list of strings the server never sent.
  describe "a response whose shape drifted" do
    def cast(pets)
      PersonQuery::Result.from_h("person" => { "id" => "1", "name" => "Daniel", "pets" => pets })
    end

    it "names the key and what the server actually sent, for an object where a list belongs" do
      expect { cast({ "id" => "p1" }) }
        .to raise_error(GraphWeaver::CastError, /pets: expected a list, but the server sent an object/)
    end

    it "names the element for a null inside a list of objects" do
      expect { cast([nil]) }
        .to raise_error(GraphWeaver::CastError, /pets\.0: expected an object, but the server sent null/)
    end

    it "names the element for a scalar inside a list of objects" do
      expect { cast(["p1"]) }
        .to raise_error(GraphWeaver::CastError, /pets\.0: expected an object, but the server sent a string/)
    end

    # What arrived, named as JSON names it — sorbet reports the Ruby type of
    # whatever the cast had half-built by then, which is a different thing.
    it "names what arrived in the wire's vocabulary, whatever it was" do
      expect { cast(5) }.to raise_error(GraphWeaver::CastError, /pets: .*sent a number/)
      expect { cast(true) }.to raise_error(GraphWeaver::CastError, /pets: .*sent a boolean/)
      # nothing on the wire is a Symbol, so JSON has no word for it: say Ruby's
      expect { cast(:nope) }.to raise_error(GraphWeaver::CastError, /pets: .*sent a Symbol/)
      expect { PersonQuery::Result.from_h("person" => []) }
        .to raise_error(GraphWeaver::CastError, /person: expected an object, but the server sent a list/)
    end
  end
end
