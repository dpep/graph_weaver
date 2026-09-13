# typed: false
require_relative "generated/find_pets_query"

# A generated enum is a plain T::Enum, which is what makes it interchangeable
# with the app's own — including how it compares. `species == "CAT"` is the one
# misuse nothing here catches, and sorbet-runtime owns both the behavior and
# the knob that flags it; docs/generated_modules.md points at this.
describe "a generated T::Enum compared with a wire string" do
  let(:species) do
    FindPetsQuery::Result.from_h("findPets" => [{ "name" => "Nibbler", "species" => "CAT" }])
      .find_pets.first.species
  end

  it "answers false, as any T::Enum does" do
    expect(species).to eq GraphQLTypes::Species::Cat
    expect(species == "CAT").to be false
    expect(species.serialize).to eq "CAT"
  end

  # the one line an app adds to be told, in its own dev/test boot
  it "reaches the soft assert handler in legacy migration mode" do
    reported = []
    T::Configuration.enable_legacy_t_enum_migration_mode
    T::Configuration.soft_assert_handler = ->(message, extra) { reported << [message, extra[:storytime]] }

    expect(species == "CAT").to be true

    message, storytime = reported.first
    expect(message).to include "Enum to string comparison not allowed"
    expect(storytime[:class]).to eq "GraphQLTypes::Species"
    expect(storytime[:other]).to eq "CAT"
  ensure
    T::Configuration.disable_legacy_t_enum_migration_mode
    T::Configuration.soft_assert_handler = nil
  end
end
