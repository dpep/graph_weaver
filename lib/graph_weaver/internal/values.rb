# typed: true
# frozen_string_literal: true

require "date"

# The value engine behind FakeClient and Cassette#anonymize!: seeded,
# type-correct scalar generation with optional faker-backed semantics
# matched on field names — strings (name/email/url/...) and numbers
# (age/price/count/latitude/...) alike. Keeps a consistent id mapping so
# the same original id always anonymizes to the same fake id.
class GraphWeaver::Internal::Values
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

  # The Ruby shape a fabricated value has to take, keyed by the class the
  # scalar registry says the scalar deserializes into. That registry is what
  # codegen emitted the prop and its cast from, so a scalar registered as
  # Time needs an iso8601 string whatever the schema happens to call it.
  REGISTERED_SHAPES = {
    "String" => :string,
    "Integer" => :integer,
    "Float" => :float,
    "T::Boolean" => :boolean,
    "Date" => :date,
    "Time" => :time,
    "DateTime" => :time,
  }.freeze

  # What Codegen.scalar reports for a scalar nobody registered
  UNREGISTERED = "T.untyped"

  # The fallback, for a scalar nobody registered: its prop is T.untyped, so
  # anything holds and a plausible shape beats a placeholder.
  NAMED_SHAPES = {
    "ID" => :id,
    "String" => :string,
    "Int" => :integer,
    "Float" => :float,
    "Boolean" => :boolean,
    "Date" => :date,
    "DateTime" => :time,
    "Time" => :time,
    "ISO8601DateTime" => :time,
  }.freeze

  attr_reader :rng

  def initialize(seed: nil, values: nil)
    @rng = Random.new(seed || GraphWeaver::Testing.config.seed || Random.new_seed)
    @style = resolve_style(values)
    @sequence = 0
    @id_map = {}
    @resolved = {}
  end

  # coordinate: the "Type.field" this value is for, so a per-field
  # register_scalar resolves the way codegen resolved it when it emitted the
  # cast — and so a refusal can advise an override key that pins this field
  # alone. at: where the walk is ("reader.orders.0.total"), for that refusal;
  # a walk that doesn't track one leaves it unsaid.
  def scalar(type_name, field_name, coordinate = nil, at: nil)
    registered, shape = resolve(type_name, coordinate)
    return registered.fake(rng) if registered.fake?

    prop = underscore(field_name)

    if @style == :faker
      # rebind per call: several Values instances may interleave (e.g. two
      # seeded fakes), and faker's rng is global
      ::Faker::Config.random = @rng
      case shape
      when :string
        STRING_SEMANTICS.each { |pattern, faker| return faker.call if pattern.match?(prop) }
      when :integer, :float
        NUMBER_SEMANTICS.each do |pattern, gen|
          next unless pattern.match?(prop)

          value = gen.call(@rng)
          return (shape == :integer) ? value.to_i : value.to_f
        end
      end
    end

    case shape
    when :id then (@sequence += 1).to_s
    when :string then "#{field_name}-#{@sequence += 1}"
    when :integer then @rng.rand(0..1_000)
    when :float then @rng.rand(0.0..1_000.0).round(2)
    when :boolean then [true, false].sample(random: @rng)
    when :date then (Date.new(2020, 1, 1) + @rng.rand(0..2_000)).iso8601
    when :time then Time.at(1_600_000_000 + @rng.rand(0..100_000_000)).utc.iso8601
    when :unregistered then "#{type_name}-#{@sequence += 1}" # nobody registered it: prop is T.untyped
    else unfakeable!(type_name, field_name, registered, coordinate, at)
    end
  end

  # same original id => same fake id, so relationships survive anonymization
  def mapped_id(original)
    @id_map[original] ||= (@sequence += 1).to_s
  end

  private

  # The registration in play and the shape it wants, memoized per scalar (or
  # per coordinate, where a field-level registration overrides it).
  def resolve(type_name, coordinate)
    @resolved[coordinate || type_name] ||= begin
      registered = GraphWeaver::Codegen.scalar(type_name, coordinate)
      [registered, shape_of(type_name, registered.type)]
    end
  end

  # ID asks by name as well as by class: it registers as String, and an id
  # repeated across a list breaks a `find` or `group_by` in the code under
  # test. Registered as anything else, it takes that type's treatment.
  def shape_of(type_name, ruby_type)
    if type_name == "ID" && ruby_type == "String"
      :id
    elsif (shape = REGISTERED_SHAPES[ruby_type])
      shape
    elsif ruby_type == UNREGISTERED
      NAMED_SHAPES[type_name] || :unregistered
    else
      :unfakeable
    end
  end

  # An app class is the one Ruby type nothing here can invent a wire value
  # for — `Money.parse` accepts what its author decided it accepts — and
  # guessing hands the generated cast a placeholder, which fails deep inside
  # from_h blaming the codec.
  def unfakeable!(type_name, field_name, registered, coordinate, at)
    raise GraphWeaver::Error, "can't fabricate a #{type_name} #{at ? "at #{at}" : "for #{field_name.inspect}"}: " \
      "it deserializes into #{registered.type}, and only the registration knows what wire value " \
      "that accepts. Say it there — GraphWeaver.register_scalar(#{registered.graphql_name.inspect}, " \
      "#{registered.type}, fake: -> { ... }) — or pin this one field: " \
      "overrides: { #{(coordinate || field_name).inspect} => ... }"
  end

  # :faker is an explicit ask — fail loudly when the gem is missing; auto
  # (nil) quietly falls back to :literal
  def resolve_style(style)
    case style
    when :faker
      raise ArgumentError, "values: :faker requires the faker gem (add it to your Gemfile's test group)" unless defined?(::Faker)

      :faker
    when :literal then :literal
    when nil then defined?(::Faker) ? :faker : :literal
    else
      raise ArgumentError, "values: must be one of #{GraphWeaver::Testing::VALUE_STYLES.inspect} " \
        "(or nil for auto), got #{style.inspect}"
    end
  end
end
