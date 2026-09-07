# typed: ignore — Faker is a development dependency sorbet doesn't see
# frozen_string_literal: true

require "time"
require "faker"

require "graph_weaver/testing"

# The value engine behind FakeClient and Cassette#anonymize!. Its two jobs are
# routing a field name to the right generator and returning something the
# generated struct can actually hold — a wrong Ruby class here surfaces as a
# TypeError from sorbet-runtime in someone else's spec, a long way from here.
describe GraphWeaver::Testing::Values do
  subject(:values) { described_class.new(seed: 3) }

  describe "field-name semantics" do
    # The table is scanned in order and the FIRST match wins, so `last_name`
    # reaching Faker::Name.name instead is a reordering away — and the result
    # still looks like a plausible name, which is why it needs pinning by the
    # generator called rather than by the shape of what comes back.
    before do
      {
        Faker::Internet => %i[email url],
        Faker::Name => %i[first_name last_name name],
        Faker::PhoneNumber => %i[phone_number],
        Faker::Address => %i[full_address city],
      }.each do |namespace, generators|
        generators.each do |generator|
          allow(namespace).to receive(generator).and_return("#{namespace}.#{generator}")
        end
      end
      allow(Faker::Lorem).to receive(:sentence).and_return("Faker::Lorem.sentence")
    end

    {
      "email" => "Faker::Internet.email",
      "contactEmail" => "Faker::Internet.email",
      "firstName" => "Faker::Name.first_name",
      "lastName" => "Faker::Name.last_name",
      "name" => "Faker::Name.name",
      "fullName" => "Faker::Name.name",
      "website" => "Faker::Internet.url",
      "link" => "Faker::Internet.url",
      "phoneNumber" => "Faker::PhoneNumber.phone_number",
      "address" => "Faker::Address.full_address",
      "city" => "Faker::Address.city",
      "title" => "Faker::Lorem.sentence",
      "description" => "Faker::Lorem.sentence",
    }.each do |field, generator|
      it "routes #{field} to #{generator}" do
        expect(values.scalar("String", field)).to eq generator
      end
    end

    it "leaves a name-shaped field that isn't one alone" do
      expect(values.scalar("String", "username")).to match(/\Ausername-\d+\z/)
      expect(values.scalar("String", "nameplate")).to match(/\Anameplate-\d+\z/)
    end
  end

  describe "numbers" do
    # generated as `const :count, Float` when the schema says Float — an
    # Integer there is a TypeError out of sorbet-runtime, not a wrong value
    it "keeps a semantic number the type the schema declared" do
      expect(values.scalar("Float", "count")).to be_a Float
      expect(values.scalar("Int", "price")).to be_an Integer
      expect(values.scalar("Int", "year")).to be_between(1970, 2030)
    end

    # ±90 would be latitude's range copy-pasted
    it "gives longitude its own range" do
      draws = Array.new(50) { values.scalar("Float", "longitude") }

      expect(draws).to all(be_between(-180, 180))
      expect(draws.map(&:abs).max).to be > 90
    end
  end

  describe "mode: :literal" do
    subject(:values) { described_class.new(seed: 3, mode: :literal) }

    # every one of these is cast by generated code, so the value has to be
    # something that codec accepts — iso8601 strings, not Date/Time objects
    it "gives each built-in scalar a value its generated struct can cast" do
      expect(values.scalar("ID", "id")).to match(/\A\d+\z/)
      expect(values.scalar("Int", "rank")).to be_an Integer
      expect(values.scalar("Float", "ratio")).to be_a Float
      expect(values.scalar("Boolean", "active")).to be(true).or be(false)
      expect(Date.iso8601(values.scalar("Date", "bornOn"))).to be_a Date
      %w[DateTime Time ISO8601DateTime].each do |type|
        expect(Time.iso8601(values.scalar(type, "at"))).to be_a Time
      end
    end

    # a fake for a scalar nobody registered is a placeholder; naming the type
    # in it is what tells you which register_scalar is missing
    it "names the type in an unregistered scalar's value" do
      expect(values.scalar("Money", "price")).to match(/\AMoney-\d+\z/)
    end
  end

  describe "mode" do
    it "asks for the gem by name when :faker was requested and isn't there" do
      hide_const("Faker")

      expect { described_class.new(mode: :faker) }
        .to raise_error(ArgumentError, /requires the faker gem \(add it to your Gemfile's test group\)/)
    end

    it "falls back to :literal without complaint when nothing asked for :faker" do
      hide_const("Faker")

      expect(described_class.new(seed: 1).scalar("String", "email")).to match(/\Aemail-\d+\z/)
    end

    it "uses faker when asked for it explicitly" do
      expect(described_class.new(seed: 1, mode: :faker).scalar("String", "email")).to match(/@/)
    end
  end

  # Faker keeps ONE global rng, so a second seeded fake generating a value
  # between two of yours would otherwise walk your sequence forward — two
  # examples sharing a process, and the seed stops meaning anything.
  it "stays deterministic when two seeded instances interleave" do
    mine, theirs = described_class.new(seed: 7), described_class.new(seed: 99)
    interleaved = [mine.scalar("String", "email"), theirs.scalar("String", "email"), mine.scalar("String", "email")]

    alone = described_class.new(seed: 7)

    expect(interleaved.values_at(0, 2)).to eq [alone.scalar("String", "email"), alone.scalar("String", "email")]
  end
end
