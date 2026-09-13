# typed: true
# frozen_string_literal: true

require_relative "errors"
require_relative "internal/refusal"

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
    # Marks a key path hop the schema declares as a list: `@key(fields: "id
    # lineItems { sku }")` over a `[LineItem!]!` flattens to
    # "lineItems[].sku". A representation is built from these paths and
    # nothing else, so this is the only place list-ness is written down.
    LIST_HOP = "[]"

    # `key_sets` is the entity's @key field sets as dotted paths, in
    # declaration order — [["upc", "sku"], ["id"]] for a type keyed either
    # way. The first fully-supplied one wins; the wire hash carries exactly
    # that key set plus __typename, so nothing extraneous reaches the router.
    def self.build(type_name, values, key_sets)
      satisfied = key_sets.find { |paths| missing(values, paths).empty? }
      raise incomplete(type_name, values, key_sets) unless satisfied

      satisfied.each_with_object({ "__typename" => type_name }) do |path, wire|
        graft(wire, values, path.split("."))
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
      shown = Internal::Redact.shown(value)
      got = " (got #{shown})" unless e.message.include?(shown)
      raise InputError.new(
        "#{type_name} representation #{name}: #{Internal::Redact.detail(name, "#{e.message}#{got}")}",
        kind: Internal::Refusal.kind_of(e), path: [name], coordinate: "#{type_name}.#{name}",
        value: Internal::Redact.value(name, value), details: Internal::Refusal.details_of(e),
        struct: type_name,
      )
    end

    def self.missing(values, paths) = paths.select { |path| dig(values, path).nil? }
    private_class_method :missing

    # Nested key values arrive as a caller-built hash, so accept either key
    # flavour at every hop — a literal `{ id: "1" }` reads the same as a hash
    # round-tripped through JSON. A LIST_HOP has to BE a list, and the rest of
    # the path reads through every element: supplied only if all of them are,
    # so one object where the schema says list reads as absent rather than
    # going onto the wire misshapen.
    def self.dig(scope, hops)
      hops = hops.split(".") if hops.is_a?(String)
      return scope if hops.empty?
      return unless scope.is_a?(Hash)

      hop, *rest = hops
      value = fetch(scope, hop.delete_suffix(LIST_HOP))
      return dig(value, rest) unless hop.end_with?(LIST_HOP)
      return unless value.is_a?(Array)
      return value if rest.empty?

      each = value.map { |item| dig(item, rest) }
      each unless each.any?(&:nil?)
    end
    private_class_method :dig

    def self.fetch(hash, name) = hash.key?(name) ? hash[name] : hash[name.to_sym]
    private_class_method :fetch

    # One key path, copied onto the wire in the shape the path declares — a
    # LIST_HOP stays a list of objects, one per element, rather than
    # collapsing into the single object a subgraph would read as one entity.
    def self.graft(wire, source, hops)
      hop, *rest = hops
      name = hop.delete_suffix(LIST_HOP)
      value = fetch(source, name)
      return wire[name] = value if rest.empty?

      if hop.end_with?(LIST_HOP)
        elements = (wire[name] ||= Array.new(value.size) { {} })
        value.each_with_index { |item, index| graft(elements[index], item, rest) }
      else
        graft(wire[name] ||= {}, value, rest)
      end
    end
    private_class_method :graft

    # Name the type and what it's short of, per @key — with a single key
    # there's one answer, so it also fills InputError#path.
    def self.incomplete(type_name, values, key_sets)
      gaps = key_sets.map { |paths| missing(values, paths) }

      if key_sets.one?
        # a nested @key reads "organization.id"; #path is that route, without
        # the list markers the message keeps
        path = gaps.first.one? ? gaps.first.first.split(".").map { |hop| hop.delete_suffix(LIST_HOP) } : []
        InputError.new(
          "#{type_name} representation is missing @key #{gaps.first.map(&:inspect).join(", ")}",
          kind: :missing, path:,
          coordinate: ("#{type_name}.#{path.first}" if path.one?),
          struct: type_name,
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
          kind: :missing, struct: type_name,
        )
      end
    end
    private_class_method :incomplete
  end
end
