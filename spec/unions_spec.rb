# typed: ignore — HomeQuery/ArchiveQuery/GraphQLUnions are eval'd at runtime, invisible to srb
# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe "shared unions (fragment-driven hoisting)" do
  def write(dir, name, content)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), content)
  end

  let(:schema) do
    GraphQL::Schema.from_definition(<<~GRAPHQL)
      type Query { feed: [FeedItem!]! }
      union FeedItem = Post | Photo
      type Post { title: String! }
      type Photo { url: String! }
    GRAPHQL
  end

  let(:fragment) do
    <<~GRAPHQL
      fragment FeedItemFields on FeedItem {
        __typename
        ... on Post { title }
        ... on Photo { url }
      }
    GRAPHQL
  end

  # generate a two-query directory that both spread the shared union fragment
  def generate(base)
    write("#{base}/fragments", "feed.graphql", fragment)
    write("#{base}/queries", "home.graphql", "query Home { feed { ...FeedItemFields } }")
    write("#{base}/queries", "archive.graphql", "query Archive { feed { ...FeedItemFields } }")
    FileUtils.mkdir_p("#{base}/generated")
    GraphWeaver.fragments_paths = ["#{base}/fragments"]
    GraphWeaver.generate!(schema:, queries: "#{base}/queries", output: "#{base}/generated")
  end

  around do |example|
    Dir.mktmpdir { |base| @base = base; example.run }
  ensure
    GraphWeaver.fragments_paths = nil
  end

  it "hoists the union once into GraphQLUnions and aliases it per query" do
    generate(@base)

    unions = File.read("#{@base}/generated/unions.rb")
    expect(unions).to include("module GraphQLUnions", "module FeedItemFields")
    # both members dispatched under one type family
    expect(unions).to include("class Post < T::Struct", "class Photo < T::Struct")
    expect(unions).to include("Type = T.type_alias")

    %w[home archive].each do |name|
      src = File.read("#{@base}/generated/#{name}_query.rb")
      expect(src).to include('require_relative "unions"')
      expect(src).to include("FeedItemFields = GraphQLUnions::FeedItemFields")
      # the result references the shared type, not a locally-emitted union
      expect(src).to include("FeedItemFields::Type")
      expect(src).not_to include("module FeedItemFields") # lives in unions.rb
    end
  end

  it "resolves both queries to one shared Ruby type" do
    generate(@base)
    GraphWeaver.load_generated!("#{@base}/generated")

    response = { "data" => { "feed" => [{ "__typename" => "Post", "title" => "hi" }] } }
    home = HomeQuery.from_response!(response).feed.first
    archive = ArchiveQuery.from_response!(response).feed.first

    expect(home.class).to eq(archive.class)
    expect(home.class).to eq(GraphQLUnions::FeedItemFields::Post)
    expect(home.title).to eq("hi")
  ensure
    %i[HomeQuery ArchiveQuery GraphQLUnions].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
  end

  it "does not hoist a union whose fragment a query defines locally" do
    write("#{@base}/fragments", "feed.graphql", fragment)
    # local fragment of the same name shadows the shared one
    write("#{@base}/queries", "home.graphql",
      "query Home { feed { ...FeedItemFields } }\n#{fragment}")
    FileUtils.mkdir_p("#{@base}/generated")
    GraphWeaver.fragments_paths = ["#{@base}/fragments"]
    GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated")

    expect(File.exist?("#{@base}/generated/unions.rb")).to be(false)
    src = File.read("#{@base}/generated/home_query.rb")
    # emitted locally as a union named for its type, not hoisted
    expect(src).to include("module FeedItem", "Type = T.type_alias")
    expect(src).not_to include("GraphQLUnions")
  end

  it "prunes a stray unions.rb once no query hoists" do
    generate(@base)
    expect(File.exist?("#{@base}/generated/unions.rb")).to be(true)

    # drop the shared fragment usage: queries select inline instead
    inline = "query Home { feed { __typename ... on Post { title } ... on Photo { url } } }"
    File.write("#{@base}/queries/home.graphql", inline)
    File.write("#{@base}/queries/archive.graphql", inline.sub("Home", "Archive"))
    GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated")

    expect(File.exist?("#{@base}/generated/unions.rb")).to be(false)
  end

  it "regenerates clean (verify_generated! passes on fresh output)" do
    generate(@base)
    expect(
      GraphWeaver.verify_generated!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated"),
    ).to be(true)
  end

  it "resolves a shared fragment nested inside the union fragment" do
    write("#{@base}/fragments", "feed.graphql", <<~GRAPHQL)
      fragment FeedItemFields on FeedItem {
        __typename
        ... on Post { ...PostBits }
        ... on Photo { url }
      }
      fragment PostBits on Post { title }
    GRAPHQL
    write("#{@base}/queries", "home.graphql", "query Home { feed { ...FeedItemFields } }")
    FileUtils.mkdir_p("#{@base}/generated")
    GraphWeaver.fragments_paths = ["#{@base}/fragments"]
    GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated")

    # the nested spread is inlined into the hoisted member struct
    expect(File.read("#{@base}/generated/unions.rb")).to include("const :title, String")
  end

  context "alongside a shared input in the same query" do
    let(:schema) do
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { feed(filter: FeedFilter): [FeedItem!]! }
        input FeedFilter { kind: String }
        union FeedItem = Post | Photo
        type Post { title: String! }
        type Photo { url: String! }
      GRAPHQL
    end

    it "emits both shared artifacts and loads cleanly" do
      write("#{@base}/fragments", "feed.graphql", fragment)
      write("#{@base}/queries", "home.graphql",
        "query Home($filter: FeedFilter) { feed(filter: $filter) { ...FeedItemFields } }")
      FileUtils.mkdir_p("#{@base}/generated")
      GraphWeaver.fragments_paths = ["#{@base}/fragments"]
      GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated")

      expect(File.exist?("#{@base}/generated/inputs.rb")).to be(true)
      expect(File.exist?("#{@base}/generated/unions.rb")).to be(true)
      src = File.read("#{@base}/generated/home_query.rb")
      expect(src).to include('require_relative "inputs"', 'require_relative "unions"')

      GraphWeaver.load_generated!("#{@base}/generated")
      response = { "data" => { "feed" => [{ "__typename" => "Photo", "url" => "x" }] } }
      expect(HomeQuery.from_response!(response).feed.first.url).to eq("x")
    ensure
      %i[HomeQuery GraphQLInputs GraphQLUnions].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    end
  end

  describe "review fixes" do
    class HoistRank < T::Enum
      enums { High = new("HIGH"); Low = new("LOW") }
    end

    let(:schema) do
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { feed: [FeedItem!]! }
        union FeedItem = Post | Photo
        type Post { rank: Rank! }
        type Photo { url: String! }
        enum Rank { HIGH LOW }
      GRAPHQL
    end

    let(:fragment) do
      <<~GRAPHQL
        fragment FeedItemFields on FeedItem {
          __typename
          ... on Post { rank }
          ... on Photo { url }
        }
      GRAPHQL
    end

    it "emits mapped-enum tables into unions.rb and resolves them at from_h" do
      registry = GraphWeaver::Codegen.enum_registry
      saved = registry.dup
      GraphWeaver.register_enum("Rank", HoistRank)
      generate(@base)

      expect(File.read("#{@base}/generated/unions.rb")).to include("RANK_FROM_WIRE")
      GraphWeaver.load_generated!("#{@base}/generated")
      got = HomeQuery.from_response!("data" => { "feed" => [{ "__typename" => "Post", "rank" => "HIGH" }] })
      expect(got.feed.first.rank).to eq(HoistRank::High)
    ensure
      registry.clear
      registry.merge!(saved)
      %i[HomeQuery ArchiveQuery GraphQLUnions].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    end

    it "refuses to hoist a shared fragment whose name collides with a generated constant" do
      write("#{@base}/fragments", "f.graphql", fragment.sub("FeedItemFields", "Result"))
      write("#{@base}/queries", "home.graphql", "query Home { feed { ...Result } }")
      FileUtils.mkdir_p("#{@base}/generated")
      GraphWeaver.fragments_paths = ["#{@base}/fragments"]

      expect { GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated") }
        .to raise_error(GraphWeaver::Error, /collides with a generated constant/)
    end
  end
end
