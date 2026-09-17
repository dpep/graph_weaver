# typed: true
# frozen_string_literal: true

# What `extend_type` registers, and where its block-built mixins land.
#
# Three things ride on one call — helper modules mixed into every struct
# generated from a GraphQL type, the requires those modules need, and
# alias: paths that flatten a nested selection onto a typed accessor. They
# share a registry entry because they share a registration, and codegen
# reads all three off the same type name (see Codegen::Aliases for how a
# path is resolved against an actual selection).

class GraphWeaver::Codegen
  # The extend_type half of one graph's registrations — see Codegen::Registry.
  class Registry
    # Attach app-owned helper modules to every struct generated from a
    # GraphQL type — the logic stays in your code, generation wires it in:
    #
    #      GraphWeaver.extend_type("Pet", PetHelpers)
    #
    # Or build the mixin inline — the block is module_eval'd into a fresh
    # module named for where it is written and what it extends:
    # GraphWeaver::TypeHelpers::Pet, or ::Billing::Pet in graph :billing.
    # Handy for quick decoration; srb tc can't see into block-defined methods,
    # so prefer a named module where static checking matters:
    #
    #      GraphWeaver.extend_type("Pet") do
    #        def display_name = "#{name} the pet"
    #      end
    #
    # Additive: repeated registrations (and client-scoped ones) stack.
    #
    # alias: projects a (possibly nested) selected field onto a flat, typed
    # accessor on the struct — the one derivation codegen can type itself, so
    # it's emitted into the struct body where the field is in scope:
    #
    #      GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" })
    #      GraphWeaver.extend_type("Widget", alias: "meta.tag")        # accessor named `tag`
    #      GraphWeaver.extend_type("Widget", alias: ["meta.tag", "meta.color"])
    #
    # A path segment is a field, or `first`/`last` to pick one element out of a
    # list hop (always nilable): `alias: { entity: "_entities.first" }`.
    #
    # optional: true makes the aliases lenient — a query whose selection doesn't
    # fit the path just omits the accessor instead of failing generation. Use it
    # for a root-type accessor (a Query alias every query would otherwise have to
    # satisfy) or one that only fits some selections.
    #
    # Inside the block, `alias_field` is the same keyword said next to the
    # methods that use it — one alias per line, always strict:
    #
    #      GraphWeaver.extend_type("Widget") do
    #        alias_field :tag, "meta.tag"
    #        def shout = tag&.upcase
    #      end
    def extend_type(graphql_name, *mixins, requires: nil, **kw, &block)
      optional = !!kw.delete(:optional)
      aliases = normalize_aliases(kw.delete(:alias), optional:)
      raise ArgumentError, "unknown keyword: #{kw.keys.first}" unless kw.empty?

      mixins = mixins.dup
      mixins << helper_module(graphql_name, block, aliases) if block

      raise ArgumentError, "pass one or more helper modules, a block, or alias:" if mixins.empty? && aliases.empty?
      mixins.each do |mixin|
        # a name rather than the module is what you write when the constant
        # won't resolve yet — see EnumType for why that's a Rails initializer
        if mixin.is_a?(String)
          raise ArgumentError, "type helpers are the modules themselves, not their names — " \
            "extend_type(#{graphql_name.to_s.inspect}, #{mixin}). #{GraphWeaver::Codegen::AUTOLOAD_HINT}"
        end
        unless mixin.is_a?(Module) && mixin.name
          raise ArgumentError, "type helpers must be named modules, got #{mixin.inspect}"
        end
      end

      entry = type_registry[graphql_name.to_s] ||= { mixins: [], requires: [], aliases: {} }
      entry[:mixins].concat(mixins)
      entry[:requires].concat(GraphWeaver::Codegen.normalize_requires!(requires, load: true))
      entry[:aliases].merge!(aliases)
      entry
    end

    # accessor names and path segments are interpolated verbatim into generated
    # source, so — like module_name — they must be plain identifiers, never
    # arbitrary text that could inject code
    ALIAS_NAME = /\A[a-zA-Z_]\w*[?!]?\z/
    ALIAS_SEGMENT = /\A[a-zA-Z_]\w*\z/
    private_constant :ALIAS_NAME, :ALIAS_SEGMENT

    # { accessor => { segments:, optional: } } from a path string (accessor
    # named after the last segment), an array of such, or an { accessor => path }
    # hash. `optional:` marks every alias in this registration as lenient.
    def normalize_aliases(input, optional:)
      pairs = case input
      when nil then []
      when String then [[input.split(".").last, input.split(".")]]
      when Array then input.map { |path| [path.split(".").last, path.split(".")] }
      when Hash then input.map { |name, path| [name.to_s, path.to_s.split(".")] }
      else raise ArgumentError, "alias: expects a String, Array, or Hash, got #{input.class}"
      end
      pairs.to_h do |name, segments|
        unless name.to_s.match?(ALIAS_NAME)
          raise ArgumentError, "alias name #{name.inspect} is not a valid method name"
        end
        raise ArgumentError, "alias #{name.inspect} has an empty path" if segments.empty?

        bad = segments.reject { |seg| seg.match?(ALIAS_SEGMENT) }
        raise ArgumentError, "alias #{name.inspect} has an invalid path segment: #{bad.first.inspect}" if bad.any?

        [name, { segments:, optional: }]
      end
    end
    private :normalize_aliases

    def type_registry
      @type_registry ||= {}
    end

    # Drop every extend_type registration (mixins, requires, alias: paths).
    # The block-built mixin constants under GraphWeaver::TypeHelpers stay —
    # generated files may still name them.
    def reset_type_helpers!
      type_registry.clear
      helper_counts.clear
      self
    end

    # Which graph's registrations this registry holds — nil for the top-level
    # one. Block-built helpers are named for it, so two graphs extending the
    # same type get two constants (see helper_module).
    attr_accessor :graph_name

    # A block-built mixin needs a name generated files can reference:
    # GraphWeaver::TypeHelpers::Pet, or ::Billing::Pet in graph :billing (V2,
    # V3… for a second and third block on the same type in the same place).
    #
    # The name is a function of the source and nothing else — where the block
    # is written and what it extends. It gets baked into generated code, so
    # naming it after whichever constants happened to exist made it a function
    # of how many times THIS process had read the registry, and `generate`
    # wrote a name a plain boot never creates.
    def helper_module(graphql_name, block, aliases)
      namespace = helper_namespace
      type = GraphWeaver::Inflect.camelize(graphql_name.to_s)
      index = (helper_counts[[namespace.name, type]] += 1)
      name = index == 1 ? type : "#{type}V#{index}"
      # reused rather than replaced, so re-declaring the same source (a Rails
      # to_prepare reload) keeps the module already-loaded structs include
      mod = const_under(namespace, name) { Module.new }
      aliases.merge!(collect_aliases(graphql_name, mod, aliases, &block))
      mod
    end
    private :helper_module

    # Run the block with `alias_field` available — the alias: keyword said one
    # line at a time — and hand back what it collected.
    #
    # It lives on the module's singleton for the length of the block and is
    # removed after: a generated struct includes this module, and an
    # `alias_field` left behind would be an instance method the wire never named.
    def collect_aliases(graphql_name, mod, keyword_aliases, &block)
      registry, collected = self, {}
      mod.define_singleton_method(:alias_field) do |name, path = nil, **kw|
        collected.merge!(registry.send(:one_alias, graphql_name, name, path, kw))
      end
      mod.module_eval(&block)

      twice = keyword_aliases.keys & collected.keys
      unless twice.empty?
        raise ArgumentError, "extend_type(#{graphql_name.to_s.inspect}) declares alias " \
          "#{twice.first.inspect} twice — once as alias:, once as alias_field; keep one"
      end
      collected
    ensure
      mod.singleton_class.send(:remove_method, :alias_field)
    end
    private :collect_aliases

    ALIAS_FIELD_FORMS = %(one alias per line — alias_field "meta.tag", or alias_field :tag, "meta.tag"; ) +
      %(a Hash or Array of paths goes on the alias: keyword)
    private_constant :ALIAS_FIELD_FORMS

    # One `alias_field` line, normalized the way the keyword's own paths are.
    # The block takes no optional: — leniency has one spelling, on the keyword,
    # because it is a property of the registration and not of one accessor.
    def one_alias(graphql_name, name, path, kw)
      if kw.key?(:optional)
        keyword = path ? "alias: { #{name}: #{path.inspect} }" : "alias: #{name.inspect}"
        raise ArgumentError, "alias_field is always strict — for a lenient alias use the keyword: " \
          "extend_type(#{graphql_name.to_s.inspect}, #{keyword}, optional: true)"
      end
      raise ArgumentError, "unknown keyword: #{kw.keys.first}" unless kw.empty?

      input = if path.nil? && name.is_a?(String)
        name
      elsif path.is_a?(String) && (name.is_a?(String) || name.is_a?(Symbol))
        { name => path }
      end
      if input.nil?
        # spelled as a caller writes it — Hash#inspect changed between Ruby 3.3 and 3.4
        given = [name, path].compact.map do |arg|
          arg.is_a?(Hash) ? "{#{arg.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")}}" : arg.inspect
        end.join(", ")
        raise ArgumentError, "alias_field #{given}: #{ALIAS_FIELD_FORMS}"
      end

      normalize_aliases(input, optional: false)
    end
    private :one_alias

    # Where this registry's block-built helpers live: under a module named for
    # the graph, so two graphs extending the same type get two constants and
    # neither has to know the other exists.
    def helper_namespace
      return GraphWeaver::TypeHelpers unless graph_name

      const_under(GraphWeaver::TypeHelpers, GraphWeaver::Inflect.camelize(graph_name.to_s)) { Module.new }
    end
    private :helper_namespace

    def const_under(namespace, name)
      return namespace.const_get(name, false) if namespace.const_defined?(name, false)

      namespace.const_set(name, yield)
    end
    private :const_under

    # How many block-built helpers this registry has already named for a type.
    # Per registry, not per process: a graph's registrations are replayed over
    # a fresh copy of the top-level registry on every read, so the same source
    # counts the same way every time.
    def helper_counts
      @helper_counts ||= Hash.new(0)
    end
    private :helper_counts
  end
end

module GraphWeaver
  # Home of block-built type helpers (extend_type with a block), which
  # need constant names so generated files can reference them.
  module TypeHelpers; end
end
