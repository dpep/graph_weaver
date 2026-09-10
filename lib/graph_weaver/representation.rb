# typed: true
# frozen_string_literal: true

require_relative "errors"

module GraphWeaver
  # Called by generated code — not semver'd for direct use.
  #
  # Runtime for the generated `Representations` builders — the entity
  # references a federation `_entities(representations:)` query takes.
  #
  # Codegen types what it can: the kwargs are the entity's @key fields, so a
  # single-key entity can't be under-specified without a Sorbet error. What's
  # left is what a sig can't say — an entity with two alternative keys (either
  # resolves it, neither is individually required) and a nested key set
  # (`organization { id }`, a sub-hash the kwarg's Hash type doesn't pin
  # down). Both land here.
  #
  # `InputError#struct` is the entity's GraphQL type name here, not a class: a
  # representation is a Hash a module function builds, so there is no generated
  # struct to name.
  module Representation
    # `key_sets` is the entity's @key field sets as dotted paths, in
    # declaration order — [["upc", "sku"], ["id"]] for a type keyed either
    # way. The first fully-supplied one wins; the wire hash carries exactly
    # that key set plus __typename, so nothing extraneous reaches the router.
    def self.build(type_name, values, key_sets)
      satisfied = key_sets.find { |paths| missing(values, paths).empty? }
      raise incomplete(type_name, values, key_sets) unless satisfied

      satisfied.each_with_object({ "__typename" => type_name }) do |path, wire|
        assign(wire, path.split("."), dig(values, path))
      end
    end

    # One key field's trip onto the wire: normalize whatever arrived into the
    # type the sig promises — the sig itself is `.checked(:never)`, so this is
    # the check — then serialize. A cast complains about the value alone
    # ("expected an Int"), and a query can build several representations, so
    # the refusal names this one and the field. nil passes through untouched:
    # a missing key is `build`'s complaint to make, and it says more.
    def self.field(type_name, name, value)
      return if value.nil?

      yield value
    rescue StandardError => e
      shown = value.inspect
      got = " (got #{shown})" unless e.message.include?(shown)
      raise InputError.new(
        "#{type_name} representation #{name}: #{Internal::Redact.detail(name, "#{e.message}#{got}")}",
        field: name, struct: type_name,
      )
    end

    def self.missing(values, paths) = paths.select { |path| dig(values, path).nil? }
    private_class_method :missing

    # Nested key values arrive as a caller-built hash, so accept either key
    # flavour at every hop — a literal `{ id: "1" }` reads the same as a hash
    # round-tripped through JSON.
    def self.dig(values, path)
      path.split(".").reduce(values) do |scope, name|
        return unless scope.is_a?(Hash)

        scope.key?(name) ? scope[name] : scope[name.to_sym]
      end
    end
    private_class_method :dig

    def self.assign(wire, path, value)
      *parents, leaf = path
      target = parents.reduce(wire) { |scope, name| scope[name] ||= {} }
      target[leaf] = value
    end
    private_class_method :assign

    # Name the type and what it's short of, per @key — with a single key
    # there's one answer, so it also fills InputError#field.
    def self.incomplete(type_name, values, key_sets)
      gaps = key_sets.map { |paths| missing(values, paths) }

      if key_sets.one?
        InputError.new(
          "#{type_name} representation is missing @key #{gaps.first.map(&:inspect).join(", ")}",
          field: gaps.first.one? ? gaps.first.first : nil, struct: type_name,
        )
      else
        alternatives = key_sets.zip(gaps).map do |paths, gap|
          # a partly-supplied compound key is the near miss worth pointing at;
          # for one wholly absent, naming it twice says nothing extra
          supplied = gap.size < paths.size
          "#{paths.map(&:inspect).join(" + ")}#{" (missing #{gap.map(&:inspect).join(", ")})" if supplied}"
        end
        InputError.new(
          "#{type_name} representation satisfies none of its @keys — supply #{alternatives.join(", or ")}",
          struct: type_name,
        )
      end
    end
    private_class_method :incomplete
  end
end
