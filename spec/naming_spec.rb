# frozen_string_literal: true

# Generated code is checked in and referenced by app code, so a struct's name
# must be a function of its own position in the query and nothing else: adding,
# removing, or reordering an UNRELATED selection may not rename it. Every
# example below fails under the old scheme (GraphQL type names, one level of
# field-name disambiguation, first-come-first-served).
describe "generated class naming" do
  let(:schema) do
    GraphQL::Schema.from_definition(<<~GRAPHQL)
      type Query { person: Person author: Person feed: [Item!]! }
      type Person { name: String! pets: [Pet!]! friend: Person }
      type Pet { name: String! }
      union Item = Book | Disc
      type Book { title: String! }
      type Disc { runtime: Int! }
    GRAPHQL
  end

  # path (as an app would write it) => the struct's props, so a name that
  # survives while pointing at a DIFFERENT struct still counts as a rename.
  # Props are sorted: their order follows the query, and this is about names.
  def structs(query, schema: self.schema)
    walk(GraphWeaver::Codegen.parse(schema:, query:, name: "Q")::Result, "Result")
  end

  def walk(const, path, acc = {})
    acc[path] = if const.respond_to?(:props) then const.props.keys.map(&:to_s).sort
    elsif const.respond_to?(:values) then const.values.map(&:serialize).sort
    else :module # a union namespace
    end
    const.constants(false).each do |name|
      child = const.const_get(name)
      walk(child, "#{path}::#{name}", acc) if child.is_a?(Module)
    end
    acc
  end

  # everything at or under `root`, so the parent that legitimately gained or
  # lost the unrelated field isn't itself part of the comparison
  def subtree(query, root = "Result::Person")
    structs(query).select { |path, _| path.start_with?(root) }
  end

  let(:base) { "query Q { person { name pets { name } } }" }

  it "names a struct for the response key that selects it" do
    expect(structs(base).keys)
      .to match_array ["Result", "Result::Person", "Result::Person::Pets"]
  end

  it "survives an unrelated field added before or after it" do
    expect(subtree("query Q { author { name } person { name pets { name } } }")).to eq subtree(base)
    expect(subtree("query Q { person { name pets { name } } author { name } }")).to eq subtree(base)
    expect(subtree("query Q { person { name pets { name } } feed { __typename } }")).to eq subtree(base)
  end

  it "survives an unrelated selection being removed" do
    both = "query Q { author { name } person { name pets { name } } }"

    expect(subtree(base)).to eq subtree(both)
  end

  it "survives reordered selections" do
    both = "query Q { author { name friend { name } } person { name pets { name } } }"
    swapped = "query Q { person { name pets { name } } author { friend { name } name } }"

    expect(structs(swapped)).to eq structs(both)
  end

  it "gives the same type selected at two depths two names, each its own" do
    expect(structs("query Q { person { name friend { name pets { name } } } }").keys).to match_array [
      "Result",
      "Result::Person",
      "Result::Person::Friend",
      "Result::Person::Friend::Pets",
    ]
  end

  describe "collisions the type-name scheme could not resolve" do
    it "generates a struct whose type reappears six levels down" do
      # examples/github/stargazers: Repository -> ... -> RepositoryConnection
      # -> Repository, two structurally different structs of one GraphQL type
      deep = GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { repository: Repository }
        type Repository { nameWithOwner: String! stargazers: StargazerConnection }
        type StargazerConnection { edges: [StargazerEdge!]! }
        type StargazerEdge { node: User! }
        type User { login: String! repositories: RepositoryConnection }
        type RepositoryConnection { nodes: [Repository!]! }
      GRAPHQL
      query = "query Q { repository { nameWithOwner stargazers { edges { node { login " \
              "repositories { nodes { nameWithOwner } } } } } } }"

      expect(structs(query, schema: deep).keys)
        .to include "Result::Repository::Stargazers::Edges::Node::Repositories::Nodes"
    end

    it "generates two fields of one type where the second used to raise" do
      # `pet: Owner` fell back to PetOwner, which the enclosing struct held
      colliding = GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { home: PetOwner }
        type PetOwner { primary: Owner pet: Owner }
        type Owner { name: String! }
      GRAPHQL

      expect(structs("query Q { home { primary { name } pet { name } } }", schema: colliding).keys)
        .to match_array ["Result", "Result::Home", "Result::Home::Primary", "Result::Home::Pet"]
    end

    it "refuses a key that camelizes to no constant at all" do
      expect { structs("query Q { _: person { name } } ") }
        .to raise_error(GraphWeaver::Error, /makes no class name/)
    end

    it "suffixes a name that would shadow the struct it nests in" do
      # a bare `Pet` inside class Pet resolves to the child, so the parent's own
      # `returns(Pet)` sig would name the wrong struct
      recursive = GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { pet: Pet }
        type Pet { name: String! pet: Pet }
      GRAPHQL
      mod = GraphWeaver::Codegen.parse(schema: recursive, query: "query Q { pet { name pet { name } } }", name: "Q")

      expect(mod::Result::Pet::Pet2.props.keys).to eq [:name]
      expect(mod.from_response!("data" => { "pet" => { "name" => "a", "pet" => { "name" => "b" } } }).pet&.pet&.name)
        .to eq "b"
    end
  end

  describe "abstract types" do
    let(:union) { "query Q { feed { __typename ... on Book { title } ... on Disc { runtime } } }" }

    it "names members for their type condition, inside a container named for the field" do
      expect(structs(union).keys).to match_array [
        "Result",
        "Result::Feed",
        "Result::Feed::Book",
        "Result::Feed::Disc",
        "Result::Feed::Other", # the member the query never named
      ]
    end

    it "keeps a member's name when another member's selection changes" do
      grown = "query Q { feed { __typename ... on Book { title } ... on Disc { runtime __typename } } }"

      expect(structs(grown)["Result::Feed::Book"]).to eq structs(union)["Result::Feed::Book"]
    end
  end

  describe "names that would shadow a constant the file uses" do
    let(:shadowy) do
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        scalar Date
        enum Species { DOG CAT }
        type Info { note: String }
        type Pet { info: Info, kind: Species, born: Date, tag: Info }
        type Query { pet: Pet }
      GRAPHQL
    end

    def generate(query)
      GraphWeaver::Codegen.generate(schema: shadowy, query:, name: "Q")
    end

    it "refuses a class name that shadows the enum a sibling field reads" do
      expect { generate("query Q { pet { species: info { note } kind } }") }
        .to raise_error(GraphWeaver::Error, /"kind" resolves to Species.*"species".*shadows it inside Pet/)
    end

    it "refuses a class name that shadows a registered scalar's Ruby type" do
      GraphWeaver.register_scalar("Date", Date, cast: :iso8601, serialize: :iso8601, requires: "date")

      expect { generate("query Q { pet { date: info { note } born } }") }
        .to raise_error(GraphWeaver::Error, /"born" resolves to Date/)
    ensure
      GraphWeaver::Codegen.reset_scalars!
    end

    it "allows the same name where nothing lexically reaches it" do
      # `tag` nests a Species struct, but the enum is read on a different branch
      expect { generate("query Q { pet { species: info { note } tag { note } } }") }.not_to raise_error
    end
  end

  describe "structurally identical selections" do
    let(:contacts) do
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        union Contact = Email | Phone
        type Email { address: String! }
        type Phone { number: String! }
        type User { primary: Contact secondary: Contact! }
        type Query { user: User }
      GRAPHQL
    end
    let(:sel) { "{ __typename ... on Email { address } ... on Phone { number } }" }

    # both fields share one Ruby type (one exhaustive `case`), so its name can't
    # come from whichever field the walk reached first
    it "collapse to one struct named for the first of the sharing keys" do
      names = structs("query Q { user { primary #{sel} secondary #{sel} } }", schema: contacts).keys
      swapped = structs("query Q { user { secondary #{sel} primary #{sel} } }", schema: contacts).keys

      expect(names).to include("Result::User::Primary::Email")
      expect(names).not_to include("Result::User::Secondary::Email")
      expect(swapped).to match_array names
    end
  end
end
