# typed: ignore

# The summary CI prints when the server's schema moved. The message *is*
# the feature here, so these assert the lines, not just the verdict.
describe GraphWeaver::SchemaDiff do
  # one line per change, without the alignment padding
  def diff(before, after, **)
    described_class.new(
      GraphQL::Schema.from_definition(before), GraphQL::Schema.from_definition(after), **
    )
  end

  def lines(before, after)
    diff(before, after).changes.map(&:to_s)
  end

  # a local, not a constant: two spec files reaching for the same obvious
  # name at top level silently redefine each other's
  base = "type Query { me: User } type User { id: ID! name: String }"

  it "reports nothing when the schemas agree" do
    result = diff(base, base)

    expect(result).to be_empty
    expect(result.report).to eq "no changes"
    expect(result.to_h).to eq("changes" => [])
  end

  describe "what it names" do
    {
      "a removed type" => ["type Query { me: User } type User { id: ID! } scalar Money", base,
        "Money  removed",],
      "an added type" => [base, "#{base} scalar Money", "Money  added scalar"],
      "a type that changed kind" => [
        "type Query { me: Thing } type Thing { id: ID! }",
        "type Query { me: Thing } interface Thing { id: ID! }",
        "Thing  object -> interface",
      ],
      "a removed field" => [base, "type Query { me: User } type User { id: ID! }",
        "User.name  removed",],
      "an added field" => [base, "type Query { me: User } type User { id: ID! name: String email: String }",
        "User.email  added: String",],
      "a field whose type changed" => [base, "type Query { me: User } type User { id: ID! name: Int }",
        "User.name  String -> Int",],
      "an output that lost its guarantee" => [base, "type Query { me: User } type User { id: ID name: String }",
        "User.id  ID! -> ID",],
      "a removed argument" => [
        "type Query { me(id: ID): User } type User { id: ID! }",
        "type Query { me: User } type User { id: ID! }",
        "Query.me(id:)  argument removed",
      ],
      "an added optional argument" => [
        "type Query { me: User } type User { id: ID! }",
        "type Query { me(id: ID): User } type User { id: ID! }",
        "Query.me(id:)  argument added: ID",
      ],
      "an added required argument" => [
        "type Query { me: User } type User { id: ID! }",
        "type Query { me(id: ID!): User } type User { id: ID! }",
        "Query.me(id:)  argument added: ID! — required",
      ],
      "an argument made required" => [
        "type Query { me(id: ID): User } type User { id: ID! }",
        "type Query { me(id: ID!): User } type User { id: ID! }",
        "Query.me(id:)  argument ID -> ID!",
      ],
      "a removed enum value" => [
        "type Query { r: Role } enum Role { ADMIN GUEST }",
        "type Query { r: Role } enum Role { ADMIN }",
        "Role.GUEST  enum value removed",
      ],
      "an added enum value" => [
        "type Query { r: Role } enum Role { ADMIN }",
        "type Query { r: Role } enum Role { ADMIN GUEST }",
        "Role.GUEST  enum value added",
      ],
      "a newly deprecated field" => [
        base, %(type Query { me: User } type User { id: ID! name: String @deprecated(reason: "use id") }),
        "User.name  deprecated: use id",
      ],
      "a removed input field" => [
        "type Query { s(f: Filter): String } input Filter { q: String limit: Int }",
        "type Query { s(f: Filter): String } input Filter { q: String }",
        "Filter.limit  removed",
      ],
      "an input field made required" => [
        "type Query { s(f: Filter): String } input Filter { q: String }",
        "type Query { s(f: Filter): String } input Filter { q: String! }",
        "Filter.q  String -> String!",
      ],
      "a dropped union member" => [
        "type Query { t: Thing } union Thing = User | Post type User { id: ID! } type Post { id: ID! }",
        "type Query { t: Thing } union Thing = User type User { id: ID! } type Post { id: ID! }",
        "Thing.Post  union member removed",
      ],
      "an interface a type dropped" => [
        "type Query { me: User } interface Node { id: ID! } type User implements Node { id: ID! }",
        "type Query { me: User } interface Node { id: ID! } type User { id: ID! }",
        "User  no longer implements Node",
      ],
    }.each do |what, (before, after, expected)|
      it "names #{what}" do
        expect(lines(before, after)).to include expected
      end
    end
  end

  describe "which side of a nullability change breaks" do
    it "treats an output losing non-null as breaking and gaining it as free" do
      loosened = diff(base, "type Query { me: User } type User { id: ID name: String }")
      tightened = diff(base, "type Query { me: User } type User { id: ID! name: String! }")

      expect(loosened.breaking.map(&:coordinate)).to eq ["User.id"]
      expect(tightened.breaking).to be_empty
      expect(tightened.compatible.map(&:to_s)).to eq ["User.name  String -> String!"]
    end

    it "treats an input gaining non-null as breaking and losing it as free" do
      optional = "type Query { me(id: ID): User } type User { id: ID! }"
      tightened = diff(optional, "type Query { me(id: ID!): User } type User { id: ID! }")
      loosened = diff("type Query { me(id: ID!): User } type User { id: ID! }", optional)

      expect(tightened.breaking.map(&:coordinate)).to eq ["Query.me(id:)"]
      expect(loosened.breaking).to be_empty
    end

    # the tightening reaches no query, so calling it breaking would cry wolf
    it "doesn't call an argument breaking when a default satisfies it" do
      result = diff(
        "type Query { me(first: Int): User } type User { id: ID! }",
        "type Query { me(first: Int! = 10): User } type User { id: ID! }",
      )

      expect(result.breaking).to be_empty
      expect(result).not_to be_empty
    end
  end

  it "leads with the breaking changes" do
    result = diff(
      "type Query { me: User } type User { id: ID! name: String }",
      "type Query { me: User } type User { name: String nickname: String }",
    )

    expect(result.report).to eq <<~REPORT.chomp
      2 changes, 1 breaking

      breaking:
        User.id  removed

      other:
        User.nickname  added: String
    REPORT
  end

  it "names the schemas it compared" do
    result = diff(base, "type Query { me: User } type User { id: ID! }",
      source: "schema.json", target: "https://api.example.com/graphql")

    expect(result.report).to start_with "schema.json vs https://api.example.com/graphql: 1 change, 1 breaking"
  end

  it "reports each change as data" do
    result = diff(base, "type Query { me: User } type User { id: ID! }")

    expect(result.to_h).to eq(
      "changes" => [{ "coordinate" => "User.name", "change" => "removed", "breaking" => true }],
    )
  end

  # a field newly typed Float pulls the built-in into the schema; reporting
  # it as a new type would be noise on every such change
  it "doesn't report a built-in scalar as an added type" do
    expect(lines(base, "type Query { me: User } type User { id: ID! name: String score: Float }"))
      .to eq ["User.score  added: Float"]
  end

  # the walk names what a client breaks on; a gate that went green on the
  # rest would be worse than one admitting it can't name the change
  it "still reports drift it can't name" do
    result = diff(base, %(type Query { me: User } type User { id: ID! name: String @foo } directive @foo on FIELD_DEFINITION))

    expect(result).not_to be_empty
    expect(result.report).to include "changed in ways this summary doesn't name"
  end
end
