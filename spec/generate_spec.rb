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
      types/species.rb types/adoption_input.rb types/pet_filter.rb types.rb
      add_pet_mutation.rb adopt_mutation.rb find_pets_query.rb named_query.rb person_query.rb search_query.rb
    ]
    # byte-identical to the checked-in fixtures (same generator, same inputs)
    expect(File.read(File.join(@dir, "person_query.rb")))
      .to eq File.read(File.join(root, "spec/generated/person_query.rb"))
  end

  it "leaves an unchanged file alone on a second run" do
    root = File.expand_path("..", __dir__)
    args = { schema: Demo::Schema, queries: File.join(root, "spec/queries"), output: @dir, client: Demo::Schema }
    written = GraphWeaver.generate!(**args)
    before = written.to_h { |path| [path, File.mtime(path)] }

    expect(GraphWeaver.generate!(**args)).to eq written
    expect(GraphWeaver.changed_files).to be_empty
    expect(written.to_h { |path| [path, File.mtime(path)] }).to eq before
  end

  # Rails.root.join(...) is how a Rails app spells a path
  it "takes a Pathname where it takes a schema path" do
    Dir.mktmpdir do |dir|
      schema = File.join(dir, "schema.graphql")
      File.write(schema, Demo::Schema.to_definition)
      queries = File.join(dir, "queries")
      FileUtils.mkdir_p(queries)
      File.write(File.join(queries, "pet.graphql"), "query { person(id: 1) { name } }\n")
      out = File.join(dir, "generated")

      expect(GraphWeaver.generate!(schema: Pathname.new(schema), queries:, output: out).size).to eq 1
    end
  end

  # ...and a query path is a path too. schema: took a Pathname and query:
  # didn't, which is the asymmetry, not the feature.
  it "takes a Pathname where it takes a query path" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "pet.graphql")
      File.write(path, "query { person(id: 1) { name } }\n")

      mod = GraphWeaver.parse(schema: Demo::Schema, query: Pathname.new(path))

      # named off the file rather than the anonymous operation, so the path
      # was read as a path (each parse gets its own container, hence the suffix)
      expect(mod.name).to end_with("PetQuery")
    end
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

  # numbering a corpus is a normal way to order it, and "01HomeQuery" isn't a
  # constant — with thirty files, which one is the only actionable fact
  it "names the query file whose name can't spell a constant" do
    queries = File.join(@dir, "queries")
    FileUtils.mkdir_p(queries)
    File.write(File.join(queries, "01_home_featured.graphql"), "query { person(id: 1) { name } }")

    expect { GraphWeaver.generate!(schema: Demo::Schema, queries:, output: @dir) }
      .to raise_error(GraphWeaver::Error, %r{\A.*/queries/01_home_featured\.graphql: name: must be a constant name, got "01HomeFeaturedQuery" — it comes from the file name, so rename})
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

  it "names the shared module the same wherever the output goes" do
    root = File.expand_path("..", __dir__)
    output = File.join(@dir, "github", "generated")
    GraphWeaver.generate!(
      schema: Demo::Schema,
      queries: File.join(root, "spec/queries"),
      output:,
      client: Demo::Schema,
    )

    # a public constant that moved when you renamed a directory was a rule you
    # couldn't state without reciting a blocklist
    expect(File.read(File.join(output, "types.rb"))).to include "module GraphQLTypes"
    expect(File.read(File.join(output, "adopt_mutation.rb"))).to include "GraphQLTypes::AdoptionInput"
  end

  it "takes an explicit module name per run, for multi-schema layouts" do
    root = File.expand_path("..", __dir__)
    GraphWeaver.generate!(
      schema: Demo::Schema,
      queries: File.join(root, "spec/queries"),
      output: @dir,
      client: Demo::Schema,
      types_module: "GithubTypes",
    )

    expect(File.read(File.join(@dir, "types.rb"))).to include "module GithubTypes"
    expect(File.read(File.join(@dir, "types/species.rb"))).to include "module GithubTypes"
    expect(File.read(File.join(@dir, "adopt_mutation.rb"))).to include "GithubTypes::AdoptionInput"
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

  # Dropping an extend_type leaves every file that included its mixin
  # referencing a constant nothing defines. Since generate depends on
  # :environment, the boot failure used to block its own repair.
  it "names the fix when a generated file expects a helper nothing registers" do
    generated = File.join(@dir, "generated")
    FileUtils.mkdir_p(generated)
    File.write(File.join(generated, "stale_query.rb"), <<~RUBY)
      module StaleQuery
        class Result
          include GraphWeaver::TypeHelpers::Ghost
        end
      end
    RUBY

    expect { GraphWeaver.load_generated!(generated) }
      .to raise_error(GraphWeaver::Error, /extend_type\("Ghost"\).*rake graph_weaver:generate/m)
  end

  it "names the fix when a generated file expects an app constant that is gone" do
    generated = File.join(@dir, "generated")
    FileUtils.mkdir_p(generated)
    File.write(File.join(generated, "stale_query.rb"), <<~RUBY)
      module StaleQuery
        class Result
          include PetHelpersGone # registered for Pet
        end
      end
    RUBY

    expect { GraphWeaver.load_generated!(generated) }
      .to raise_error(GraphWeaver::Error, /PetHelpersGone.*extend_type or register_enum.*rake graph_weaver:generate/m)
  end

  it "loads appended generated_paths — the spec-support pattern" do
    queries = File.join(@dir, "support/graphql/queries")
    output = File.join(@dir, "support/graphql/generated")
    FileUtils.mkdir_p(queries)
    File.write(File.join(queries, "appended_people.graphql"), "query { people { name } }")
    GraphWeaver.generate!(schema: Demo::Schema, queries:, output:, client: Demo::Schema)

    begin
      GraphWeaver.generated_paths << output
      expect(GraphWeaver.generated_paths.first).to eq "app/graphql/generated" # default untouched

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
      GraphWeaver.queries_paths = queries
      GraphWeaver.generated_paths = output

      written = GraphWeaver.generate!(schema: Demo::Schema, client: Demo::Schema)
      expect(written).to eq [File.join(output, "loaded_people_query.rb")]

      # and load_generated! requires them — the factory_bot-style one-liner
      GraphWeaver.load_generated!
      expect(defined?(::LoadedPeopleQuery)).to eq "constant"
      expect(LoadedPeopleQuery.execute!.people.map(&:name)).to eq ["Daniel"]
    ensure
      GraphWeaver.queries_paths = nil
      GraphWeaver.generated_paths = nil
    end
  end

  it "generates every queries_paths entry, and a String assigns as one" do
    engine = File.join(@dir, "engine/queries")
    app = File.join(@dir, "app/queries")
    [engine, app].each { |dir| FileUtils.mkdir_p(dir) }
    File.write(File.join(engine, "engine_people.graphql"), "query { people { name } }")
    File.write(File.join(app, "app_people.graphql"), "query { people { name } }")

    begin
      GraphWeaver.queries_paths = app
      expect(GraphWeaver.queries_paths).to eq [app] # a String is one entry

      GraphWeaver.queries_paths << engine
      written = GraphWeaver.generate!(schema: Demo::Schema, output: File.join(@dir, "generated"))

      expect(written.map { |path| File.basename(path) })
        .to eq %w[app_people_query.rb engine_people_query.rb]
    ensure
      GraphWeaver.queries_paths = nil
    end
  end

  # a mistyped queries_paths looks exactly like a brand-new app: generate!
  # printed nothing and exited 0, and verify_generated! returned true having
  # compared nothing, so a CI gate stayed green forever
  describe "no query documents" do
    let(:empty) { File.join(@dir, "querys") }

    it "warns from generate! and fails verify_generated!" do
      io = StringIO.new
      GraphWeaver.logger = Logger.new(io, level: Logger::WARN)

      expect(GraphWeaver.generate!(schema: Demo::Schema, queries: empty, output: @dir)).to be_empty
      expect(io.string).to include("nothing to generate")

      expect { GraphWeaver.verify_generated!(schema: Demo::Schema, queries: empty, output: @dir) }
        .to raise_error(GraphWeaver::Error, /proved nothing/)
    ensure
      GraphWeaver.logger = nil
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

describe "the shared module name" do
  it "is a constant, not a function of the output path" do
    expect(GraphWeaver.types_module).to eq "GraphQLTypes"
  end

  it "takes a global override" do
    GraphWeaver.types_module = "MyTypes"
    expect(GraphWeaver.types_module).to eq "MyTypes"
  ensure
    GraphWeaver.types_module = nil
  end
end

describe "GraphWeaver.verify_generated!" do
  # Shared with every other spec file that exercises these tasks (see
  # rake_tasks_spec's header comment on TASKS for why this must be a single
  # process-wide load rather than one per file).
  require "rake"
  unless defined?(TASKS)
    TASKS = Rake::Application.new
    begin
      previous, Rake.application = Rake.application, TASKS
      require "graph_weaver/tasks"
    ensure
      Rake.application = previous
    end
  end

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

  # a rake task beside a watching dev server writes the same file, and the
  # server requires it next: a truncating write can hand it a prefix
  it "leaves a regenerated file whole until the new one replaces it" do
    Dir.mktmpdir do |dir|
      queries = File.join(root, "spec/queries")
      GraphWeaver.generate!(schema: Demo::Schema, queries:, output: dir, client: Demo::Schema)
      # an identical file isn't rewritten at all, so give every one of them a diff
      Dir[File.join(dir, "**/*.rb")].each { |path| File.write(path, "#{File.read(path)}# stale\n") }
      before = Dir[File.join(dir, "**/*.rb")].to_h { |path| [path, File.read(path)] }

      # what a concurrent reader would see at the last possible moment
      seen = {}
      allow(File).to receive(:rename).and_wrap_original do |original, tmp, target|
        seen[target] = File.read(target)
        original.call(tmp, target)
      end
      GraphWeaver.generate!(schema: Demo::Schema, queries:, output: dir, client: Demo::Schema)

      expect(seen.keys).to match_array before.keys
      expect(seen).to eq before
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
    original = Rake.application
    Rake.application = TASKS

    expect(Rake::Task.task_defined?("graph_weaver:generate")).to be true
    expect(Rake::Task.task_defined?("graph_weaver:verify")).to be true
  ensure
    Rake.application = original
  end
end

describe "query directory scanning" do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  let(:queries) { File.join(@dir, "queries") }

  def write(name, source)
    path = File.join(queries, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    path
  end

  before do
    write("admin/pets.graphql", "query { people { name } }")
    write("owners.gql", "query { people { name } }")
  end

  it "generates from nested queries and .gql files" do
    output = File.join(@dir, "generated")
    written = GraphWeaver.generate!(schema: Demo::Schema, queries:, output:, client: Demo::Schema)

    # flat output: a directory organizes the queries, it doesn't namespace them
    expect(written.map { |path| File.basename(path) }).to eq %w[pets_query.rb owners_query.rb]
    # .gql keeps its extension out of the module name
    expect(File.read(File.join(output, "owners_query.rb"))).to include "module OwnersQuery"
  end

  it "checks nested queries and .gql files" do
    write("admin/pets.graphql", "query { people { nmae } }")
    write("owners.gql", "query { people { nmae } }")

    failures = GraphWeaver.check_queries(schema: Demo::Schema, queries:, fragments: [])
    expect(failures.keys.map { |path| path.delete_prefix("#{queries}/") })
      .to eq %w[admin/pets.graphql owners.gql]
  end

  it "loads nested queries and .gql files into modules" do
    namespace = Module.new
    GraphWeaver.new(Demo::Schema).load_queries!(queries, namespace:)

    expect(namespace.constants.sort).to eq %i[OwnersQuery PetsQuery]
  end

  it "refuses two files that generate the same module, naming both" do
    write("pets.graphql", "query { people { name } }")

    expect { GraphWeaver.generate!(schema: Demo::Schema, queries:, output: @dir, client: Demo::Schema) }
      .to raise_error(GraphWeaver::Error, %r{PetsQuery.*queries/admin/pets\.graphql.*queries/pets\.graphql}m)
  end
end
