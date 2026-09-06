# typed: ignore — exercises eval-defined constants and the Rake DSL
require "tmpdir"

describe "GraphWeaver.generate!" do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  it "generates every query in a directory into explicit output paths" do
    root = File.expand_path("..", __dir__)
    written = GraphWeaver.generate!(
      schema: Demo::Schema,
      queries: File.join(root, "spec/queries"),
      output: @dir,
      client: Demo::Schema,
    )

    expect(written.map { |path| path.delete_prefix("#{@dir}/") }).to eq %w[
      inputs/species.rb inputs/adoption_input.rb inputs/pet_filter.rb inputs.rb
      add_pet_mutation.rb adopt_mutation.rb find_pets_query.rb named_query.rb person_query.rb search_query.rb
    ]
    # byte-identical to the checked-in fixtures (same generator, same inputs)
    expect(File.read(File.join(@dir, "person_query.rb")))
      .to eq File.read(File.join(root, "spec/generated/person_query.rb"))
  end

  it "brands an unparseable query file and names it" do
    queries = File.join(@dir, "queries")
    FileUtils.mkdir_p(queries)
    File.write(File.join(queries, "broken.graphql"), "query { people {{ name } }")

    # fragment inlining parses before Codegen#generate's rescue, so this used to
    # escape as a bare GraphQL::ParseError pointing into an unnamed document
    expect { GraphWeaver.generate!(schema: Demo::Schema, queries:, output: @dir) }
      .to raise_error(GraphWeaver::ValidationError, %r{queries/broken\.graphql:})
  end

  it "names the query file a validation error came from" do
    queries = File.join(@dir, "queries")
    FileUtils.mkdir_p(queries)
    File.write(File.join(queries, "typo.graphql"), "query { person(id: 1) { nmae } }")

    # the file reaches Codegen only if generate! passes path: — without it a
    # project with thirty query files reports a bare 1:25
    expect { GraphWeaver.generate!(schema: Demo::Schema, queries:, output: @dir) }
      .to raise_error(GraphWeaver::ValidationError, %r{\Ainvalid query in .*/queries/typo\.graphql:\n  1:25  Field 'nmae'})
  end

  it "derives the shared-inputs module from a multi-schema output path" do
    root = File.expand_path("..", __dir__)
    output = File.join(@dir, "github", "generated")
    GraphWeaver.generate!(
      schema: Demo::Schema,
      queries: File.join(root, "spec/queries"),
      output:,
      client: Demo::Schema,
    )

    manifest = File.read(File.join(output, "inputs.rb"))
    expect(manifest).to include "module GithubInputs"
    expect(File.read(File.join(output, "adopt_mutation.rb"))).to include "GithubInputs::AdoptionInput"
  end

  it "loads per-schema layouts via glob path entries" do
    # the default list covers both the generic and per-schema layouts
    expect(GraphWeaver.generated_paths).to eq ["app/graphql/generated", "app/graphql/*/generated"]

    queries = File.join(@dir, "queries")
    FileUtils.mkdir_p(queries)
    File.write(File.join(queries, "glob_people.graphql"), "query { people { name } }")
    GraphWeaver.generate!(
      schema: Demo::Schema, queries:, output: File.join(@dir, "github/generated"), client: Demo::Schema,
    )

    begin
      GraphWeaver.generated_paths = [File.join(@dir, "*/generated")]
      GraphWeaver.load_generated!
      expect(defined?(::GlobPeopleQuery)).to eq "constant"
    ensure
      GraphWeaver.generated_paths = nil
    end
  end

  it "loads appended generated_paths — the spec-support pattern" do
    queries = File.join(@dir, "support/graphql/queries")
    output = File.join(@dir, "support/graphql/generated")
    FileUtils.mkdir_p(queries)
    File.write(File.join(queries, "appended_people.graphql"), "query { people { name } }")
    GraphWeaver.generate!(schema: Demo::Schema, queries:, output:, client: Demo::Schema)

    begin
      GraphWeaver.generated_paths << output
      expect(GraphWeaver.generated_path).to eq "app/graphql/generated" # default untouched

      GraphWeaver.load_generated!
      expect(defined?(::AppendedPeopleQuery)).to eq "constant"
      expect(AppendedPeopleQuery.execute!.people.map(&:name)).to eq ["Daniel"]
    ensure
      GraphWeaver.generated_paths = nil
    end
  end

  it "defaults to the configured conventional paths" do
    queries = File.join(@dir, "queries")
    output = File.join(@dir, "generated")
    FileUtils.mkdir_p(queries)
    File.write(File.join(queries, "loaded_people.graphql"), "query { people { name } }")

    begin
      GraphWeaver.queries_path = queries
      GraphWeaver.generated_path = output

      written = GraphWeaver.generate!(schema: Demo::Schema, client: Demo::Schema)
      expect(written).to eq [File.join(output, "loaded_people_query.rb")]

      # and load_generated! requires them — the factory_bot-style one-liner
      GraphWeaver.load_generated!
      expect(defined?(::LoadedPeopleQuery)).to eq "constant"
      expect(LoadedPeopleQuery.execute!.people.map(&:name)).to eq ["Daniel"]
    ensure
      GraphWeaver.queries_path = nil
      GraphWeaver.generated_path = nil
    end
  end

  describe "pruning" do
    let(:queries) { File.join(@dir, "queries") }
    let(:output) { File.join(@dir, "generated") }

    def generate! = GraphWeaver.generate!(schema: Demo::Schema, queries:, output:, client: Demo::Schema)

    def generated = Dir[File.join(output, "*.rb")].map { |path| File.basename(path) }.sort

    before do
      FileUtils.mkdir_p(queries)
      File.write(File.join(queries, "person.graphql"), "query { person(id: 1) { name } }")
      generate!
    end

    it "prunes the old file when a query is renamed" do
      FileUtils.mv(File.join(queries, "person.graphql"), File.join(queries, "people.graphql"))
      generate!

      expect(generated).to eq %w[people_query.rb]
    end

    it "prunes the file when a query is deleted" do
      File.delete(File.join(queries, "person.graphql"))
      generate!

      expect(generated).to be_empty
    end

    it "leaves hand-written files in the output directory alone" do
      mine = File.join(output, "person_query_helpers.rb")
      File.write(mine, "# mine, not GraphWeaver's\nmodule PersonQueryHelpers; end\n")
      File.delete(File.join(queries, "person.graphql"))

      generate!

      expect(generated).to eq %w[person_query_helpers.rb]
      expect(File.read(mine)).to start_with "# mine"
      expect { GraphWeaver.verify_generated!(schema: Demo::Schema, queries:, output:, client: Demo::Schema) }
        .not_to raise_error
    end
  end
end

describe "module naming by operation" do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    File.write(File.join(@dir, "adopt.graphql"), "mutation { addPet(name: \"Rex\", species: DOG) { id } }")
    File.write(File.join(@dir, "person.graphql"), "query { person(id: 1) { name } }")
  end

  it "names mutations …Mutation and queries …Query at every site" do
    output = File.join(@dir, "generated")
    written = GraphWeaver.generate!(schema: Demo::Schema, queries: @dir, output:, client: Demo::Schema)
    expect(written.map { |path| File.basename(path) }).to eq %w[adopt_mutation.rb person_query.rb]
    expect(File.read(File.join(output, "adopt_mutation.rb"))).to include "module AdoptMutation"

    expect(GraphWeaver.parse(schema: Demo::Schema, query: File.join(@dir, "adopt.graphql")).name)
      .to end_with "AdoptMutation"
    expect(GraphWeaver.parse(schema: Demo::Schema, query: File.join(@dir, "person.graphql")).name)
      .to end_with "PersonQuery"

    namespace = Module.new
    GraphWeaver.new(Demo::Schema).load_queries!(@dir, namespace:)
    expect(namespace.constants.sort).to eq %i[AdoptMutation PersonQuery]
  end
end

describe "GraphWeaver.inputs_module" do
  it "derives the module name from the output path" do
    expect(GraphWeaver.inputs_module("app/graphql/github/generated")).to eq "GithubInputs"
    expect(GraphWeaver.inputs_module("app/graphql/pet_shop/generated")).to eq "PetShopInputs"

    # the conventional single-schema layout (and anything unrecognizable)
    # shares the default module
    expect(GraphWeaver.inputs_module("app/graphql/generated")).to eq "GraphQLInputs"
    expect(GraphWeaver.inputs_module("spec/generated")).to eq "GraphQLInputs"
    expect(GraphWeaver.inputs_module("/tmp/d20260713-91-x2x")).to eq "GraphQLInputs"
  end

  it "prefers an explicit global override" do
    GraphWeaver.inputs_module = "MyInputs"
    expect(GraphWeaver.inputs_module("app/graphql/github/generated")).to eq "MyInputs"
  ensure
    GraphWeaver.inputs_module = nil
  end
end

describe "GraphWeaver.verify_generated!" do
  let(:root) { File.expand_path("..", __dir__) }

  it "passes when generated files are current (our own fixtures)" do
    expect(
      GraphWeaver.verify_generated!(
        schema: Demo::Schema,
        queries: File.join(root, "spec/queries"),
        output: File.join(root, "spec/generated"),
        client: Demo::Schema,
      ),
    ).to be true
  end

  it "passes on a CRLF checkout — git's autocrlf isn't staleness" do
    Dir.mktmpdir do |dir|
      source = File.join(root, "spec/generated")
      Dir[File.join(source, "**/*.rb")].each do |file|
        target = File.join(dir, file.delete_prefix("#{source}/"))
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, File.read(file).gsub("\n", "\r\n"))
      end

      expect(
        GraphWeaver.verify_generated!(
          schema: Demo::Schema,
          queries: File.join(root, "spec/queries"),
          output: dir,
          client: Demo::Schema,
        ),
      ).to be true
    end
  end

  it "raises naming the stale files" do
    Dir.mktmpdir do |dir|
      FileUtils.cp(Dir[File.join(root, "spec/generated/*.rb")], dir)
      File.write(File.join(dir, "person_query.rb"), "# stale\n")

      expect {
        GraphWeaver.verify_generated!(
          schema: Demo::Schema,
          queries: File.join(root, "spec/queries"),
          output: dir,
          client: Demo::Schema,
        )
      }.to raise_error(GraphWeaver::Error, /stale.*person_query\.rb/m)
    end
  end

  it "flags a generated file the queries no longer produce" do
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(root, "spec/generated/."), dir)
      # a query that was renamed or deleted: its module lingers, load_generated!
      # would keep requiring it
      FileUtils.cp(File.join(dir, "person_query.rb"), File.join(dir, "gone_query.rb"))

      expect {
        GraphWeaver.verify_generated!(
          schema: Demo::Schema,
          queries: File.join(root, "spec/queries"),
          output: dir,
          client: Demo::Schema,
        )
      }.to raise_error(GraphWeaver::Error, /stale.*gone_query\.rb/m)
    end
  end

  it "ships rake tasks for generate and verify" do
    require "rake"
    Rake::Task.tasks.each(&:clear) if Rake::Task.tasks.any?
    load File.join(root, "lib/graph_weaver/tasks.rb")

    expect(Rake::Task.task_defined?("graph_weaver:generate")).to be true
    expect(Rake::Task.task_defined?("graph_weaver:verify")).to be true
  end
end

describe "GraphWeaver.auto_coerce" do
  after do
    GraphWeaver.auto_coerce = nil
    GraphWeaver.reset_scalars!
  end

  let(:query) { "query Cast($id: ID!, $term: String!) { search(term: $term) { __typename ... on Named { name } } }" }

  it "defaults built-in coercion lazily — no reset_scalars! dance, any order" do
    mod = GraphWeaver.parse(
      schema: Demo::Schema,
      client: Demo::Schema,
      query: "query Sized($term: String!, $first: Int) { search(term: $term, first: $first) { __typename ... on Named { name } } }",
    )
    # parse happened BEFORE enabling? no — generation is what matters, so
    # enable first here; the point is no registry reset is needed
    GraphWeaver.auto_coerce = true
    coerced = GraphWeaver.parse(
      schema: Demo::Schema,
      client: Demo::Schema,
      query: "query Sized($term: String!, $first: Int) { search(term: $term, first: $first) { __typename ... on Named { name } } }",
    )

    expect(coerced.execute!(term: "el", first: "1").search.size).to eq 1 # "1" converted
    expect { mod.execute!(term: "el", first: "1") }.to raise_error(TypeError) # generated before: strict
  end

  it "gives cast/serialize scalars parse-style coercion; explicit coerce: false wins" do
    GraphWeaver.auto_coerce = true

    date_mod = GraphWeaver.parse(
      schema: Demo::Schema,
      client: Demo::Schema,
      query: "query People { people { birthday } }",
    )
    # Date has a full cast/serialize pair, so under auto_coerce a Date
    # VARIABLE would accept "2020-01-01" — output casting is unchanged
    expect(date_mod.execute!.people.first&.birthday).to be_a Date

    GraphWeaver.register_scalar("Date", Date, cast: :iso8601, serialize: :iso8601, requires: "date", coerce: false)
    expect(GraphWeaver::Codegen.scalar("Date").coerce?).to be false # explicit false beats auto
  end

  it "applies inside input objects too — mutations included" do
    GraphWeaver.auto_coerce = true

    mod = GraphWeaver.parse(
      schema: Demo::Schema,
      client: Demo::Schema,
      query: "mutation Adopt($input: AdoptionInput!) { adopt(input: $input) { name species } }",
    )

    # birthday as a raw iso8601 string (the input's fields flatten into
    # kwargs): the Date scalar's coercion (auto) parses it before the
    # struct type-checks
    pet = mod.execute!(name: "Rex", species: "DOG", birthday: "2020-06-15").adopt
    expect(pet.name).to eq "Rex"
  end
end
