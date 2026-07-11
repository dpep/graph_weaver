# typed: true
# frozen_string_literal: true

require "date"

# The value engine behind FakeExecutor and Cassette#anonymize!: seeded,
# type-correct scalar generation with optional faker-backed semantics
# matched on field names — strings (name/email/url/...) and numbers
# (age/price/count/latitude/...) alike. Keeps a consistent id mapping so
# the same original id always anonymizes to the same fake id.
class GraphWeaver::Testing::Values
  include GraphWeaver::Inflect

  STRING_SEMANTICS = {
    /email/ => -> { ::Faker::Internet.email },
    /(^|_)first_name$/ => -> { ::Faker::Name.first_name },
    /(^|_)last_name$/ => -> { ::Faker::Name.last_name },
    /(^|_)(full_)?name$/ => -> { ::Faker::Name.name },
    /(^|_)(url|website|link)$/ => -> { ::Faker::Internet.url },
    /phone/ => -> { ::Faker::PhoneNumber.phone_number },
    /(^|_)address$/ => -> { ::Faker::Address.full_address },
    /(^|_)(city)$/ => -> { ::Faker::Address.city },
    /(^|_)(title|description)$/ => -> { ::Faker::Lorem.sentence(word_count: 3) },
  }.freeze

  NUMBER_SEMANTICS = {
    /(^|_)age$/ => ->(rng) { rng.rand(1..99) },
    /(^|_)(price|amount|cost|total)(_cents)?$/ => ->(rng) { (rng.rand(1.0..10_000.0) * 100).round / 100.0 },
    /(^|_)(count|quantity|size)$/ => ->(rng) { rng.rand(0..100) },
    /latitude/ => ->(rng) { rng.rand(-90.0..90.0).round(6) },
    /longitude/ => ->(rng) { rng.rand(-180.0..180.0).round(6) },
    /(^|_)year$/ => ->(rng) { rng.rand(1970..2030) },
  }.freeze

  attr_reader :rng

  def initialize(seed: nil, mode: nil)
    config = GraphWeaver::Testing.config
    @rng = Random.new(seed || config.seed || Random.new_seed)
    @mode = resolve_mode(mode || config.mode)
    @sequence = 0
    @id_map = {}
  end

  def scalar(type_name, field_name)
    prop = underscore(field_name)

    if @mode == :faker
      # rebind per call: several Values instances may interleave (e.g. two
      # seeded executors), and faker's rng is global
      ::Faker::Config.random = @rng
      case type_name
      when "String"
        STRING_SEMANTICS.each { |pattern, faker| return faker.call if pattern.match?(prop) }
      when "Int", "Float"
        NUMBER_SEMANTICS.each do |pattern, gen|
          next unless pattern.match?(prop)

          value = gen.call(@rng)
          return type_name == "Int" ? value.to_i : value.to_f
        end
      end
    end

    case type_name
    when "ID" then (@sequence += 1).to_s
    when "String" then "#{field_name}-#{@sequence += 1}"
    when "Int" then @rng.rand(0..1_000)
    when "Float" then @rng.rand(0.0..1_000.0).round(2)
    when "Boolean" then [true, false].sample(random: @rng)
    when "Date" then (Date.new(2020, 1, 1) + @rng.rand(0..2_000)).iso8601
    when "DateTime", "Time", "ISO8601DateTime" then Time.at(1_600_000_000 + @rng.rand(0..100_000_000)).utc.iso8601
    else "#{type_name}-#{@sequence += 1}" # unknown custom scalar: override it
    end
  end

  # same original id => same fake id, so relationships survive anonymization
  def mapped_id(original)
    @id_map[original] ||= (@sequence += 1).to_s
  end

  private

  # :faker is an explicit ask — fail loudly when the gem is missing; auto
  # (nil) quietly falls back to :literal
  def resolve_mode(mode)
    case mode
    when :faker
      raise ArgumentError, "mode: :faker requires the faker gem (add it to your Gemfile's test group)" unless defined?(::Faker)

      :faker
    when :literal then :literal
    when nil then defined?(::Faker) ? :faker : :literal
    else
      raise ArgumentError, "mode: must be one of #{GraphWeaver::Testing::MODES.inspect} (or nil for auto), got #{mode.inspect}"
    end
  end
end
