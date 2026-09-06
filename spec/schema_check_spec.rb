# typed: ignore — loads the Rake DSL
require "tmpdir"

describe "GraphWeaver.check_queries" do
  # v2 drops Media.title and retypes search's argument — the two ways a
  # server breaks a query that used to compile
  let(:v1) do
    GraphWeaver::SchemaLoader.load(<<~SDL)
      type Media { id: ID! title: String }
      type Query { media(id: ID!): Media search(term: String!): [Media!]! }
    SDL
  end

  let(:v2) do
    GraphWeaver::SchemaLoader.load(<<~SDL)
      type Media { id: ID! }
      type Query { media(id: ID!): Media search(term: Int!): [Media!]! }
    SDL
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      write("title.graphql", "query($id: ID!) {\n  media(id: $id) {\n    title\n  }\n}\n")
      write("search.graphql", "query($term: String!) { search(term: $term) { id } }\n")
      write("still_good.graphql", "query($id: ID!) { media(id: $id) { id } }\n")
      example.run
    end
  end

  def write(name, source) = File.write(File.join(@dir, name), source)

  def check(schema) = GraphWeaver.check_queries(schema:, queries: @dir, fragments: [])

  it "reports nothing while the queries still validate" do
    expect(check(v1)).to be_empty
  end

  it "names only the queries a schema change broke, with source positions" do
    failures = check(v2)

    expect(failures.keys.map { |path| File.basename(path) }).to eq %w[search.graphql title.graphql]
    expect(failures[File.join(@dir, "title.graphql")])
      .to eq [{ "message" => "Field 'title' doesn't exist on type 'Media'", "line" => 3, "column" => 5 }]
    expect(failures[File.join(@dir, "search.graphql")].first["message"])
      .to match(/\$term.*String!.*Int!/)
  end

  it "reports an unparseable query rather than raising" do
    write("broken.graphql", "query { media {{ id } }")

    expect(check(v1).keys.map { |path| File.basename(path) }).to eq %w[broken.graphql]
  end

  it "checks against a passed schema without touching the network" do
    expect(GraphWeaver::SchemaLoader).not_to receive(:introspect)
    check(v1)
  end

  it "falls back to the local dump when it records no source url" do
    path = File.join(@dir, "dump", "schema.graphql")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "type Media { id: ID! }\ntype Query { media(id: ID!): Media }\n")
    GraphWeaver.schema_path = path

    expect(GraphWeaver::SchemaLoader).not_to receive(:introspect)
    expect(GraphWeaver.check_queries(queries: @dir, fragments: []).keys.map { |f| File.basename(f) })
      .to eq %w[search.graphql title.graphql]
  ensure
    GraphWeaver.schema_path = nil
  end
end

describe "rake graph_weaver:schema:check" do
  before(:context) do
    require "rake"
    Rake::Task.tasks.each(&:clear) if Rake::Task.tasks.any?
    load File.expand_path("../lib/graph_weaver/tasks.rb", __dir__)
  end

  # rake refuses to run a task twice, and abort's SystemExit must not
  # escape into the suite — so run the task by hand and report both
  # streams plus the exit status the shell would see
  def run_task
    Rake::Task["graph_weaver:schema:check"].reenable
    out, err = StringIO.new, StringIO.new
    $stdout, $stderr = out, err
    status = 0
    begin
      Rake::Task["graph_weaver:schema:check"].invoke
    rescue SystemExit => e
      status = e.status
    end
    [out.string, err.string, status]
  ensure
    $stdout, $stderr = STDOUT, STDERR
  end

  it "prints file, position, and message, then exits non-zero" do
    allow(GraphWeaver).to receive(:check_queries).and_return(
      "app/graphql/queries/person.graphql" => [
        { "message" => "Field 'titel' doesn't exist on type 'Media'", "line" => 4, "column" => 5 },
      ],
    )
    out, err, status = run_task

    expect(out).to eq "app/graphql/queries/person.graphql\n  4:5  Field 'titel' doesn't exist on type 'Media'\n"
    expect(err).to eq "1 invalid query\n"
    expect(status).to eq 1
  end

  it "exits zero when everything validates" do
    allow(GraphWeaver).to receive(:check_queries).and_return({})

    expect(run_task).to eq ["every query validates against the schema\n", "", 0]
  end
end
