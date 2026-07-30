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

  # snapshot/restore the global type registry so aliases don't leak between examples
  around do |example|
    saved = GraphWeaver::Codegen.type_registry.dup
    example.run
  ensure
    reg = GraphWeaver::Codegen.type_registry
    reg.clear
    reg.merge!(saved)
  end

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

  it "rejects a path that traverses a list" do
    GraphWeaver.extend_type("Widget", alias: { code: "bits.code" })
    expect { generate("query W { widget { bits { code } } }") }
      .to raise_error(GraphWeaver::Error, /list/)
  end

  it "rejects an accessor name that collides with a selected field" do
    GraphWeaver.extend_type("Widget", alias: { name: "meta.tag" })
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
end
