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

    expect(written.map { |path| File.basename(path) })
      .to eq %w[add_pet_query.rb adopt_query.rb find_pets_query.rb named_query.rb person_query.rb search_query.rb]
    # byte-identical to the checked-in fixtures (same generator, same inputs)
    expect(File.read(File.join(@dir, "person_query.rb")))
      .to eq File.read(File.join(root, "spec/generated/person_query.rb"))
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
