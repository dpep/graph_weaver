# typed: ignore — Faker is a development dependency sorbet doesn't see
# frozen_string_literal: true

require "time"
require "faker"

require "graph_weaver/testing"

# The value engine behind FakeClient and Cassette#anonymize!. Its two jobs are
# routing a field name to the right generator and returning something the
# generated struct can actually hold — a wrong Ruby class here surfaces as a
# TypeError from sorbet-runtime in someone else's spec, a long way from here.
describe GraphWeaver::Internal::Values do
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

  describe "values: :literal" do
    subject(:values) { described_class.new(seed: 3, values: :literal) }

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

  # A custom scalar is registered so codegen emits a codec for it, and the
  # fake's value has to survive that codec. Keyed off the name alone, a
  # `Timestamp` registered as Time got "Timestamp-1" and every fake response
  # touching it died in Time.iso8601 — the one promise the harness makes.
  describe "a registered custom scalar" do
    subject(:values) { described_class.new(seed: 3, values: :literal) }

    after { GraphWeaver::Codegen.reset_scalars! }

    it "fabricates for the Ruby type it deserializes into, not its name" do
      GraphWeaver.register_scalar("Timestamp", Time, cast: :iso8601, serialize: :iso8601, requires: "time")
      GraphWeaver.register_scalar("Ticks", Integer)
      GraphWeaver.register_scalar("Slug", String)

      expect(Time.iso8601(values.scalar("Timestamp", "at"))).to be_a Time
      expect(values.scalar("Ticks", "n")).to be_an Integer
      expect(values.scalar("Slug", "handle")).to be_a String
    end

    it "still names the type when nothing registered one" do
      expect(values.scalar("Money", "price")).to match(/\AMoney-\d+\z/)
    end

    # An app class is the one Ruby type the library can't invent a wire value
    # for: only whoever wrote Money.parse knows what it accepts. A placeholder
    # here raised out of the codec, blaming Money for the fake's guess.
    context "registered as an app class" do
      let(:money) do
        Class.new do
          def self.name = "Money"
          def self.parse(wire) = new(Float(wire))
          def initialize(amount) = @amount = amount
          attr_reader :amount
        end
      end

      before { stub_const("Money", money) }

      it "refuses, naming the field and both fixes" do
        GraphWeaver.register_scalar("Money", Money, cast: :parse, serialize: :to_s)

        expect { values.scalar("Money", "price") }.to raise_error(GraphWeaver::Error) { |error|
          expect(error.message).to include("Money", "price", "fake:", "overrides:")
        }
      end

      # a bare "price" pins that field on every type; the coordinate the
      # caller resolved against is the advice that pins the one that failed
      it "advises the coordinate when the caller knew one" do
        GraphWeaver.register_scalar("Money", Money, cast: :parse, serialize: :to_s)

        expect { values.scalar("Money", "price", "Order.price", at: "orders.0.price") }
          .to raise_error(GraphWeaver::Error, /at orders\.0\.price.*"Order\.price"/m)
      end

      it "uses the fake: the registration supplies" do
        GraphWeaver.register_scalar("Money", Money, cast: :parse, serialize: :to_s, fake: "12.00")

        expect(Money.parse(values.scalar("Money", "price")).amount).to eq 12.0
      end

      # a fake that varies has to vary off the seeded rng, or --seed stops
      # reproducing the run
      it "hands a proc the seeded rng" do
        GraphWeaver.register_scalar("Money", Money, cast: :parse, serialize: :to_s,
          fake: ->(rng) { format("%.2f", rng.rand(1.0..100.0)) })

        drawn = Array.new(3) { values.scalar("Money", "price") }
        again = described_class.new(seed: 3, values: :literal)

        expect(drawn.uniq.size).to eq 3
        expect(drawn).to eq Array.new(3) { again.scalar("Money", "price") }
      end
    end
  end

  describe "values:" do
    it "asks for the gem by name when :faker was requested and isn't there" do
      hide_const("Faker")

      expect { described_class.new(values: :faker) }
        .to raise_error(ArgumentError, /requires the faker gem \(add it to your Gemfile's test group\)/)
    end

    it "falls back to :literal without complaint when nothing asked for :faker" do
      hide_const("Faker")

      expect(described_class.new(seed: 1).scalar("String", "email")).to match(/\Aemail-\d+\z/)
    end

    it "uses faker when asked for it explicitly" do
      expect(described_class.new(seed: 1, values: :faker).scalar("String", "email")).to match(/@/)
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
