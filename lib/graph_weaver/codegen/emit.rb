# typed: true
# frozen_string_literal: true

# Source emission: turns the node tree into the generated module text.
# Mixed into Codegen — methods run with the generator instance state.
class GraphWeaver::Codegen
  module Emit
    include Kernel # for sorbet: hosts are Objects
    include GraphWeaver::Inflect

    private

    # The Relay convention — an operation whose only variable is a required
    # input object — reads better flattened: the input's fields become
    # execute's kwargs directly, and the wrapping level is rebuilt on the
    # wire. Multi-variable (or nullable-input) operations keep the
    # variable-per-kwarg surface.
    def flatten_input(variables)
      return unless variables.size == 1

      var = variables.first
      return unless var.required && var.node.is_a?(NonNull)

      input = var.node.of
      return unless input.is_a?(InputNode)
      # Flattening is the one place an input field's name has to be a legal Ruby
      # identifier — a keyword, or one of execute's own locals, can't be a kwarg.
      # Unlike a variable name the user can't rename it, so keep the wrapping level.
      return if input.fields.any? { |field| RESERVED_KWARGS.include?(field.prop) || RUBY_KEYWORDS.include?(field.prop) }

      input
    end

    def input_references(node)
      node.fields.filter_map do |field|
        child = field.node
        child = child.of while child.respond_to?(:of)
        child if child.is_a?(InputNode)
      end
    end

    # Input structs in dependency order (referenced types before their
    # referrers) so each emitted const names an already-defined class.
    # Cycles make that impossible — flagged so emission can forward-declare
    # every input class first, then reopen each to add its props.
    def ordered_inputs
      ordered = []
      seen = {} # node => :done | :visiting (bool_exp graphs get big)
      cyclic = T.let(false, T::Boolean)

      visit = lambda do |node|
        next if seen[node] == :done

        if seen[node] == :visiting
          cyclic = true
          next
        end

        seen[node] = :visiting
        input_references(node).each(&visit)
        seen[node] = :done
        ordered << node
      end
      @variable_inputs.each_value(&visit)

      [ordered, cyclic]
    end

      # Mapped-enum tables, generated enums, and input structs
      # (dependency-ordered, forward-declared when cyclic) — inline in the
      # module that needs them, unless a shared module already holds them (then
      # the module aliases them instead; see emit_shared_aliases).
      def emit_variable_types(out)
          emit_enum_types(out) unless @enums_namespace
          return if @inputs_namespace

          inputs, cyclic = ordered_inputs
          if cyclic
            # Recursive input types (Hasura bool_exp et al) reference each other,
            # so no definition order satisfies the runtime — forward-declare every
            # class empty, then let the full definitions below reopen with props.
            # eval'd so srb sees only the full bodies (reopening a T::Struct to
            # add props is a static error; adding them at runtime is fine).
            out << "  # runtime-only forward declarations: these input types reference"
            out << "  # each other, so the full definitions below need the constants"
            out << "  eval(<<~RUBY, binding, __FILE__, __LINE__ + 1)"
            inputs.each { |input| out << "    class #{input.class_name} < T::Struct; end" }
            out << "  RUBY"
            out << ""
          end
          inputs.each do |input|
            emit_input(input, out, 1)
            out << ""
          end
        end

      # Every schema enum this walk touched, at module level: wire tables for
      # the ones mapped onto an app enum, a T::Enum for the rest.
      def emit_enum_types(out, indent = 1)
        @mapped_enums.each_value do |mapped|
          emit_mapped_enum(mapped, out, indent)
          out << ""
        end
        @enums.each_value do |enum|
          emit_enum(enum, out, indent)
          out << ""
        end
      end

      # In the shared workflow the types live once in their shared module and
      # each query module aliases what it uses, so AdoptMutation::AdoptionInput
      # stays a real constant — and a shared type keeps ONE identity across
      # every module that touches it.
      #
      # Enums: every one this walk reached, since a result field and a variable
      # both reference it by that name.
      def shared_enum_names
        @mapped_enums.each_value.flat_map { |m| ["#{m.const_prefix}_FROM_WIRE", "#{m.const_prefix}_TO_WIRE"] } +
          @enums.each_value.map(&:class_name)
      end

      # Inputs: only the variable root types (and, when flattened, the root
      # input's field types) — the names this module's own source spells.
      # Nested input types stay un-aliased; they live in the inputs module.
      def shared_input_names(variables, flatten)
        nodes = variables.map(&:node)
        nodes += flatten.fields.map(&:node) if flatten

        nodes.filter_map { |wrapped|
          node = T.let(wrapped, T.untyped)
          node = node.of while node.is_a?(NonNull) || node.is_a?(List)
          node.class_name if node.is_a?(InputNode)
        }.uniq
      end

      def emit_shared_aliases(out, names, namespace)
        return if names.empty?

        names.each { |name| out << "  #{name} = #{namespace}::#{name}" }
        out << ""
      end

      # The shared inputs artifact as files: inputs.rb (the manifest —
      # requires, forward declarations for every struct so definition
      # order never matters, then one require per type file) plus
      # inputs/<type>.rb per enum/mapped-table/input struct.
      def emit_inputs_files
        files = {}
        struct_files = []
        inputs, = ordered_inputs
        inputs.each do |input|
          struct_files << inputs_file(files, input.class_name) { |out| emit_input(input, out, 1) }
        end

        manifest = []
        manifest << "# typed: strict"
        manifest << "# frozen_string_literal: true"
        manifest << ""
        manifest << "# Generated by GraphWeaver — do not edit. Shared variable types for"
        manifest << "# this schema, one file per type; query modules alias what they use."
        manifest << ""
        requires = @requires.uniq.sort
        if requires.any?
          requires.each { |req| manifest << "require #{req.inspect}" }
          manifest << ""
        end
        manifest << "module #{@module_name}; end"
        manifest << ""
        # input fields typed as enums spell them bare, so alias the shared ones
        # into this module before any struct body loads
        enums = shared_enum_names
        if enums.any?
          manifest << "require_relative \"enums\""
          manifest << ""
          manifest << "module #{@module_name}"
          enums.each { |name| manifest << "  #{name} = #{@enums_namespace}::#{name}" }
          manifest << "end"
        end
        if inputs.any?
          manifest << ""
          manifest << "# runtime-only forward declarations: input types reference each"
          manifest << "# other across files, so every constant must exist before any"
          manifest << "# definition loads (srb sees only the full bodies)"
          manifest << "module #{@module_name}"
          manifest << "  eval(<<~RUBY, binding, __FILE__, __LINE__ + 1)"
          inputs.each { |input| manifest << "    class #{input.class_name} < T::Struct; end" }
          manifest << "  RUBY"
          manifest << "end"
          manifest << ""
          struct_files.sort.each { |file| manifest << "require_relative #{file.delete_suffix(".rb").inspect}" }
        end

        files["inputs.rb"] = manifest.join("\n") + "\n"
        files
      end

      # The shared enums artifact as a single file: one Ruby type per schema
      # enum, so every query module aliases the same constant.
      def emit_enums_file
        out = []
        out << "# typed: strict"
        out << "# frozen_string_literal: true"
        out << ""
        out << "# Generated by GraphWeaver — do not edit. Shared enum types for this"
        out << "# schema; query modules alias what they use."
        out << ""
        requires = @requires.uniq.sort
        if requires.any?
          requires.each { |req| out << "require #{req.inspect}" }
          out << ""
        end
        out << "module #{@module_name}"
        emit_enum_types(out)
        out.pop if out.last == ""
        out << "end"

        { "enums.rb" => out.join("\n") + "\n" }
      end

      # The shared unions artifact as a single file: every hoisted union as a
      # <module_name>::<Name> module. Unions don't cross-reference (each is a
      # self-contained fragment), so there's no need for per-type files or the
      # forward declarations recursive input types require.
      def emit_unions_file(unions)
        out = []
        out << "# typed: strict"
        out << "# frozen_string_literal: true"
        out << ""
        out << "# Generated by GraphWeaver — do not edit. Shared union types for this"
        out << "# schema (named fragments on union fields); query modules alias what they use."
        out << ""
        requires = @requires.uniq.sort
        if requires.any?
          requires.each { |req| out << "require #{req.inspect}" }
          out << ""
        end
        out << "require_relative \"enums\"" << "" if @enums_namespace && shared_enum_names.any?
        out << "module #{@module_name}"
        out << "  extend T::Sig" << "" if GraphWeaver.extend_t_sig?
        # a member selecting an enum spells it bare — alias the shared ones, or
        # (with no shared module) emit them here, the same way a query module does
        if @enums_namespace
          emit_shared_aliases(out, shared_enum_names, @enums_namespace)
        else
          emit_enum_types(out)
        end
        unions.each do |union|
          emit_union(union, out, 1)
          out << ""
        end
        out.pop if out.last == ""
        out << "end"

        { "unions.rb" => out.join("\n") + "\n" }
      end

      # one type per file, wrapped in the namespace so bare sibling
      # references resolve lexically
      def inputs_file(files, name)
        out = []
        out << "# typed: strict"
        out << "# frozen_string_literal: true"
        out << ""
        out << "# Generated by GraphWeaver — do not edit."
        out << ""
        out << "module #{@module_name}"
        yield(out)
        out << "end"

        file = "inputs/#{GraphWeaver::Inflect.underscore(name)}.rb"
        files[file] = out.join("\n") + "\n"
        file
      end

    # The whole generated file: header, requires, the QUERY heredoc and
    # its OPERATION_NAME, enum tables, input structs (dependency-ordered,
    # forward-declared when cyclic), the Result tree, and execute —
    # assembled from the generator's walked state.
    def emit_module(root, variables, representations = [], operation_name = nil)
      flatten = flatten_input(variables)
      input_aliases = @inputs_namespace ? shared_input_names(variables, flatten) : []
      enum_aliases = @enums_namespace ? shared_enum_names : []
      # hoisted unions the result tree references, aliased so <Name>::Type and
      # <Name>.from_h resolve to the shared module
      union_aliases = @used_unions.map { |name| camelize(name) }.uniq.sort

      out = []
      out << "# typed: strict"
      out << "# frozen_string_literal: true"
      out << ""
      out << "# Generated by GraphWeaver — do not edit."
      out << ""
      requires = @requires.uniq.sort
      if requires.any?
        requires.each { |req| out << "require #{req.inspect}" }
        out << ""
      end
      # the aliases below need their shared modules loaded (same directory by
      # the generate! convention)
      shared = { "enums" => enum_aliases, "inputs" => input_aliases, "unions" => union_aliases }
        .select { |_, names| names.any? }
      if shared.any?
        shared.each_key { |file| out << "require_relative #{file.inspect}" }
        out << ""
      end
      out << "module #{@module_name}"
      out << "  extend T::Sig" << "" if GraphWeaver.extend_t_sig?
      # a GraphQL block string could contain a bare GRAPHQL line, which
      # would terminate the heredoc early — pick a delimiter the query
      # can't collide with
      delimiter = "GRAPHQL"
      delimiter += "_" while @query.match?(/^\s*#{delimiter}\s*$/)
      out << "  QUERY = T.let(<<~'#{delimiter}', String)"
      @query.each_line { |line| out << "    #{line}".rstrip }
      out << "  #{delimiter}"
      out << ""
      out << "  # sent as the request's operationName — what an APM keys traces on"
      out << "  OPERATION_NAME = T.let(#{operation_name.inspect}, T.nilable(String))"
      out << ""
      # aliases first: an inline input struct's props spell enum names bare
      emit_shared_aliases(out, enum_aliases, @enums_namespace)
      emit_shared_aliases(out, input_aliases, @inputs_namespace)
      emit_shared_aliases(out, union_aliases, @unions_namespace)
      emit_variable_types(out)
      emit_representations(out, representations)
      emit_nested(root, out, 1)
      out << ""
      emit_execute(out, variables, flatten:)
      out << "end"

      out.join("\n") + "\n"
    end

    # Typed constructors for the entity references an
    # `_entities(representations:)` query takes — one per entity the query's
    # selection reaches, its kwargs the type's @key fields. A single-key
    # entity types them required, so an incomplete representation is a
    # Sorbet error rather than a round trip; alternative keys and nested key
    # sets are what GraphWeaver::Representation.build checks at runtime.
    def emit_representations(out, nodes)
      return if nodes.empty?

      out << "  # Entity references for _entities(representations:) — one builder"
      out << "  # per entity this query can resolve, typed from its @key fields."
      out << "  module Representations"
      out << "    extend T::Sig" if GraphWeaver.extend_t_sig?

      nodes.each do |node|
        out << ""
        out << "    # #{node.graphql_type} #{node.key_fields.map { |set| "@key(fields: #{set.inspect})" }.join(" ")}"
        sig = node.params.map { |param| "#{param.kwarg}: #{param.type}" }.join(", ")
        out << "    sig { params(#{sig}).returns(T::Hash[String, T.untyped]) }"
        kwargs = node.params.map { |param| param.required ? "#{param.kwarg}:" : "#{param.kwarg}: nil" }.join(", ")
        out << "    def self.#{node.method_name}(#{kwargs})"
        out << "      GraphWeaver::Representation.build(#{node.graphql_type.inspect}, {"
        node.params.each { |param| out << "        #{param.wire.inspect} => #{param.value}," }
        out << "      }, #{node.key_sets.inspect})"
        out << "    end"
      end

      out << "  end"
      out << ""
    end

    # Is this node defined once at module level rather than inside the struct
    # that references it? (Variable enums — see the ENUM branch of object_node.)
    def module_level?(node)
      @enums.value?(node)
    end

    def emit_nested(node, out, indent)
      case node
      when UnionNode then emit_union(node, out, indent)
      when EnumNode then emit_enum(node, out, indent)
      else emit_object(node, out, indent)
      end
    end

    def emit_enum(node, out, indent)
      pad = "  " * indent

      out << "#{pad}class #{node.class_name} < T::Enum"
      out << "#{pad}  enums do"
      node.values.each do |value|
        out << "#{pad}    #{camelize(value.downcase)} = new(#{value.inspect})"
      end
      out << "#{pad}  end"
      out << "#{pad}end"
    end

    # module-level wire translation tables for an app-mapped enum
    def emit_mapped_enum(node, out, indent)
      pad = "  " * indent
      type = node.bare_type
      prefix = node.const_prefix

      out << "#{pad}# GraphQL enum #{node.graphql_name} <-> #{type} (registered mapping)"
      out << "#{pad}#{prefix}_FROM_WIRE = T.let({"
      node.mapping.each do |wire, member|
        out << "#{pad}  #{wire.inspect} => #{type}.deserialize(#{member.serialize.to_s.inspect}),"
      end
      out << "#{pad}}.freeze, T::Hash[String, #{type}])"
      out << "#{pad}#{prefix}_TO_WIRE = T.let(#{prefix}_FROM_WIRE.invert.freeze, T::Hash[#{type}, String])"
    end

    def emit_object(node, out, indent)
      pad = "  " * indent

      out << "#{pad}class #{node.class_name} < T::Struct"
      out << "#{pad}  extend T::Sig" if GraphWeaver.extend_t_sig?
      out << "#{pad}  include GraphWeaver::Hints"
      node.mixins.each do |mixin|
        out << "#{pad}  include #{mixin} # registered for #{node.graphql_type}"
      end
      out << ""

      # uniq by object identity: deduped sibling unions share one node, so the
      # shared type is emitted once (both fields' consts already reference it).
      # A variable enum a result field reuses is already defined at module
      # level (or aliased from the shared inputs module) — redefining it here
      # would shadow the shared type back apart.
      children = node.fields.filter_map { |field| field.node.nested }.uniq
      children.reject { |child| module_level?(child) }.each do |child|
        emit_nested(child, out, indent + 1)
        out << ""
      end

      node.fields.each do |field|
        out << "#{pad}  const :#{field.prop}, #{field.node.prop_type}"
      end

      out << ""
      out << "#{pad}  sig { params(data: T::Hash[String, T.untyped]).returns(#{node.class_name}) }"
      out << "#{pad}  def self.from_h(data)"
      out << "#{pad}    new("
      node.fields.each do |field|
        out << "#{pad}      #{field.prop}: #{field_cast(field)},"
      end
      out << "#{pad}    )"
      out << "#{pad}  rescue GraphWeaver::Error"
      out << "#{pad}    raise # already branded by a nested struct — keep the innermost context"
      out << "#{pad}  rescue StandardError => e" # a scalar's cast may raise anything
      out << "#{pad}    raise GraphWeaver::TypeError.new(struct: self, error: e)"
      out << "#{pad}  end"

      # alias delegators (extend_type alias:) — typed accessors that project a
      # selected field onto the struct, next to the honest wire data
      node.aliases.each do |a|
        out << ""
        out << "#{pad}  sig { returns(#{a.type}) }"
        out << "#{pad}  def #{a.name} = #{a.expr}"
      end
      out << "#{pad}end"
    end

    def emit_union(node, out, indent)
      pad = "  " * indent

      out << "#{pad}module #{node.class_name}"
      out << "#{pad}  extend T::Sig" << "" if GraphWeaver.extend_t_sig?

      structs = node.members.values + [node.catch_all].compact
      structs.each do |member|
        emit_object(member, out, indent + 1)
        out << ""
      end

      member_names = structs.map(&:class_name)
      type_alias = member_names.size == 1 ? member_names.first : "T.any(#{member_names.join(", ")})"
      out << "#{pad}  Type = T.type_alias { #{type_alias} }"
      out << ""
      out << "#{pad}  sig { params(data: T::Hash[String, T.untyped]).returns(Type) }"
      out << "#{pad}  def self.from_h(data)"
      if node.catch_all
        out << "#{pad}    case data.fetch(\"__typename\")"
      else
        out << "#{pad}    case (typename = data.fetch(\"__typename\"))"
      end
      node.members.each do |graphql_name, member|
        out << "#{pad}    when #{graphql_name.inspect} then #{member.class_name}.from_h(data)"
      end
      if node.catch_all
        out << "#{pad}    # a member this query names no fields on — including one the"
        out << "#{pad}    # schema grew since generation"
        out << "#{pad}    else #{node.catch_all.class_name}.from_h(data)"
      else
        out << "#{pad}    else raise GraphWeaver::TypeError.new(struct: self, message: \"unexpected __typename: \#{typename}\")"
      end
      out << "#{pad}    end"
      out << "#{pad}  end"
      out << "#{pad}end"
    end

    def emit_execute(out, variables, flatten: nil)
      # client/client= carry no per-query types, so they live in the gem
      out << "  # client / client= — see GraphWeaver::QueryModule"
      out << "  extend GraphWeaver::QueryModule"
      if @client_const
        out << ""
        out << "  # the baked default client, resolved on first use"
        out << "  DEFAULT_CLIENT = T.let(-> { #{@client_const} }, T.proc.returns(T.untyped))"
      end
      out << ""

      # the kwarg surface: the input's fields when flattened, else one
      # kwarg per declared variable — typed identically either way. The
      # per-call client override rides as an optional POSITIONAL arg, so
      # only this body's own locals (RESERVED_KWARGS) are off limits.
      params = flatten ? flatten.fields.partition(&:required).flatten : variables

      sig_params = ["client: T.untyped"]
      sig_params += params.map do |param|
        bare = param.node.coerce? ? param.node.coerce_input_type : param.node.bare_type
        kwarg_type = param.required || bare == "T.untyped" ? bare : "T.nilable(#{bare})"
        "#{kwarg_name(param)}: #{kwarg_type}"
      end

      kwargs = ["client = nil"]
      kwargs += params.map { |param| param.required ? "#{kwarg_name(param)}:" : "#{kwarg_name(param)}: nil" }

      # execute returns the full envelope; execute! is the strict shortcut for
      # `execute(...).data!` — the typed result, or a raised QueryError.
      # kwargs forward via hash shorthand (key == value)
      forward = (["client"] + params.map { |param| "#{kwarg_name(param)}:" }).join(", ")

      if flatten
        out << "  # $#{variables.first.wire}'s fields, flattened into kwargs (single input-object variable)"
      end
      out << "  sig { params(#{sig_params.join(", ")}).returns(GraphWeaver::Response[Result]) }"
      out << "  def self.execute(#{kwargs.join(", ")})"

      if flatten
        fields = flatten.fields.map { |field| "#{field.prop}:" }.join(", ")
        out << "    variables = {"
        out << "      #{variables.first.wire.inspect} => #{flatten.class_name}.coerce({ #{fields} }).serialize,"
        out << "    }"
      else
        required, optional = variables.partition(&:required)
        if required.empty?
          out << "    variables = {}"
        else
          out << "    variables = {"
          required.each do |var|
            out << "      #{var.wire.inspect} => #{variable_serialize(var)},"
          end
          out << "    }"
        end
        optional.each do |var|
          out << "    variables[#{var.wire.inspect}] = #{variable_serialize(var)} unless #{var.kwarg}.nil?"
        end
      end

      out << ""
      out << "    transport = GraphWeaver.resolve_transport(client || self.client)"
      out << "    from_response(transport.execute(QUERY, variables:, operation_name: OPERATION_NAME))"
      out << "  end"
      out << ""
      out << "  sig { params(#{sig_params.join(", ")}).returns(Result) }"
      out << "  def self.execute!(#{kwargs.join(", ")})"
      out << "    execute(#{forward}).data!"
      out << "  end"
      out << ""
      emit_from_response(out)
    end

    # The network-free half of execute: deserialize a raw GraphQL response
    # into the typed envelope. For responses fetched by any other client —
    # execute delegates here after the transport call. Accepts the response
    # hash (or anything with #to_h, e.g. a schema result): {"data" => ...,
    # "errors" => ..., "extensions" => ...} with wire-cased string keys.
    def emit_from_response(out)
      out << "  # Deserialize a raw GraphQL response into the typed envelope — the"
      out << "  # network-free half of execute, for responses fetched by any client."
      out << "  # Takes the response hash (or anything with #to_h): {\"data\" => ...,"
      out << "  # \"errors\" => ..., \"extensions\" => ...} with wire-cased string keys."
      out << "  sig { params(response: T.untyped).returns(GraphWeaver::Response[Result]) }"
      out << "  def self.from_response(response)"
      out << "    raw = GraphWeaver.check_envelope!(response.to_h, Result)"
      out << "    GraphWeaver::Response[Result].new("
      out << "      data: (Result.from_h(raw[\"data\"]) if raw[\"data\"]),"
      out << "      errors: (raw[\"errors\"] || []).map { |e| GraphWeaver::GraphQLError.from_h(e) },"
      out << "      extensions: raw[\"extensions\"] || {},"
      out << "    )"
      out << "  end"
      out << ""
      out << "  # from_response + data! — the typed result, or a raised QueryError."
      out << "  sig { params(response: T.untyped).returns(Result) }"
      out << "  def self.from_response!(response)"
      out << "    from_response(response).data!"
      out << "  end"
    end

    # a kwarg surface entry is a VarDef (.kwarg) or, when flattened, an
    # InputNode::Field (.prop)
    def kwarg_name(param)
      param.respond_to?(:kwarg) ? param.kwarg : param.prop
    end

    def variable_serialize(var)
      value = var.node.coerce? ? var.node.coerce(var.kwarg) : var.kwarg
      var.node.serialize_identity? ? value : var.node.serialize(value, 1)
    end

    def field_cast(field)
      node = field.node

      if node.non_null?
        raw = "data.fetch(#{field.key.inspect})"
        node.identity? ? raw : node.cast(raw, 1)
      else
        raw = "data[#{field.key.inspect}]"
        node.identity? ? raw : "#{raw}&.then { |v1| #{node.cast("v1", 2)} }"
      end
    end

    # A module-level T::Struct per input type: typed consts plus a FIELDS
    # table the GraphWeaver::InputStruct runtime drives — serialize/to_h/
    # coerce live once in the gem, not unrolled per struct (bool_exp
    # schemas pull hundreds of inputs into one module).
    def emit_input(node, out, indent)
      pad = "  " * indent

      out << "#{pad}class #{node.class_name} < T::Struct"
      out << "#{pad}  include GraphWeaver::InputStruct"
      out << "#{pad}  extend GraphWeaver::InputStruct::ClassMethods"
      out << ""
      if node.one_of
        out << "#{pad}  # @oneOf: every field is nullable, so exactly-one is checked at runtime"
        out << "#{pad}  ONE_OF = T.let(true, T::Boolean)"
        out << ""
      end
      node.fields.each do |field|
        default = field.required ? "" : ", default: nil"
        out << "#{pad}  const :#{field.prop}, #{field.node.prop_type}#{default}"
      end
      out << ""
      out << "#{pad}  # (prop, wire, required, serializer, coercer) per field"
      out << "#{pad}  FIELDS = T.let(["
      node.fields.each do |field|
        serializer = field.node.serialize_identity? ? "nil" : "->(v) { #{field.node.serialize("v", 1)} }"
        coercer = field.node.hash_coerce_identity? ? "nil" : "->(v) { #{field.node.hash_coerce("v", 1)} }"
        out << "#{pad}    GraphWeaver::InputStruct::Field.new(:#{field.prop}, #{field.wire.inspect}, #{field.required}, #{serializer}, #{coercer}),"
      end
      out << "#{pad}  ].freeze, T::Array[GraphWeaver::InputStruct::Field])"
      out << "#{pad}end"
    end
  end
end
