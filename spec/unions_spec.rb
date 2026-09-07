# typed: ignore — HomeQuery/ArchiveQuery/SharedTypes are eval'd at runtime, invisible to srb
# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe "shared unions (fragment-driven hoisting)" do
  # These examples load generated modules, so they must put the constants back.
  # The shared module gets its own name here rather than the default: reopening
  # the *fixture's* GraphQLTypes would leave this spec's types inside it, since
  # restoring the constant restores the same module object.
  GENERATED_CONSTANTS = %i[HomeQuery ArchiveQuery SharedTypes].freeze

  around do |example|
    GraphWeaver.types_module = "SharedTypes"
    prior = GENERATED_CONSTANTS.to_h { |c| [c, (Object.const_get(c) if Object.const_defined?(c))] }
    example.run
  ensure
    GraphWeaver.types_module = nil
    GENERATED_CONSTANTS.each do |c|
      Object.send(:remove_const, c) if Object.const_defined?(c)
      Object.const_set(c, prior[c]) if prior[c]
    end
  end

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

  it "hoists the union once into the shared module and aliases it per query" do
    generate(@base)

    union = File.read("#{@base}/generated/types/feed_item_fields.rb")
    expect(union).to include("module SharedTypes", "module FeedItemFields")
    # both members dispatched under one type family
    expect(union).to include("class Post < T::Struct", "class Photo < T::Struct")
    expect(union).to include("Type = T.type_alias")
    expect(File.read("#{@base}/generated/types.rb"))
      .to include('require_relative "types/feed_item_fields"')

    %w[home archive].each do |name|
      src = File.read("#{@base}/generated/#{name}_query.rb")
      expect(src).to include('require_relative "types"')
      expect(src).to include("FeedItemFields = SharedTypes::FeedItemFields")
      # the result references the shared type, not a locally-emitted union
      expect(src).to include("FeedItemFields::Type")
      expect(src).not_to include("module FeedItemFields") # lives in the shared module
    end
  end

  it "resolves both queries to one shared Ruby type" do
    generate(@base)
    GraphWeaver.load_generated!("#{@base}/generated")

    response = { "data" => { "feed" => [{ "__typename" => "Post", "title" => "hi" }] } }
    home = HomeQuery.from_response!(response).feed.first
    archive = ArchiveQuery.from_response!(response).feed.first

    expect(home.class).to eq(archive.class)
    expect(home.class).to eq(SharedTypes::FeedItemFields::Post)
    expect(home.title).to eq("hi")
  end

  it "hoists the catch-all too, so a member added upstream bends the shared type" do
    generate(@base)
    expect(File.read("#{@base}/generated/types/feed_item_fields.rb")).to include("class Other < T::Struct")

    GraphWeaver.load_generated!("#{@base}/generated")
    item = HomeQuery.from_response!("data" => { "feed" => [{ "__typename" => "Video" }] }).feed.first

    expect(item).to be_a(SharedTypes::FeedItemFields::Other)
    expect(item.__typename).to eq "Video"
  end

  it "does not hoist a union whose fragment a query defines locally" do
    write("#{@base}/fragments", "feed.graphql", fragment)
    # local fragment of the same name shadows the shared one
    write("#{@base}/queries", "home.graphql",
      "query Home { feed { ...FeedItemFields } }\n#{fragment}")
    FileUtils.mkdir_p("#{@base}/generated")
    GraphWeaver.fragments_paths = ["#{@base}/fragments"]
    GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated")

    expect(File.exist?("#{@base}/generated/types/feed_item_fields.rb")).to be(false)
    src = File.read("#{@base}/generated/home_query.rb")
    # emitted locally as a union named for its field, not hoisted
    expect(src).to include("module Feed", "Type = T.type_alias")
    expect(src).not_to include("SharedTypes")
  end

  it "prunes a stray union file once no query hoists" do
    generate(@base)
    expect(File.exist?("#{@base}/generated/types/feed_item_fields.rb")).to be(true)

    # drop the shared fragment usage: queries select inline instead
    inline = "query Home { feed { __typename ... on Post { title } ... on Photo { url } } }"
    File.write("#{@base}/queries/home.graphql", inline)
    File.write("#{@base}/queries/archive.graphql", inline.sub("Home", "Archive"))
    GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated")

    expect(File.exist?("#{@base}/generated/types/feed_item_fields.rb")).to be(false)
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
    expect(File.read("#{@base}/generated/types/feed_item_fields.rb")).to include("const :title, String")
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

    it "emits both kinds of shared type and loads cleanly" do
      write("#{@base}/fragments", "feed.graphql", fragment)
      write("#{@base}/queries", "home.graphql",
        "query Home($filter: FeedFilter) { feed(filter: $filter) { ...FeedItemFields } }")
      FileUtils.mkdir_p("#{@base}/generated")
      GraphWeaver.fragments_paths = ["#{@base}/fragments"]
      GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated")

      expect(File.exist?("#{@base}/generated/types/feed_filter.rb")).to be(true)
      expect(File.exist?("#{@base}/generated/types/feed_item_fields.rb")).to be(true)
      src = File.read("#{@base}/generated/home_query.rb")
      expect(src).to include('require_relative "types"')

      GraphWeaver.load_generated!("#{@base}/generated")
      response = { "data" => { "feed" => [{ "__typename" => "Photo", "url" => "x" }] } }
      expect(HomeQuery.from_response!(response).feed.first.url).to eq("x")
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

    it "emits mapped-enum tables a hoisted fragment reaches, and resolves them at from_h" do
      GraphWeaver.register_enum("Rank", HoistRank)
      generate(@base)

      # a hoisted fragment's own selections are the one place a query walk
      # doesn't reach, so unions are built before the enums are collected
      expect(File.read("#{@base}/generated/types/rank.rb")).to include("RANK_FROM_WIRE = T.let({")
      # ...and the enum file loads before the union that spells it bare
      expect(File.read("#{@base}/generated/types.rb"))
        .to include(%(require_relative "types/rank"\nrequire_relative "types/feed_item_fields"))
      GraphWeaver.load_generated!("#{@base}/generated")
      got = HomeQuery.from_response!("data" => { "feed" => [{ "__typename" => "Post", "rank" => "HIGH" }] })
      expect(got.feed.first.rank).to eq(HoistRank::High)
    ensure
      GraphWeaver::Codegen.reset_enums!
    end

    it "hoists an unmapped enum a shared fragment reaches into the shared module" do
      generate(@base)

      expect(File.read("#{@base}/generated/types/rank.rb")).to include("class Rank < T::Enum")
      # same module, so the union member spells Rank bare — no alias to keep
      union = File.read("#{@base}/generated/types/feed_item_fields.rb")
      expect(union).to include("Rank.deserialize")
      expect(union).not_to include("Rank = ")
      GraphWeaver.load_generated!("#{@base}/generated")
      got = HomeQuery.from_response!("data" => { "feed" => [{ "__typename" => "Post", "rank" => "HIGH" }] })
      expect(got.feed.first.rank).to equal SharedTypes::Rank::High
    end

    it "refuses to hoist a shared fragment whose name collides with a generated constant" do
      write("#{@base}/fragments", "f.graphql", fragment.sub("FeedItemFields", "Result"))
      write("#{@base}/queries", "home.graphql", "query Home { feed { ...Result } }")
      FileUtils.mkdir_p("#{@base}/generated")
      GraphWeaver.fragments_paths = ["#{@base}/fragments"]

      expect { GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated") }
        .to raise_error(GraphWeaver::Error, /collides with a generated constant/)
    end

    # a fragment is named by you, a type by the schema — one module means one
    # namespace, so the two can meet
    it "refuses a fragment whose name is already a schema type in the shared module" do
      write("#{@base}/fragments", "f.graphql", fragment.sub("FeedItemFields", "Rank"))
      write("#{@base}/queries", "home.graphql", "query Home { feed { ...Rank } }")
      FileUtils.mkdir_p("#{@base}/generated")
      GraphWeaver.fragments_paths = ["#{@base}/fragments"]

      expect { GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated") }
        .to raise_error(GraphWeaver::Error, /fragment "Rank" .* SharedTypes::Rank.*schema enum Rank/)
    end
  end
end
