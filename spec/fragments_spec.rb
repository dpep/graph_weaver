# typed: false
# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe "shared fragments" do
  def write(dir, name, content)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), content)
  end

  let(:schema) do
    GraphQL::Schema.from_definition(<<~GRAPHQL)
      type Query { people: [Person!]! }
      type Person { name: String! email: String! }
    GRAPHQL
  end

  describe "GraphWeaver::Codegen.load_fragments" do
    it "loads named fragments from the fragments path" do
      Dir.mktmpdir do |dir|
        write(dir, "person.graphql", "fragment PersonFields on Person { name email }")
        expect(GraphWeaver::Codegen.load_fragments([dir]).keys).to eq(["PersonFields"])
      end
    end

    it "rejects a fragment file that contains an operation" do
      Dir.mktmpdir do |dir|
        write(dir, "bad.graphql", "query Oops { people { name } }")
        expect { GraphWeaver::Codegen.load_fragments([dir]) }
          .to raise_error(GraphWeaver::Error, /only fragments/)
      end
    end

    it "rejects duplicate fragment names across files" do
      Dir.mktmpdir do |dir|
        write(dir, "a.graphql", "fragment F on Person { name }")
        write(dir, "b.graphql", "fragment F on Person { email }")
        expect { GraphWeaver::Codegen.load_fragments([dir]) }
          .to raise_error(GraphWeaver::Error, /duplicate shared fragment 'F'/)
      end
    end
  end

  describe "GraphWeaver::Codegen.inline_fragments" do
    let(:shared) do
      Dir.mktmpdir do |dir|
        write(dir, "f.graphql",
          "fragment PersonFields on Person { name ...ContactBits }\n" \
          "fragment ContactBits on Person { email }")
        GraphWeaver::Codegen.load_fragments([dir])
      end
    end

    it "inlines the fragments a query spreads, transitively" do
      out = GraphWeaver::Codegen.inline_fragments("query P { people { ...PersonFields } }", shared)
      expect(out).to include("fragment PersonFields on Person", "fragment ContactBits on Person")
    end

    it "leaves a query that spreads nothing unchanged" do
      q = "query P { people { name } }"
      expect(GraphWeaver::Codegen.inline_fragments(q, shared)).to eq(q)
    end

    it "lets a query-local fragment shadow a shared one of the same name" do
      q = "query P { people { ...PersonFields } }\nfragment PersonFields on Person { name }"
      expect(GraphWeaver::Codegen.inline_fragments(q, shared)).not_to include("email")
    end
  end

  it "generates a self-contained module from a query that spreads a shared fragment" do
    Dir.mktmpdir do |base|
      write("#{base}/fragments", "person.graphql", "fragment PersonFields on Person { name email }")
      write("#{base}/queries", "people.graphql", "query People { people { ...PersonFields } }")
      FileUtils.mkdir_p("#{base}/generated")
      GraphWeaver.fragments_paths = ["#{base}/fragments"]
      GraphWeaver.generate!(schema:, queries: "#{base}/queries", output: "#{base}/generated")

      src = File.read("#{base}/generated/people_query.rb")
      expect(src).to include("fragment PersonFields on Person") # the sent QUERY is self-contained
      expect(src).to include("const :name, String", "const :email, String")
    ensure
      GraphWeaver.fragments_paths = nil
    end
  end

  it "surfaces an undefined fragment as a ValidationError" do
    expect { GraphWeaver::Codegen.generate(schema:, query: "query P { people { ...Nope } }", module_name: "P") }
      .to raise_error(GraphWeaver::ValidationError, /Nope/)
  end

  describe "dispatch + cycles (review fixes)" do
    let(:iface_schema) do
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { node: Node }
        interface Node { id: ID! }
        type User implements Node { id: ID! name: String! }
        type Post implements Node { id: ID! title: String! }
      GRAPHQL
    end

    it "dispatches a named interface fragment holding inline ... on X conditions" do
      query = "query Q { node { ...NodeFields } }\n" \
        "fragment NodeFields on Node { __typename id ... on User { name } ... on Post { title } }"
      src = GraphWeaver::Codegen.generate(schema: iface_schema, query:, module_name: "Q")

      expect(src).to include("Type = T.type_alias")  # a dispatch, not one interface-level struct
      expect(src).to include("const :name, String")  # User's field survives
      expect(src).to include("const :title, String") # Post's field survives
    end

    # codegen catches cycles via graphql-ruby's schema validation; the Selection
    # guard is the backstop for the walkers that skip it (FakeClient, Anonymizer)
    it "raises a clear error on a fragment cycle instead of overflowing the stack" do
      host = Object.new.extend(GraphWeaver::Selection)
      host.instance_variable_set(:@schema, iface_schema)
      op = host.load_operation(
        "query Q { node { id ...A } }\nfragment A on Node { id ...B }\nfragment B on Node { id ...A }",
      )
      node_selections = op.selections.first.selections

      expect { host.each_field(iface_schema.get_type("Node"), node_selections) { |_k, _n| } }
        .to raise_error(GraphWeaver::Error, /cycle/)
    end
  end
end
