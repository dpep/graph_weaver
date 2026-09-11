# typed: true
# frozen_string_literal: true

# One graph's registrations: the scalar codecs, the enum mappings, and the
# type helpers a generation reads. The three tables move together because a
# registration is scoped to the schema it describes — an app with two schemas
# registers `Money` for each, or for only one, and neither answer is the
# other's (see GraphWeaver.graph).
#
# The methods themselves live in Registrations, which the three codegen/*.rb
# files fill in; this is where they get somewhere to write. Codegen's class
# methods (GraphWeaver.register_scalar and friends) delegate here, to the
# default graph's registry — so a single-schema app never meets this class.

class GraphWeaver::Codegen
  # The registrations one graph generates with: the scalar codecs, the enum
  # mappings and the type helpers, plus what a schema can say about them.
  # Users never name this class — they write register_scalar/register_enum/
  # extend_type, at the top level (the default graph) or in a graph block.
  # codegen/{scalar,enum,type_helpers}.rb fill in the registering half.
  class Registry
    # What a registry's names must be in the schema. extend_type decorates
    # whatever composite a query reaches, so it demands no particular kind.
    REGISTERED_KIND = { "scalar" => "SCALAR", "enum" => "ENUM" }.freeze
    # the type registry is reached via extend_type; scalars/enums via register_*
    REGISTRATION_METHOD = { "type" => "extend_type", "scalar" => "register_scalar", "enum" => "register_enum" }.freeze
    private_constant :REGISTERED_KIND, :REGISTRATION_METHOD

    # Every registration this schema can't match, one sentence each. The answer
    # depends on the schema and the registry alone, not on any one document, so
    # a whole generate! run gets the same list — which is what lets the build
    # report it once (see GraphWeaver.unmatched_registrations).
    #
    # The built-in scalars are pre-registered entries in the same table rather
    # than user intent, so they're exempt — a schema with no Date scalar is not
    # a mistake.
    def unmatched_registrations(schema)
      {
        "enum" => enum_registry,
        "scalar" => scalar_registry.except(*BUILTIN_SCALARS),
        "type" => type_registry,
      }.flat_map do |kind, registry|
        registry.keys.filter_map { |name| validate_registration!(schema, kind, name) }
      end
    end

    # A registry serves one graph, but a generation sees one schema — so a
    # registration fails generation only where THIS schema can disprove it: a
    # name it declares as something else, or a coordinate whose field it declares
    # as a composite. A name it can't match at all proves nothing, because an
    # entity type is declared by every subgraph that references it while its
    # fields are split among them; that returns the sentence to say instead.
    def validate_registration!(schema, kind, name)
      method = REGISTRATION_METHOD.fetch(kind)
      # register_scalar("Type.field", ...) overrides one field's scalar — validate
      # the field, not that a type named "Type.field" exists.
      return validate_scalar_field!(schema, name, method) if kind == "scalar" && name.include?(".")

      type = schema.get_type(name)
      unless type
        return unmatched(schema, method, name, kind, GraphWeaver::Internal::Util.did_you_mean(schema.types.keys, name))
      end

      expected = REGISTERED_KIND[kind]
      return if expected.nil? || type.kind.name == expected

      found = type.kind.name.downcase.tr("_", " ")
      # a leaf registered as the other kind has a method that would have worked
      other = REGISTERED_KIND.key(type.kind.name)
      raise GraphWeaver::Error,
        "#{method}(#{name.inspect}) names #{article(found)} #{found}, not #{article(kind)} " \
        "#{kind}#{other ? " — use #{REGISTRATION_METHOD.fetch(other)}" : ""}"
    end
    private :validate_registration!

    # A per-field override, register_scalar("Type.field", ...). Neither an absent
    # type nor an absent field is disprovable here; what is, is a field this
    # schema declares as something a scalar codec could never read.
    def validate_scalar_field!(schema, name, method)
      type_name, field_name = name.split(".", 2)
      type = schema.get_type(type_name)
      unless type
        near = GraphWeaver::Internal::Util.did_you_mean(schema.types.keys, type_name)
        return unmatched(schema, method, name, "scalar field", near && "#{near}.#{field_name}")
      end

      fields = type.respond_to?(:fields) ? type.fields : {}
      field = fields[field_name]
      unless field
        near = GraphWeaver::Internal::Util.did_you_mean(fields.keys, field_name)
        return unmatched(schema, method, name, "scalar field", near && "#{type_name}.#{near}")
      end
      return if field.type.unwrap.kind.name == "SCALAR"

      raise GraphWeaver::Error,
        "#{method}(#{name.inspect}): #{name} isn't a scalar field (it's #{field.type.unwrap.kind.name.downcase})"
    end
    private :validate_scalar_field!

    # What to say about a name this schema has nothing for. Registrations are
    # graph-scoped — federation composes by name, so one `Money` codec serves
    # every subgraph that declares it — which is exactly why this schema can't
    # tell a typo from a registration for the subgraph next door. Say both.
    def unmatched(schema, method, name, what, suggestion)
      hint = suggestion ? " (did you mean '#{suggestion}'?)" : ""
      "#{method}(#{name.inspect}) matches no #{what} in #{schema.name || "this schema"} " \
        "— a typo#{hint}, or a registration for another schema"
    end
    private :unmatched

    def article(word) = word.downcase.start_with?(/[aeiou]/) ? "an" : "a"
    private :article

    # Every table back to its starting state — scalars (built-ins restored),
    # enum mappings, and type helpers. The clean slate between tests, and the
    # one call that stays right when a fourth kind of registration shows up.
    def reset_registrations!
      reset_scalars!
      reset_enums!
      reset_type_helpers!
      self
    end

    def initialize = register_builtin_scalars!
  end

  # The default graph's registrations — where a top-level
  # GraphWeaver.register_scalar writes, and what a generation uses unless a
  # graph hands it its own.
  def self.registry = @registry ||= Registry.new

  # Pre-registered rather than user intent, so generation doesn't hold a schema
  # to them (validate_registration! skips these). Read off a fresh registry: a
  # seventh built-in shouldn't have to be named twice.
  BUILTIN_SCALARS = Registry.new.scalar_registry.keys.freeze

  class << self
    # The default graph's registry answers every one of these — the surface an
    # app has used since before graphs existed, unchanged.
    def register_scalar(...) = registry.register_scalar(...)
    def register_enum(...) = registry.register_enum(...)
    def extend_type(...) = registry.extend_type(...)
    def scalar(...) = registry.scalar(...)
    def scalar_registry = registry.scalar_registry
    def enum_registry = registry.enum_registry
    def type_registry = registry.type_registry
    def unmatched_registrations(...) = registry.unmatched_registrations(...)
    def clear_scalars! = registry.clear_scalars! && self
    def reset_scalars! = registry.reset_scalars! && self
    def reset_enums! = registry.reset_enums! && self
    def reset_type_helpers! = registry.reset_type_helpers! && self

    # Returns Codegen, not the registry: these are the documented calls, and
    # their value has always been something you can keep chaining off.
    def reset_registrations! = registry.reset_registrations! && self
  end
end
