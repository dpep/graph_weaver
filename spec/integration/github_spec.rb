# Manual integration checks against the GitHub GraphQL API. Auth comes
# from GITHUB_TOKEN or `gh auth token`. Run with:
#
#   make integration
#
# Note: GitHub's schema is large — the one-time introspection takes a few
# seconds and is cached for the run.
describe "GitHub API", :integration do
  def self.token
    @token ||= ENV["GITHUB_TOKEN"] || `gh auth token 2>/dev/null`.strip
  end

  before do
    skip "no GitHub token (gh auth login, or set GITHUB_TOKEN)" if self.class.token.empty?
  end

  let(:executor) do
    GraphWeaver::HttpExecutor.new(
      "https://api.github.com/graphql",
      headers: { "Authorization" => "Bearer #{self.class.token}" },
    )
  end

  let(:schema) { integration_schema(:github, executor) }

  it "queries the viewer" do
    viewer_query = GraphWeaver.parse(
      schema:,
      executor:,
      query: "query { viewer { login name } }",
    )

    login = viewer_query.execute!.viewer.login
    expect(login).to be_a String
    expect(login).not_to be_empty
  end

  it "handles variables, nested selections, and custom scalars" do
    GraphWeaver.register_scalar("DateTime", type: Time, serialize: :iso8601, requires: "time")

    repo_query = GraphWeaver.parse(
      schema:,
      executor:,
      query: <<~GRAPHQL,
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            nameWithOwner
            createdAt
            stargazerCount
            primaryLanguage { name }
          }
        }
      GRAPHQL
    )

    repo = repo_query.execute!(owner: "dpep", name: "graph_weaver").repository

    expect(repo&.name_with_owner).to eq "dpep/graph_weaver"
    expect(repo&.created_at).to be_a Time
    expect(repo&.stargazer_count).to be >= 0
    expect(repo&.primary_language&.name).to eq "Ruby"
  ensure
    GraphWeaver.reset_scalars!
  end

  it "dispatches union search results via __typename" do
    search_query = GraphWeaver.parse(
      schema:,
      executor:,
      query: <<~GRAPHQL,
        query($q: String!) {
          search(query: $q, type: REPOSITORY, first: 3) {
            nodes {
              __typename
              ... on Repository {
                nameWithOwner
              }
            }
          }
        }
      GRAPHQL
    )

    nodes = search_query.execute!(q: "graph_weaver in:name").search.nodes

    expect(nodes).not_to be_nil
    expect(nodes&.compact&.map(&:__typename)).to all(eq "Repository")
  end
end
