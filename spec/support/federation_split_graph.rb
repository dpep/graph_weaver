# typed: ignore — graphql-ruby class DSL
# frozen_string_literal: true

# A two-subgraph graph carrying the shapes RouterGraph doesn't have: a union
# whose members live in different subgraphs, a mutation whose root fields do,
# and a subscription root. Hand-written rather than composed, so the pieces
# can be arranged the way a refusal needs them rather than the way a real
# graph would.
module SplitGraph
  SUPERGRAPH = <<~SDL
    schema @link(url: "https://specs.apollo.dev/link/v1.0")
      @link(url: "https://specs.apollo.dev/join/v0.3", for: EXECUTION)
    { query: Query, mutation: Mutation, subscription: Subscription }
    directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
    directive @join__graph(name: String!, url: String!) on ENUM_VALUE
    directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT | UNION
    directive @join__unionMember(graph: join__Graph!, member: String!) repeatable on UNION
    scalar join__FieldSet
    enum join__Graph {
      A @join__graph(name: "a", url: "http://a")
      B @join__graph(name: "b", url: "http://b")
    }
    type Query @join__type(graph: A) @join__type(graph: B) {
      search: [Result!]! @join__field(graph: A)
    }
    type Mutation @join__type(graph: A) @join__type(graph: B) {
      publish: Doc @join__field(graph: A)
      annotate: Note @join__field(graph: B)
    }
    type Subscription @join__type(graph: A) { ticks: Int @join__field(graph: A) }
    union Result @join__type(graph: A) @join__type(graph: B)
      @join__unionMember(graph: A, member: "Doc")
      @join__unionMember(graph: B, member: "Note")
      = Doc | Note
    type Doc @join__type(graph: A) { id: ID! }
    type Note @join__type(graph: B) { id: ID! }
  SDL

  class Doc < GraphQL::Schema::Object
    graphql_name "Doc"
    field :id, ID, null: false
  end

  class Note < GraphQL::Schema::Object
    graphql_name "Note"
    field :id, ID, null: false
  end

  # each subgraph declares Result with only its own member — the split the
  # supergraph records with @join__unionMember
  class DocResult < GraphQL::Schema::Union
    graphql_name "Result"
    possible_types Doc
  end

  class NoteResult < GraphQL::Schema::Union
    graphql_name "Result"
    possible_types Note
  end

  module A
    class Query < GraphQL::Schema::Object
      graphql_name "Query"
      field :search, [DocResult], null: false
      def search = [{ id: "d1" }]
    end

    class Mutation < GraphQL::Schema::Object
      graphql_name "Mutation"
      field :publish, Doc, null: true
      def publish = { id: "d1" }
    end

    class Subscription < GraphQL::Schema::Object
      graphql_name "Subscription"
      field :ticks, Integer, null: true
    end

    class Schema < GraphQL::Schema
      query Query
      mutation Mutation
      subscription Subscription
      def self.resolve_type(_type, object, _context) = object.key?(:headline) ? Note : Doc
    end
  end

  module B
    # b declares Query and Result but resolves no field the supergraph
    # lists — its own search is @inaccessible, so it composes away
    class Query < GraphQL::Schema::Object
      graphql_name "Query"
      field :notes, [NoteResult], null: false
      def notes = [{ id: "n1" }]
    end

    class Mutation < GraphQL::Schema::Object
      graphql_name "Mutation"
      field :annotate, Note, null: true
      def annotate = { id: "n1" }
    end

    class Schema < GraphQL::Schema
      query Query
      mutation Mutation
      def self.resolve_type(_type, _object, _context) = Note
    end
  end

  # A second schema defining exactly what the supergraph says "b" resolves.
  # Detection then has two candidates for b and has to refuse rather than
  # pick one — the shape a real app hits when a subgraph is subclassed.
  module Twin
    class Schema < GraphQL::Schema
      query B::Query
      mutation B::Mutation
      def self.resolve_type(_type, _object, _context) = Note
    end
  end

  SUBGRAPHS = { "a" => A::Schema, "b" => B::Schema }.freeze
end
