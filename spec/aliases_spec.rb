# typed: ignore — exercises eval-defined (parse) modules
# frozen_string_literal: true

RSpec.describe "extend_type alias: (path-projection accessors)" do
  let(:schema) do
    GraphQL::Schema.from_definition(<<~GRAPHQL)
      type Query { widget: Widget }
      type Widget { id: ID! name: String! meta: Meta bits: [Bit!]! }
      type Meta { tag: String! color: String }
      type Bit { code: String! }
    GRAPHQL
  end

  let(:query) { "query W { widget { id name meta { tag color } } }" }

  # the registry is global — clear it so aliases don't leak between examples
  after { GraphWeaver::Codegen.reset_type_helpers! }

  def generate(q = query)
    GraphWeaver::Codegen.generate(schema:, query: q, module_name: "W")
  end

  it "projects a nested nullable path (meta.tag) onto a typed accessor" do
    GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" })
    src = generate
    # meta is nullable, so the chain is nilable and nil-safe
    expect(src).to include("sig { returns(T.nilable(String)) }", "def tag = meta&.tag")
  end

  it "aliases a top-level field 1:1, preserving its non-null type" do
    GraphWeaver.extend_type("Widget", alias: { label: "name" })
    src = generate
    expect(src).to include("sig { returns(String) }", "def label = name")
  end

  it "accepts a bare path string, naming the accessor after the last segment" do
    GraphWeaver.extend_type("Widget", alias: "meta.tag")
    expect(generate).to include("def tag = meta&.tag")
  end

  it "accepts an array of paths" do
    GraphWeaver.extend_type("Widget", alias: ["meta.tag", "meta.color"])
    src = generate
    expect(src).to include("def tag = meta&.tag", "def color = meta&.color")
  end

  it "accepts a hash of multiple aliases and stacks across registrations" do
    GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" })
    GraphWeaver.extend_type("Widget", alias: { ident: "id" })
    src = generate
    expect(src).to include("def tag = meta&.tag", "def ident = id")
  end

  it "delegates at runtime, nil-safe through a null wrapper" do
    GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" })
    mod = GraphWeaver::Codegen.parse(schema:, query:, module_name: "W")

    got = mod.from_response!("data" => { "widget" => { "id" => "1", "name" => "n", "meta" => { "tag" => "T", "color" => nil } } })
    expect(got.widget.tag).to eq("T")

    none = mod.from_response!("data" => { "widget" => { "id" => "1", "name" => "n", "meta" => nil } })
    expect(none.widget.tag).to be_nil
  end

  it "field-traversing a list points you at .first/.last" do
    GraphWeaver.extend_type("Widget", alias: { code: "bits.code" })
    expect { generate("query W { widget { bits { code } } }") }
      .to raise_error(GraphWeaver::Error, /use \.first or \.last/)
  end

  it "picks a list element with .first (nilable) and can read into it" do
    GraphWeaver.extend_type("Widget", alias: { top_bit: "bits.first", top_code: "bits.first.code" })
    src = generate("query W { widget { bits { code } } }")
    expect(src).to include("sig { returns(T.nilable(Bits)) }", "def top_bit = bits.first")
    expect(src).to include("sig { returns(T.nilable(String)) }", "def top_code = bits.first&.code")
  end

  it "supports .last symmetrically" do
    GraphWeaver.extend_type("Widget", alias: { last_code: "bits.last.code" })
    expect(generate("query W { widget { bits { code } } }")).to include("def last_code = bits.last&.code")
  end

  it "rejects .first on a non-list" do
    GraphWeaver.extend_type("Widget", alias: { x: "name.first" })
    expect { generate }.to raise_error(GraphWeaver::Error, /needs a list/)
  end

  describe "optional: (lenient) aliases" do
    it "omits the accessor on a query whose selection doesn't fit the path" do
      GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" }, optional: true)
      # default query selects meta.tag -> accessor present
      expect(generate).to include("def tag = meta&.tag")
      # this query omits meta -> accessor skipped, no error
      src = generate("query W { widget { id } }")
      expect(src).not_to include("def tag")
    end

    it "still raises for a strict (default) alias on the same mismatch" do
      GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" })
      expect { generate("query W { widget { id } }") }
        .to raise_error(GraphWeaver::Error, /not a selected field/)
    end

    it "names the failing query and the opt-out when a strict alias breaks generation" do
      GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" })
      expect { generate("query W { widget { id } }") }
        .to raise_error(GraphWeaver::Error, /\AW: alias .* — pass optional: true to skip selections that don't fit\z/)
    end

    it "still raises on a segment the schema doesn't declare (a typo, not a fit)" do
      GraphWeaver.extend_type("Widget", alias: { x: "nmae" }, optional: true)
      expect { generate }.to raise_error(GraphWeaver::Error,
        %(W: alias "x" on Widget: 'nmae' is not a field of Widget — did you mean 'name'?))
    end

    it "points a wire-cased segment at the prop it should have been" do
      wire_schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { findPets: [Pet!]! }
        type Pet { id: ID! }
      GRAPHQL
      GraphWeaver.extend_type("Query", alias: { pets: "findPets.first" }, optional: true)

      expect { GraphWeaver::Codegen.generate(schema: wire_schema, query: "{ findPets { id } }", module_name: "Find") }
        .to raise_error(GraphWeaver::Error, %(Find: alias "pets" on Query: 'findPets' is not a field of Query ) +
          %(— GraphQL fields generate snake_case props; use 'find_pets'))
    end

    it "doesn't stutter when the module and the type share a name" do
      GraphWeaver.extend_type("Query", alias: { w: "widget.name" })
      expect { GraphWeaver::Codegen.generate(schema:, query: "{ widget { id } }", module_name: "Query") }
        .to raise_error(GraphWeaver::Error, /\Aalias "w" on Query: 'name' is not a selected field/)
    end
  end

  it "rejects an accessor name that collides with a selected field" do
    GraphWeaver.extend_type("Widget", alias: { name: "meta.tag" })
    expect { generate }.to raise_error(GraphWeaver::Error, /collides/)
  end

  # an alias emits a plain instance method, so a name the struct already
  # answers to is silently overridden rather than refused — and `hash` is
  # the one that hurts: every Hash and Set holding the struct breaks. A
  # wire field by that name is already refused, so an alias must be too.
  it "rejects an accessor name a struct instance already answers to" do
    GraphWeaver.extend_type("Widget", alias: { hash: "meta.tag" })
    expect { generate }.to raise_error(GraphWeaver::Error, /collides/)
  end

  it "rejects a path the query didn't select" do
    GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" })
    expect { generate("query W { widget { id } }") }
      .to raise_error(GraphWeaver::Error, /not a selected field/)
  end

  it "suggests the intended field on a near-miss segment (nested)" do
    GraphWeaver.extend_type("Widget", alias: { x: "meta.tagg" })
    expect { generate }.to raise_error(GraphWeaver::Error, /did you mean 'tag'/)
  end

  it "suggests the intended field on a near-miss segment (top level)" do
    GraphWeaver.extend_type("Widget", alias: { x: "nmae" })
    expect { generate }.to raise_error(GraphWeaver::Error, /did you mean 'name'/)
  end

  it "rejects an unknown keyword" do
    expect { GraphWeaver.extend_type("Widget", aliases: { tag: "meta.tag" }) }
      .to raise_error(ArgumentError, /unknown keyword/)
  end

  # the motivating case, end to end: a federation _entities query that resolves
  # one entity by key, read as a single typed object instead of an array
  describe "single-entity _entities accessor (end to end)" do
    let(:fed_schema) do
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { _entities(representations: [_Any!]!): [_Entity]! me: User }
        scalar _Any
        union _Entity = Widget | Gadget
        type Widget { id: ID! name: String! }
        type Gadget { id: ID! size: Int! }
        type User { id: ID! }
      GRAPHQL
    end

    it "reads the lone entity directly, typed as the concrete member" do
      GraphWeaver.extend_type("Query",
        alias: { entity: "_entities.first", entity_name: "_entities.first.name" }, optional: true)
      mod = GraphWeaver::Codegen.parse(schema: fed_schema, module_name: "Fetch",
        query: "query($r: [_Any!]!) { _entities(representations: $r) { ... on Widget { id name } } }")

      got = mod.from_response!("data" => { "_entities" => [{ "id" => "1", "name" => "Shelby" }] })
      expect(got.entity).to be_a(mod::Result::Entities) # concrete member, not the union
      expect(got.entity&.name).to eq "Shelby"
      expect(got.entity_name).to eq "Shelby"          # projected straight through
    end

    it "returns nil (not a crash) when no entity matched" do
      GraphWeaver.extend_type("Query", alias: { entity: "_entities.first" }, optional: true)
      mod = GraphWeaver::Codegen.parse(schema: fed_schema, module_name: "Fetch2",
        query: "query($r: [_Any!]!) { _entities(representations: $r) { ... on Widget { id name } } }")

      expect(mod.from_response!("data" => { "_entities" => [] }).entity).to be_nil
    end

    it "omits the accessor (optional) on a query that doesn't fetch entities" do
      GraphWeaver.extend_type("Query", alias: { entity: "_entities.first" }, optional: true)
      mod = GraphWeaver::Codegen.parse(schema: fed_schema, module_name: "Me", query: "query { me { id } }")

      expect(mod::Result.instance_methods).not_to include(:entity)
    end
  end

  describe "resolver correctness (review fixes)" do
    let(:nested_schema) do
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { widget: Widget }
        type Widget { id: ID! name: String! meta: Meta first: Thing }
        type Meta { tag: String! sub: Sub rank: Rank }
        type Sub { code: String! }
        type Thing { id: ID! }
        enum Rank { HIGH LOW }
      GRAPHQL
    end

    def gen2(aliases, q, **opts)
      GraphWeaver.extend_type("Widget", alias: aliases, **opts)
      GraphWeaver::Codegen.generate(schema: nested_schema, query: q, module_name: "W")
    end

    it "qualifies a deep object/enum leaf with its container path (not a bare constant)" do
      src = gen2({ s: "meta.sub", r: "meta.rank" }, "query W { widget { meta { sub { code } rank } } }")
      expect(src).to include("sig { returns(T.nilable(Meta::Sub)) }", "def s = meta&.sub")
      # an enum lives at module level (one Ruby type per schema enum), so it
      # takes no container prefix
      expect(src).to include("sig { returns(T.nilable(Rank)) }", "def r = meta&.rank")
    end

    it "rejects an alias name or path segment that isn't a plain identifier" do
      expect { GraphWeaver.extend_type("Widget", alias: { "x; puts :pwn" => "name" }) }
        .to raise_error(ArgumentError, /valid method name/)
      expect { GraphWeaver.extend_type("Widget", alias: { x: "" }) }
        .to raise_error(ArgumentError, /empty path/)
      expect { GraphWeaver.extend_type("Widget", alias: { x: "meta. " }) }
        .to raise_error(ArgumentError, /invalid path segment/)
    end

    it "does not let optional: swallow a reserved-name/collision error" do
      GraphWeaver.extend_type("Widget", alias: { serialize: "meta.tag" }, optional: true)
      expect { GraphWeaver::Codegen.generate(schema: nested_schema, query: "query W { widget { meta { tag } } }", module_name: "W") }
        .to raise_error(GraphWeaver::Error, /collides/)
    end

    it "qualifies a keyword-named first hop with self. (bare `next` is the keyword)" do
      schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { widget: Widget }
        type Widget { next: Meta }
        type Meta { tag: String! }
      GRAPHQL
      GraphWeaver.extend_type("Widget", alias: { cursor: "next", tag: "next.tag" })
      src = GraphWeaver::Codegen.generate(schema:, query: "query W { widget { next { tag } } }", module_name: "W")

      expect(src).to include("def cursor = self.next", "def tag = self.next&.tag")
    end

    it "reads a schema field named `first` as a field, not a list selector" do
      expect(gen2({ t: "first.id" }, "query W { widget { first { id } } }")).to include("def t = first&.id")
    end
  end

  describe "registration validation" do
    it "flags a global registration that names no type in the schema" do
      GraphWeaver.extend_type("Widgt", alias: { tag: "meta.tag" })
      expect { generate }.to raise_error(GraphWeaver::Error, /did you mean 'Widget'/)
    end

    it "checks requires: for loadability at registration" do
      expect { GraphWeaver.extend_type("Widget", Comparable, requires: "no/such/lib") }
        .to raise_error(ArgumentError, /not loadable/)
    end
  end

  # STRUCT_METHODS is derived from T::Struct so it tracks whatever is loaded;
  # ALIAS_RESERVED is the class-method half and can't be, since it is consulted
  # before any struct exists. So the list is checked against one instead — an
  # alias colliding with a real class method breaks the file at require time.
  it "reserves exactly the class methods a generated struct defines" do
    require_relative "generated/person_query"
    # minus what any T::Struct subclass answers to (sorbet-runtime hangs an
    # `inherited` off each one), leaving what generation itself added
    added = PersonQuery::Result::Person.singleton_methods(false) - Class.new(T::Struct).singleton_methods(false)

    expect(added.map(&:to_s).to_set).to eq GraphWeaver::Codegen::Aliases::ALIAS_RESERVED
  end
end
