# typed: true
# frozen_string_literal: true

# Source emission: turns the node tree into the generated module text.
# Mixed into Codegen — methods run with the generator instance state.
class GraphWeaver::Codegen
  module Emit
    include Kernel # for sorbet: hosts are Objects
    include GraphWeaver::Inflect

    private

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
    # module that needs them, unless the shared module already holds them
    # (then the module aliases them instead; see emit_shared_aliases).
    def emit_variable_types(out)
      return if @types_namespace

      emit_enum_types(out)
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

    # In the shared workflow the types live once in the shared module and each
    # query module aliases what it uses, so AdoptMutation::AdoptionInput stays a
    # real constant — and a shared type keeps ONE identity across every module
    # that touches it.
    #
    # Enums: every one this walk reached, since a result field and a variable
    # both reference it by that name.
    def shared_enum_names
      @mapped_enums.each_value.flat_map { |m| ["#{m.const_prefix}_FROM_WIRE", "#{m.const_prefix}_TO_WIRE"] } +
        @enums.each_value.map(&:class_name)
    end

    # Inputs: only the variable root types — the names this module's own
    # source spells. Nested input types stay un-aliased; they live in the
    # shared module.
    def shared_input_names(variables)
      variables.map(&:node).filter_map { |wrapped|
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

    # The shared types artifact as files: one file per type under types/, plus
    # types.rb — the manifest that requires them in the order the runtime needs
    # (see below). One rule for all three kinds, so a schema migration diffs
    # exactly the types it touched whether they're inputs, enums or unions.
    def emit_types_files(unions)
      files = {}
      # a mapped enum's constants are its wire tables, but the file is still
      # named for the GraphQL enum — one type, one file, whichever it is
      enums = @mapped_enums.map { |name, mapped|
        type_file(files, camelize(name)) { |out| emit_mapped_enum(mapped, out, 1) }
      } + @enums.each_value.map { |enum|
        type_file(files, enum.class_name) { |out| emit_enum(enum, out, 1) }
      }
      inputs, = ordered_inputs
      structs = inputs.map { |input| type_file(files, input.class_name) { |out| emit_input(input, out, 1) } }
      hoisted = unions.map { |union| type_file(files, union.class_name) { |out| emit_union(union, out, 1) } }

      out = []
      out << "# typed: strict"
      out << "# frozen_string_literal: true"
      out << ""
      out << "# Generated by GraphWeaver — do not edit. Shared types for this schema —"
      out << "# input types, enums, and unions hoisted from shared fragments — one file"
      out << "# per type; query modules alias what they use."
      out << ""
      requires = @requires.uniq.sort
      if requires.any?
        requires.each { |req| out << "require #{req.inspect}" }
        out << ""
      end
      out << "module #{@module_name}; end"
      out << ""
      if inputs.any?
        out << "# runtime-only forward declarations: input types reference each other"
        out << "# across files, so every constant must exist before any definition loads"
        out << "# (srb sees only the full bodies)"
        out << "module #{@module_name}"
        out << "  eval(<<~RUBY, binding, __FILE__, __LINE__ + 1)"
        inputs.each { |input| out << "    class #{input.class_name} < T::Struct; end" }
        out << "  RUBY"
        out << "end"
        out << ""
      end
      # enums first: an input struct's props and a union member's selections
      # both spell them bare, and a T::Enum can't be forward-declared the way
      # an input struct can
      if enums.any? && (structs.any? || hoisted.any?)
        out << "# enums first — input structs and union members spell them bare"
      end
      (enums.sort + structs.sort + hoisted.sort).each do |file|
        out << "require_relative #{file.delete_suffix(".rb").inspect}"
      end

      files["types.rb"] = out.join("\n") + "\n"
      files
    end

    # one type per file, wrapped in the shared module so bare sibling
    # references resolve lexically
    def type_file(files, name)
      out = []
      out << "# typed: strict"
      out << "# frozen_string_literal: true"
      out << ""
      out << "# Generated by GraphWeaver — do not edit."
      out << ""
      out << "module #{@module_name}"
      yield(out)
      out << "end"

      file = "types/#{GraphWeaver::Inflect.underscore(name)}.rb"
      files[file] = out.join("\n") + "\n"
      file
    end

    # The whole generated file: header, requires, the QUERY heredoc and
    # its OPERATION_NAME, enum tables, input structs (dependency-ordered,
    # forward-declared when cyclic), the Result tree, and execute —
    # assembled from the generator's walked state.
    def emit_module(root, variables, representations = [], operation_name = nil)
      # Every shared type this module names: its variable root inputs, the
      # enums it reached, and the unions it hoisted (aliased so <Name>::Type
      # and <Name>.from_h resolve to the shared module).
      aliases = if @types_namespace
        (shared_input_names(variables) + shared_enum_names +
          @used_unions.map { |name| camelize(name) }).uniq.sort
      else
        []
      end

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
      # the aliases below need the shared module loaded (same directory by the
      # generate! convention)
      if aliases.any?
        out << "require_relative \"types\""
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
      emit_shared_aliases(out, aliases, @types_namespace)
      emit_variable_types(out)
      emit_representations(out, representations)
      emit_nested(root, out, 1)
      out << ""
      emit_execute(out, variables)
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

      # Builders are query-driven, so an entity the `_entities` selection
      # doesn't name has none — a bare NoMethodError there points at nothing.
      out << ""
      out << "    BUILDERS = T.let(#{nodes.map(&:method_name).sort.inspect}.freeze, T::Array[String])"
      out << "    private_constant :BUILDERS"
      out << ""
      out << "    sig { params(name: Symbol, args: T.untyped, block: T.untyped).returns(T.noreturn) }"
      out << "    def self.method_missing(name, *args, &block)"
      out << '      type = GraphWeaver::Inflect.camelize(name.to_s)'
      out << '      raise NoMethodError, "no representation builder for #{type} (this query builds: ' \
        '#{BUILDERS.join(", ")}) — if #{type} is an entity of this subgraph, name it in the ' \
        '_entities selection (`... on #{type} { __typename }`) and regenerate"'
      out << "    end"

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

    def emit_execute(out, variables)
      # client/client= carry no per-query types, so they live in the gem
      out << "  # client / client= — see GraphWeaver::QueryModule"
      out << "  extend GraphWeaver::QueryModule"
      if @client_const
        out << ""
        out << "  # the baked default client, resolved on first use"
        out << "  DEFAULT_CLIENT = T.let(-> { #{@client_const} }, T.proc.returns(T.untyped))"
      end
      out << ""

      # The kwarg surface: one kwarg per declared variable, always — so the
      # call sites a query already has don't change shape when it grows one.
      # The per-call client override is a kwarg like the rest; a GraphQL
      # variable can't claim the name (RESERVED_KWARGS).
      #
      # Required kwargs first, then optional ones (client: last, since it
      # always has a default): Method#parameters reports them in that order
      # whatever the source says, and sorbet-runtime checks the sig against it.
      required, optional = variables.partition(&:required)
      ordered = required + optional

      sig_params = ordered.map do |var|
        bare = var.node.coerce? ? var.node.coerce_input_type : var.node.bare_type
        kwarg_type = var.required || bare == "T.untyped" ? bare : "T.nilable(#{bare})"
        "#{var.kwarg}: #{kwarg_type}"
      end
      sig_params << "client: T.untyped"

      kwargs = required.map { |var| "#{var.kwarg}:" } +
        optional.map { |var| "#{var.kwarg}: nil" } + ["client: nil"]

      # execute returns the full envelope; execute! is the strict shortcut for
      # `execute(...).data!` — the typed result, or a raised QueryError.
      # kwargs forward via hash shorthand (key == value)
      forward = (ordered.map { |var| "#{var.kwarg}:" } + ["client:"]).join(", ")

      out << "  sig { params(#{sig_params.join(", ")}).returns(GraphWeaver::Response[Result]) }"
      out << "  def self.execute(#{kwargs.join(", ")})"

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

      out << ""
      out << "    from_response(client_for(client).execute(QUERY, variables:, operation_name: OPERATION_NAME))"
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
        # A schema default makes the field optional here, so the prop has to
        # admit the nil that omitting it leaves behind — the same widening
        # execute's kwargs already get.
        type = field.node.prop_type
        type = "T.nilable(#{type})" if !field.required && field.node.non_null? && type != "T.untyped"
        default = field.required ? "" : ", default: nil"
        out << "#{pad}  const :#{field.prop}, #{type}#{default}"
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
