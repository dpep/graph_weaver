# typed: true
# frozen_string_literal: true

# Registered aliases (extend_type alias:): dotted paths that project a nested
# selection onto the struct that owns it — `entity: "_entities.first"`,
# `tag: "meta.tag"` — as typed delegators. Resolved against the walked node
# tree, so a path the query doesn't select fails at generation.
#
# Mixed into Codegen — methods run with the generator instance state. The
# subsystem hangs off one seam: object_node's
# `node.aliases = resolve_aliases(node)`.
class GraphWeaver::Codegen
  module Aliases
    include Kernel # for sorbet: hosts are Objects

    private

    # Resolve each registered alias (extend_type alias:) for this struct's type
    # against its actual selection — path -> a typed delegator emitted into the
    # struct body. Validated here, per query, so an unselected or untraversable
    # path fails at generation with a pointed message.
    def resolve_aliases(node)
      type_aliases(node.graphql_type).filter_map do |name, spec|
        # a bad accessor name (reserved, or colliding with a real field) is a
        # registration mistake — it fails for every query, so it always raises,
        # even for optional aliases (which otherwise mask it as "doesn't fit").
        check_alias_name!(node, name)
        begin
          resolve_alias(node, name, spec[:segments])
        rescue GraphWeaver::Error => e
          # a path that doesn't fit THIS query's selection: optional simply
          # omits the accessor; strict breaks generation for every query on the
          # type, so name the one that failed and the way out
          next nil if spec[:optional]

          raise e.class, "#{[@module_name, e.message].compact.join(": ")} " \
            "— pass optional: true to skip selections that don't fit"
        end
      end
    end

    def check_alias_name!(node, name)
      taken = node.fields.any? { |f| f.prop == name } ||
        ALIAS_RESERVED.include?(name) || RUBY_KEYWORDS.include?(name)
      return unless taken

      raise GraphWeaver::Error,
        "alias #{name.inspect} on #{node.graphql_type} collides with an existing field or method"
    end

    # Registered aliases for a GraphQL type: global registry plus this client's
    # overlay (client-scoped wins on a name clash).
    def type_aliases(graphql_name)
      global = GraphWeaver::Codegen.type_registry[graphql_name]&.dig(:aliases) || {}
      (global.merge(@types[graphql_name]&.dig(:aliases) || {}))
    end

    # methods every generated struct already answers to; Ruby keywords are
    # checked alongside (RUBY_KEYWORDS is defined by the class this mixes into)
    ALIAS_RESERVED = %w[from_h serialize to_h].to_set.freeze
    # list selectors — pick one element out of a list-typed hop, always nilable
    # (the list may be empty). Everything else is a field prop.
    LIST_SELECTORS = %w[first last].freeze

    # Walk a dotted path through this struct's selected shape, building the
    # delegator expression (`meta&.tag`, `_entities.first&.name`) and its return
    # type. A segment is a field prop, or `first`/`last` to pick a list element.
    # Everything is checked against the node tree: a field on a non-object, a
    # selector on a non-list, or an unselected segment raises. Any nilable hop
    # (a nullable field, or a list element) makes the accessor nilable.
    def resolve_alias(node, name, segments)
      cur = T.let(node, T.untyped)           # the node the path has reached
      cur_nilable = T.let(false, T::Boolean) # is the expression so far nilable
      nilable = T.let(false, T::Boolean)     # is the accessor overall nilable
      containers = T.let([], T::Array[String]) # nested-struct class names on the way to the leaf
      expr = +""

      segments.each do |seg|
        connector = expr.empty? ? "" : (cur_nilable ? "&." : ".")

        # `first`/`last` select an element only when the current hop is actually a
        # list; otherwise they're an ordinary field (a schema field named `first`)
        if LIST_SELECTORS.include?(seg) && list_of(cur)
          expr << connector << seg
          cur = list_of(cur).of
          cur_nilable = true # first/last is nil on an empty list
          nilable = true
        else
          obj = object_of(cur)
          unless obj
            hint = if list_of(cur)
              " — use .first or .last to pick an element"
            elsif LIST_SELECTORS.include?(seg)
              " — .#{seg} needs a list"
            else
              ""
            end
            raise GraphWeaver::Error,
              "alias #{name.inspect} on #{node.graphql_type}: '#{seg}' can't be read here (not an object)#{hint}"
          end
          # the object a field is read from is the lexical container of its result
          # (nested structs emit inside their parent); the aliased struct itself is
          # the delegator's own scope, so it contributes no prefix
          containers << obj.class_name unless obj.equal?(node)
          field = obj.fields.find { |f| f.prop == seg }
          unless field
            props = obj.fields.map(&:prop)
            suggestion = GraphWeaver.did_you_mean(props, seg)
            hint = suggestion ? " — did you mean '#{suggestion}'?" : " (have: #{props.join(", ")})"
            raise GraphWeaver::Error,
              "alias #{name.inspect} on #{node.graphql_type}: '#{seg}' is not a selected field#{hint}"
          end
          expr << connector << seg
          cur = field.node
          cur_nilable = !field.node.non_null?
          nilable ||= cur_nilable
        end
      end

      leaf = qualified_alias_type(cur, containers)
      type = nilable && leaf != "T.untyped" ? "T.nilable(#{leaf})" : leaf
      ObjectNode::Alias.new(name, expr, type)
    end

    # The leaf's Sorbet type as referenced from the aliased struct. Generated
    # nested constants (structs, enums, unions) must carry the container path,
    # since the delegator's `sig` is emitted in an outer struct where a bare
    # `Sub` wouldn't resolve; scalars, mapped enums, and hoisted union refs are
    # already top-level. `containers` is the class-name chain to the leaf.
    def qualified_alias_type(node, containers)
      node = node.of if node.is_a?(NonNull)
      prefix = containers.empty? ? "" : "#{containers.join("::")}::"

      case node
      when List
        element = node.of.is_a?(NonNull) ? qualified_alias_type(node.of, containers) : begin
          inner = qualified_alias_type(node.of, containers)
          inner == "T.untyped" ? inner : "T.nilable(#{inner})"
        end
        "T::Array[#{element}]"
      when ObjectNode, NarrowedNode then "#{prefix}#{node.class_name}"
      # a reused variable enum is emitted at module level (see Emit#module_level?),
      # so it takes no container prefix
      when EnumNode then "#{@variable_enums.value?(node) ? "" : prefix}#{node.class_name}"
      when UnionNode then "#{prefix}#{node.bare_type}"
      else node.bare_type # Scalar, MappedEnum, UnionRefNode — already top-level
      end
    end

    # the List a node wraps (through NON_NULL), or nil
    def list_of(node)
      node = T.let(node, T.untyped)
      node = node.of while node.is_a?(NonNull)
      node if node.is_a?(List)
    end

    # the ObjectNode a node resolves to for field access (through NON_NULL and a
    # narrowed abstract member), or nil — unions/scalars/lists can't be read into
    def object_of(node)
      node = T.let(node, T.untyped)
      node = node.of while node.is_a?(NonNull)
      node = node.nested if node.is_a?(NarrowedNode)
      node if node.is_a?(ObjectNode)
    end
  end
end
