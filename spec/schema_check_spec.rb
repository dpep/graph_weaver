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
      # queries in their own directory: the scan is recursive, so a dump
      # written alongside them would be read as a query
      @queries = File.join(dir, "queries")
      FileUtils.mkdir_p(@queries)
      write("title.graphql", "query($id: ID!) {\n  media(id: $id) {\n    title\n  }\n}\n")
      write("search.graphql", "query($term: String!) { search(term: $term) { id } }\n")
      write("still_good.graphql", "query($id: ID!) { media(id: $id) { id } }\n")
      example.run
    end
  end

  def write(name, source) = File.write(File.join(@queries, name), source)

  def check(schema) = GraphWeaver.check_queries(schema:, queries: @queries, fragments: [])

  it "reports nothing while the queries still validate" do
    expect(check(v1)).to be_empty
  end

  it "names only the queries a schema change broke, with source positions" do
    failures = check(v2)

    expect(failures.keys.map { |path| File.basename(path) }).to eq %w[search.graphql title.graphql]
    expect(failures[File.join(@queries, "title.graphql")])
      .to eq [{ "message" => "Field 'title' doesn't exist on type 'Media'", "line" => 3, "column" => 5 }]
    expect(failures[File.join(@queries, "search.graphql")].first["message"])
      .to match(/\$term.*String!.*Int!/)
  end

  it "reports an unparseable query rather than raising" do
    write("broken.graphql", "query { media {{ id } }")

    expect(check(v1).keys.map { |path| File.basename(path) }).to eq %w[broken.graphql]
  end

  # codegen folds the position into the message for its own rendering; this
  # report keeps message and position apart, so the rake task printed
  # "1:16  1:16 Expected ..." until the two agreed
  it "keeps the position out of an unparseable query's message" do
    write("broken.graphql", "query { media {{ id } }")

    expect(check(v1)[File.join(@queries, "broken.graphql")])
      .to eq [{ "message" => "Expected NAME, actual: LCURLY (\"{\") at [1, 16]", "line" => 1, "column" => 16 }]
  end

  it "checks against a passed schema without touching the network" do
    expect(GraphWeaver::SchemaLoader).not_to receive(:introspect)
    check(v1)
  end

  # an app whose schema IS its own graphql-ruby class has no server to
  # re-introspect: re-reading the dump compares the schema against a snapshot
  # of itself, and reports phantom errors about a field just added
  it "checks against the live class when the app default runs in-process" do
    live = GraphQL::Schema.from_definition(
      "type Media { id: ID! title: String }\ntype Query { media(id: ID!): Media search(term: String!): [Media!]! }",
    )
    path = File.join(@dir, "dump", "schema.graphql")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "type Media { id: ID! }\ntype Query { media(id: ID!): Media }\n") # stale
    GraphWeaver.schema_path = path
    GraphWeaver.client = GraphWeaver.new(live)

    expect(GraphWeaver.check_queries(queries: @queries, fragments: [])).to be_empty
  ensure
    GraphWeaver.schema_path = nil
    GraphWeaver.client = nil
  end

  # "Product.colour" says what broke; "(products, reviews)" says whose
  # code to look at and whose team to talk to — and the supergraph's routing
  # table already has the mapping
  it "names the subgraphs behind an error when the dump is a supergraph" do
    GraphWeaver.schema_path = RouterGraph::SUPERGRAPH
    write("federated.graphql", "{ product(upc: \"1\") { colour } }\n")

    expect(GraphWeaver.check_queries(queries: @queries, fragments: [])[File.join(@queries, "federated.graphql")])
      .to eq [{
        "message" => "Field 'colour' doesn't exist on type 'Product' (products, reviews)",
        "line" => 1, "column" => 23, "subgraphs" => %w[products reviews],
      }]
  ensure
    GraphWeaver.schema_path = nil
  end

  # an argument error names the AST node kind ("Field") where a type would
  # go, so there is nothing to attribute and nothing is claimed
  it "says nothing when the error names no type of the graph" do
    GraphWeaver.schema_path = RouterGraph::SUPERGRAPH
    write("federated.graphql", "{ topProducts(nope: 1) { upc } }\n")

    expect(GraphWeaver.check_queries(queries: @queries, fragments: [])[File.join(@queries, "federated.graphql")])
      .to eq [{
        "message" => "Field 'topProducts' doesn't accept argument 'nope'", "line" => 1, "column" => 15,
      }]
  ensure
    GraphWeaver.schema_path = nil
  end

  it "leaves the same error untouched on a plain schema" do
    plain = GraphWeaver::SchemaLoader.load(
      "type Product { upc: String! }\ntype Query { product(upc: String!): Product }",
    )
    write("federated.graphql", "{ product(upc: \"1\") { dimensions } }\n")

    expect(check(plain)[File.join(@queries, "federated.graphql")])
      .to eq [{ "message" => "Field 'dimensions' doesn't exist on type 'Product'", "line" => 1, "column" => 23 }]
  end

  # `--auth MY_TOKEN` wrote ENV["MY_TOKEN"] into the initializer while this
  # path read GRAPHWEAVER_AUTH — the app authenticated and the check 401'd.
  # SchemaLoader is what knows; every re-introspection goes through it.
  it "authenticates from the ENV var the dump recorded" do
    path = File.join(@dir, "dump", "schema.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(
      "data" => { "__schema" => {} },
      "graph_weaver" => { "url" => "https://api.example.com/graphql", "auth_env" => "MY_TOKEN" },
    ))
    GraphWeaver.schema_path = path
    ENV["MY_TOKEN"] = "s3cret"

    transport = nil
    allow(GraphWeaver::SchemaLoader).to receive(:introspect) { |built| transport = built and v1 }
    GraphWeaver.check_queries(queries: @queries, fragments: [])

    expect(transport.instance_variable_get(:@headers)).to include "Authorization" => "Bearer s3cret"
  ensure
    GraphWeaver.schema_path = nil
    ENV.delete("MY_TOKEN")
  end

  it "falls back to the local dump when it records no source url" do
    path = File.join(@dir, "dump", "schema.graphql")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "type Media { id: ID! }\ntype Query { media(id: ID!): Media }\n")
    GraphWeaver.schema_path = path

    expect(GraphWeaver::SchemaLoader).not_to receive(:introspect)
    expect(GraphWeaver.check_queries(queries: @queries, fragments: []).keys.map { |f| File.basename(f) })
      .to eq %w[search.graphql title.graphql]
  ensure
    GraphWeaver.schema_path = nil
  end
end

describe "rake graph_weaver:queries:check" do
  # Shared with every other spec file that exercises these tasks (see
  # rake_tasks_spec's header comment on RakeHarness.application for why this must be a single
  # process-wide load rather than one per file/context).
  require "rake"
  # rake refuses to run a task twice, and abort's SystemExit must not
  # escape into the suite — so run the task by hand and report both
  # streams plus the exit status the shell would see
  def run_task
    original = Rake.application
    Rake.application = RakeHarness.application
    RakeHarness.application.tasks.each(&:reenable) # rake runs a task once per process otherwise
    out, err = StringIO.new, StringIO.new
    $stdout, $stderr = out, err
    status = 0
    begin
      Rake::Task["graph_weaver:queries:check"].invoke
    rescue SystemExit => e
      status = e.status
    end
    [out.string, err.string, status]
  ensure
    $stdout, $stderr = STDOUT, STDERR
    Rake.application = original
  end

  it "prints file, position, and message, then exits non-zero" do
    allow(GraphWeaver).to receive(:check_queries).and_return(
      "app/graphql/queries/person.graphql" => [
        { "message" => "Field 'titel' doesn't exist on type 'Media'", "line" => 4, "column" => 5 },
      ],
    )
    out, err, status = run_task

    expect(out).to eq "app/graphql/queries/person.graphql\n  4:5  Field 'titel' doesn't exist on type 'Media'\n\n"
    expect(err).to eq "1 invalid query\n"
    expect(status).to eq 1
  end

  it "exits zero when everything validates" do
    allow(GraphWeaver).to receive(:check_queries).and_return({})

    expect(run_task).to eq ["every query validates against the schema\n", "", 0]
  end
end

RSpec.describe "#{GraphWeaver}.check_queries schema sources" do
  # every other schema slot in the library takes a path or SDL string; this one
  # used to pass a String through to schema.validate and die on NoMethodError
  it "accepts a path the way the rest of the library does" do
    Dir.mktmpdir do |dir|
      File.write("#{dir}/schema.graphql", "type Query { person: Person }\ntype Person { name: String! }\n")
      FileUtils.mkdir_p("#{dir}/queries")
      File.write("#{dir}/queries/ok.graphql", "query { person { name } }")

      expect(
        GraphWeaver.check_queries(schema: "#{dir}/schema.graphql", queries: "#{dir}/queries"),
      ).to be_empty
    end
  end
end
