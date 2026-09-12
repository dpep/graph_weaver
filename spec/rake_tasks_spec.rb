# typed: ignore — Rake DSL, and the tasks are loaded rather than required
# frozen_string_literal: true

require "rake"
require "stringio"
require "tmpdir"
require "yaml"

require "graph_weaver/testing"

# The rake tasks as a user invokes them: what they print, on which stream, and
# what status the shell sees. The suite can't boot a Rails app, but it can run
# the tasks — and every task body here was reachable only by hand before.
describe "graph_weaver rake tasks" do
  Ran = Struct.new(:out, :err, :status)

  # A desc IS the claim that a task is for users — it is what `rake -T` shows —
  # so a desc'd task nobody documented is a feature shipped in the dark, and a
  # documented one that no longer exists is a command that fails when typed.
  # (`graph_weaver:environment` and `federation:loaded` carry no desc: they are
  # plumbing other tasks depend on.)
  it "documents every task rake -T lists, and lists every task documented" do
    prose = (Dir[File.expand_path("../docs/*.md", __dir__)] + [File.expand_path("../README.md", __dir__)])
      .map { |path| File.read(path) }.join

    described = RakeHarness.application.tasks.select(&:comment).map(&:name)
    expect(described.reject { |name| prose.include?(name) }).to be_empty
    expect(prose.scan(/rake (graph_weaver:[\w:]+)/).flatten.uniq - described).to be_empty
  end

  # A desc is baked when the Rakefile loads — in Rails that is before
  # :environment, so before an initializer can move queries_paths. The only
  # path it can honestly name is the default.
  it "names the generate paths as defaults, not as the configured value" do
    expect(RakeHarness.application["graph_weaver:generate"].comment)
      .to match(%r{default app/graphql/queries -> app/graphql/generated})
  end

  # Runs the task the way rake would, and reports both streams plus the exit
  # status — `abort` raises SystemExit, which must not escape into the suite.
  def invoke(name, out: StringIO.new, err: StringIO.new, **env)
    previous, Rake.application = Rake.application, RakeHarness.application
    RakeHarness.application.tasks.each(&:reenable) # rake runs a task once per process otherwise
    env.each { |key, value| ENV[key.to_s] = value }
    status = 0
    begin
      $stdout, $stderr = out, err
      RakeHarness.application["graph_weaver:#{name}"].invoke
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = STDOUT, STDERR
      env.each_key { |key| ENV.delete(key.to_s) }
      Rake.application = previous
    end
    Ran.new(out.respond_to?(:string) ? out.string : nil, err.respond_to?(:string) ? err.string : nil, status)
  end

  # Rails defines :environment AFTER every railtie's rake_tasks block, so a
  # task can only ask for it when it runs. Defining it here reproduces that
  # ordering: tasks.rb was loaded above, long before this.
  def with_environment(boot)
    previous, Rake.application = Rake.application, RakeHarness.application
    Rake::Task.define_task(:environment) { boot.call }
    Rake.application = previous
    yield
  ensure
    # Rake has no public task removal, and one left behind would boot the app
    # for every later example
    RakeHarness.application.instance_variable_get(:@tasks).delete("environment")
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      FileUtils.mkdir_p(File.join(dir, "queries"))
      GraphWeaver.queries_paths = File.join(dir, "queries")
      GraphWeaver.generated_paths = File.join(dir, "generated")
      GraphWeaver.fragments_paths = File.join(dir, "fragments")
      GraphWeaver.schema_path = File.join(dir, "schema.graphql")
      example.run
    end
  ensure
    GraphWeaver.queries_paths = nil
    GraphWeaver.generated_paths = nil
    GraphWeaver.fragments_paths = nil
    GraphWeaver.schema_path = nil
    GraphWeaver.reset_registrations!
    GraphWeaver::Testing.reset!
  end

  def write_query(name, source) = File.write(File.join(@root, "queries", name), source)

  def write_schema(sdl = Demo::Schema.to_definition) = File.write(GraphWeaver.schema_path, sdl)

  def generated(name) = File.read(File.join(@root, "generated", name))

  describe "graph_weaver:generate" do
    it "names every file it wrote" do
      write_schema
      write_query("person.graphql", "query Person { person(id: \"1\") { name } }")

      result = invoke("generate")

      expect(result.status).to eq 0
      expect(result.out).to eq "wrote #{@root}/generated/person_query.rb\n"
      expect(generated("person_query.rb")).to include "module PersonQuery"
    end

    # a build log is read on another machine, and the setting it echoes is the
    # one in graphql.config.yml — absolute paths there belong to nobody
    it "prints the paths it wrote and pruned relative to the root" do
      GraphWeaver.root = @root
      GraphWeaver.queries_paths = "queries"
      GraphWeaver.generated_paths = "generated"
      GraphWeaver.schema_path = "schema.graphql"
      File.write(File.join(@root, "schema.graphql"), Demo::Schema.to_definition)
      write_query("person.graphql", "query Person { person(id: \"1\") { name } }")

      expect(invoke("generate").out).to eq "wrote generated/person_query.rb\n"

      File.delete(File.join(@root, "queries", "person.graphql"))
      expect(invoke("generate").out).to include "pruned generated/person_query.rb"
    ensure
      GraphWeaver.root = nil
    end

    it "says a file it left alone is up to date, rather than claiming to write it" do
      write_schema
      write_query("person.graphql", "query Person { person(id: \"1\") { name } }")
      invoke("generate")

      result = invoke("generate")

      expect(result.status).to eq 0
      expect(result.out).not_to include "wrote"
      expect(result.out).to include "1 already up to date"
    end

    # deleting the .graphql prunes the generated file — checked-in code, so a
    # run that removed one and printed nothing left the diff to be discovered
    it "names the file it pruned when a query is gone" do
      write_schema
      write_query("person.graphql", "query Person { person(id: \"1\") { name } }")
      invoke("generate")
      File.delete(File.join(@root, "queries", "person.graphql"))

      result = invoke("generate")

      expect(result.status).to eq 0
      expect(result.out).to include "pruned #{@root}/generated/person_query.rb"
    end

    # the state every install starts in: silence and exit 0 read as "done"
    it "says where it looked when there are no queries" do
      write_schema

      result = invoke("generate")

      expect(result.status).to eq 0
      expect(result.out).to eq "no queries in #{@root}/queries\n"
    end

    # the logger is silent by default and Rails' writes to a file, so a
    # registration this schema can't match has to reach the build's own output
    # — once for the run, not once per query file
    it "names an unmatched registration once, however many queries" do
      write_schema
      3.times { |i| write_query("q#{i}.graphql", "query Q#{i} { person(id: \"1\") { name } }") }
      GraphWeaver.register_scalar("Money", String, cast: :itself, serialize: :itself)

      result = invoke("generate")

      expect(result.status).to eq 0
      expect(result.out.scan(/register_scalar\("Money"\)/).size).to eq 1
      expect(result.out).to include "matches no scalar in", "or a registration for another schema"
    end

    # The task's other advisory went to the logger alone, so one run said half
    # of what it found on the terminal and half into log/development.log. One
    # task, one destination — and once for the run, not once per query file.
    it "names the unregistered custom scalars once, where the unmatched ones print" do
      write_schema
      2.times { |i| write_query("m#{i}.graphql", "query M#{i} { findPets { metadata } }") }

      result = invoke("generate")

      expect(result.status).to eq 0
      expect(result.out.scan(/unregistered custom scalar/).size).to eq 1
      expect(result.out).to include "1 unregistered custom scalar → T.untyped: Metadata " \
        "(register with GraphWeaver.register_scalar)"
    end

    # a typo'd query is a user error: the message names file, position and
    # fix, and a rake backtrace through codegen only buries it
    it "names the file and position for a bad query, and exits non-zero" do
      write_schema
      write_query("person.graphql", "query Person { person(id: \"1\") { nosuch } }")

      result = invoke("generate")

      expect(result.status).to eq 1
      expect(result.err).to include "person.graphql", "nosuch", "Person"
      expect(result.err).not_to include "rake aborted"
      expect(result.out).to be_empty
    end

    # THE bug: the task asked `Rake::Task.task_defined?("environment")` at
    # LOAD time, and Rails defines :environment after every railtie's
    # rake_tasks block — so the app never booted and every register_scalar /
    # extend_type in an initializer was silently dropped from the output.
    it "boots the app first, so an initializer's registrations reach the generated source" do
      write_schema
      write_query("find_pets.graphql", "query FindPets { findPets { name metadata } }")

      with_environment(-> { GraphWeaver.register_scalar("Metadata", String, cast: :to_s) }) do
        expect(invoke("generate").status).to eq 0
      end

      # T.untyped is what an unregistered scalar emits — i.e. what a dropped
      # initializer looks like in the file a user reads
      expect(generated("find_pets_query.rb")).to include "const :metadata, T.nilable(String)"
    end

    # only meaningful while booting: left set, it would silently disable
    # generated-module loading for anything that boots later in the process
    it "unsets skip_generated_load once the app is booted" do
      write_schema
      seen = nil

      with_environment(-> { seen = GraphWeaver.skip_generated_load }) do
        invoke("generate")
      end

      expect(seen).to be true
      expect(GraphWeaver.skip_generated_load).to be false
    end
  end

  describe "graph_weaver:verify" do
    before do
      write_schema
      write_query("person.graphql", "query Person { person(id: \"1\") { name } }")
    end

    it "says so and exits zero when the generated files match" do
      invoke("generate")

      expect(invoke("verify")).to have_attributes(status: 0, out: "generated queries up to date\n", err: "")
    end

    it "names an unmatched registration too, so CI reads the same as the build" do
      invoke("generate")
      GraphWeaver.register_scalar("Money", String, cast: :itself, serialize: :itself)

      expect(invoke("verify").out).to include %{register_scalar("Money") matches no scalar in}
    end

    it "names the stale file and exits non-zero" do
      invoke("generate")
      File.write(File.join(@root, "generated", "person_query.rb"), "# edited by hand\n")

      result = invoke("verify")

      expect(result.status).to eq 1
      expect(result.err).to include "person_query.rb", "rake graph_weaver:generate"
    end
  end

  describe "graph_weaver:schema:diff" do
    # its sibling :refresh already said which task takes a dump; this one
    # stopped at "there isn't one", leaving the reader to find the other task
    it "names the path it looked at, and the task that takes a dump" do
      result = invoke("schema:diff")

      expect(result.status).to eq 1
      expect(result.err).to include "no schema dump at #{GraphWeaver.schema_path}",
        "rake graph_weaver:schema:refresh URL="
    end

    def diff_between(before, after)
      GraphWeaver::SchemaDiff.new(
        GraphQL::Schema.from_definition(before), GraphQL::Schema.from_definition(after)
      )
    end

    it "says the dump matches, and exits zero" do
      write_schema
      allow(GraphWeaver::SchemaLoader).to receive(:diff).and_return(diff_between("type Query { a: String }", "type Query { a: String }"))

      expect(invoke("schema:diff"))
        .to have_attributes(status: 0, out: "#{GraphWeaver.schema_path} matches the server\n")
    end

    # the whole point of the task: refreshing and diffing a 3 MB dump to
    # learn what moved is not a report
    it "prints what changed before naming the task that repairs it" do
      write_schema
      allow(GraphWeaver::SchemaLoader).to receive(:diff).and_return(
        diff_between("type Query { a: String b: Int }", "type Query { a: String c: Int }"),
      )

      result = invoke("schema:diff")

      expect(result.status).to eq 1
      expect(result.out).to include "2 changes, 1 breaking", "Query.b  removed", "Query.c  added: Int"
      expect(result.err).to include "is stale", "rake graph_weaver:schema:refresh"
    end

    # a dump with no recorded url can't be re-introspected — a clean abort,
    # not a backtrace out of the transport
    it "reports a dump it can't re-fetch as a message, not a crash" do
      write_schema

      result = invoke("schema:diff")

      expect(result.status).to eq 1
      expect(result.err).to include "records no source url"
      expect(result.err.lines.size).to eq 1
    end
  end

  describe "graph_weaver:schema:refresh" do
    it "names the dump it wrote and where it came from" do
      allow(GraphWeaver::SchemaLoader).to receive(:refresh!)
        .and_return(["app/graphql/schema.json", "https://api.example.com/graphql"])

      expect(invoke("schema:refresh")).to have_attributes(
        status: 0,
        out: "refreshed app/graphql/schema.json from https://api.example.com/graphql\n",
      )
    end

    it "passes URL= through, so the first dump can be bootstrapped" do
      allow(GraphWeaver::SchemaLoader).to receive(:refresh!).and_return(["schema.json", "https://x/graphql"])

      invoke("schema:refresh", URL: "https://x/graphql")

      expect(GraphWeaver::SchemaLoader).to have_received(:refresh!).with(url: "https://x/graphql")
    end

    # a path or SDL in URL= reaches introspection as a schema source, and the
    # error it fails with is about file extensions rather than the flag typed
    it "refuses a URL= that isn't an endpoint" do
      result = invoke("schema:refresh", URL: "db/schema.graphql")

      expect(result.status).to eq 1
      expect(result.err).to include "URL= takes an endpoint"
    end

    # with no dump and no URL=, the only useful answer is how to supply one
    it "says how to bootstrap when there is nothing to refresh from" do
      result = invoke("schema:refresh")

      expect(result.status).to eq 1
      expect(result.err).to include "no schema dump at #{GraphWeaver.schema_path}", "URL=https://"
    end
  end

  describe "graph_weaver:queries:check" do
    let(:failures) do
      { "queries/person.graphql" => [{ "message" => "Field 'titel' doesn't exist on type 'Media'", "line" => 4, "column" => 5 }] }
    end

    it "exits non-zero, counting the invalid queries" do
      allow(GraphWeaver).to receive(:check_queries).and_return(failures)

      expect(invoke("queries:check")).to have_attributes(status: 1, err: "1 invalid query\n")
    end

    # `abort` writes to unbuffered stderr while `puts` goes to block-buffered
    # stdout, so in any piped CI log the verdict arrived BEFORE the detail it
    # was a verdict about. A StringIO can't see this — it needs a real pipe.
    it "flushes the detail before the verdict, so a piped log reads in order" do
      allow(GraphWeaver).to receive(:check_queries).and_return(failures)
      read, write = IO.pipe
      write.sync = false # a pipe is block-buffered; a terminal is not
      stderr = IO.new(write.fileno, "w", autoclose: false)
      stderr.sync = true

      invoke("queries:check", out: write, err: stderr)
      stderr.close # flushes; autoclose: false leaves the fd to `write`
      write.close

      expect(read.read).to eq <<~LOG
        queries/person.graphql
          4:5  Field 'titel' doesn't exist on type 'Media'

        1 invalid query
      LOG
    end

    it "exits zero when every query validates" do
      allow(GraphWeaver).to receive(:check_queries).and_return({})

      expect(invoke("queries:check"))
        .to have_attributes(status: 0, out: "every query validates against the schema\n", err: "")
    end
  end

  describe "graph_weaver:federation:diff" do
    # a green "matches" on exit 0 having compared nothing is worse than a
    # failure, so the passing case is worth pinning as hard as the failing one
    it "exits zero when the supergraph matches the subgraphs here" do
      expect(invoke("federation:diff", SUPERGRAPH: RouterGraph::SUPERGRAPH))
        .to have_attributes(status: 0, err: "")
    end

    # A stock Rails app leaves config.rake_eager_load false, so a rake process
    # has no subgraph loaded at all — and this printed a green "matches" and
    # exited 0, a CI gate permanently passing while verifying nothing. The
    # message is pinned in federation_drift_spec; what CI actually reads is
    # the status.
    it "exits non-zero when no subgraph here was loaded to compare against" do
      allow(GraphWeaver::Internal::Schemas).to receive(:loaded).and_return([])

      result = invoke("federation:diff", SUPERGRAPH: RouterGraph::SUPERGRAPH)

      expect(result.status).to eq 1
      expect(result.err).to include "config.rake_eager_load"
    end

    # THE bug: an app that declared where its supergraph is had already said
    # so, and the task asked SchemaLoader for the conventional dump instead —
    # so it refused describing a file the user never pointed at, naming
    # neither the flag nor the graph.
    it "checks each declared graph that names a supergraph, heading each by name" do
      write_schema
      GraphWeaver.graph(:catalog) { schema GraphWeaver.schema_path }
      GraphWeaver.graph(:accounts) { schema RouterGraph::SUPERGRAPH }

      result = invoke("federation:diff")

      expect(result.status).to eq 0
      expect(result.out).to include "graph :accounts", "matches the schemas here"
      # :catalog names an API schema, so there is nothing federated to check
      expect(result.out).not_to include "graph :catalog"
    ensure
      GraphWeaver.reset_graphs!
    end
  end

  describe "graph_weaver:federation:subgraphs" do
    # the map is meant to be pasted into config — an ambiguous entry has to
    # read as "you pick", not as a schema this picked for you
    it "leaves an ambiguous subgraph nil, naming every schema that fits" do
      result = invoke("federation:subgraphs", SUPERGRAPH: SplitGraph::SUPERGRAPH)

      expect(result.status).to eq 0
      expect(result.out).to include %("b" => nil,),
        "# AMBIGUOUS: SplitGraph::B::Schema, SplitGraph::Twin::Schema all match — pick one"
    end
  end

  describe "graph_weaver:federation:coverage" do
    it "reports what the local router can plan" do
      result = invoke(
        "federation:coverage",
        SUPERGRAPH: RouterGraph::SUPERGRAPH,
        QUERIES: File.expand_path("support/federation/queries", __dir__),
      )

      expect(result.status).to eq 0
      expect(result.out.lines.first).to eq "17/17 queries plannable locally (100%), 17 servable here\n"
    end

    # with the routing table incomplete every number it would print is a
    # guess, so the construct it can't read IS the report
    it "names the construct it can't read rather than reporting a number" do
      path = File.join(@root, "supergraph.graphql")
      File.write(path, File.read(RouterGraph::SUPERGRAPH).sub(
        "type Announcement\n  @join__type(graph: REVIEWS)",
        "type Announcement\n  @join__type(graph: REVIEWS)\n  @join__directive(graphs: [REVIEWS], name: \"x\")",
      ))

      result = invoke("federation:coverage", SUPERGRAPH: path)

      expect(result.status).to eq 1
      expect(result.err).to include "@join__directive"
    end
  end

  # all three take the same argument and refuse the same way, and each has to
  # name ITS OWN task in the copy-pasteable line it prints
  %w[diff subgraphs coverage].each do |name|
    describe "graph_weaver:federation:#{name}" do
      # "no routing table here" described whichever file locate_path found —
      # a file the adopter never pointed at — and named neither the flag nor
      # the graph. The refusal says where it looked, per graph, and both ways
      # to answer it.
      it "says where it looked and what to pass when nothing here is composed" do
        result = invoke("federation:#{name}")

        expect(result.status).to eq 1
        expect(result.err).to eq <<~ABORT
          no composed supergraph here — a federation task reads the @join__* routing table, and nothing this app declares carries one:
            this app's schema: nothing on disk at #{GraphWeaver.schema_path}
          Pass one for this run — rake graph_weaver:federation:#{name} SUPERGRAPH=supergraph.graphql — or name it where the graph is declared, so every run finds it: GraphWeaver.graph(:api) { schema "supergraph.graphql" }.
        ABORT
      end

      # a multi-graph app's whole question is "why not mine" — so the
      # refusal names each graph and what it found there, not one dump
      it "names every graph it looked at, and what it found there" do
        write_schema
        GraphWeaver.graph(:catalog) { schema GraphWeaver.schema_path }
        GraphWeaver.graph(:billing) { schema -> { Demo::Schema } }

        result = invoke("federation:#{name}")

        expect(result.status).to eq 1
        expect(result.err).to include "graph :catalog: #{GraphWeaver.schema_path}",
          "graph :billing: Demo::Schema, a live class",
          "GraphWeaver.graph(:catalog) { schema \"supergraph.graphql\" }"
      ensure
        GraphWeaver.reset_graphs!
      end

      it "aborts with one line when the supergraph isn't a composed one" do
        result = invoke("federation:#{name}", SUPERGRAPH: "type Query { hi: String }")

        expect(result.status).to eq 1
        expect(result.err.lines.size).to eq 1
        expect(result.out).to be_empty
      end
    end
  end

  # The one check that reads a recording from someone else's server, so it is
  # also the one that reads the generated modules a recording is checked against.
  describe "graph_weaver:cassettes:check" do
    def record(query, response)
      dir = GraphWeaver::Testing.config.cassette_dir = File.join(@root, "cassettes")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "recording.yml"),
        [{ "query" => query, "variables" => {}, "response" => response }].to_yaml)
    end

    # each example's module name has to be its own: load_generated! requires,
    # so a second file defining the same constant would collide
    def generate_module(name)
      write_schema
      write_query("#{name}.graphql", "query { person(id: \"1\") { name } }")
      invoke("generate")
      GraphWeaver.load_generated!
      Object.const_get("#{name.split("_").map(&:capitalize).join}Query")
    end

    it "says so when every recording still casts" do
      mod = generate_module("cassette_fresh")
      record(mod::QUERY, { "data" => { "person" => { "name" => "Daniel" } } })

      expect(invoke("cassettes:check")).to have_attributes(status: 0, out: end_with("every recording still casts\n"))
    end

    # the failure this exists to move: without it the cast error surfaces
    # mid-spec naming a struct and a sorbet frame, and nothing points here
    it "names how many recordings went stale, and exits non-zero" do
      mod = generate_module("cassette_stale")
      record(mod::QUERY, { "data" => { "person" => {} } })

      result = invoke("cassettes:check")

      expect(result.status).to eq 1
      expect(result.err).to include "1 stale recording", "GRAPHWEAVER_RECORD=1"
    end

    # a green run that compared nothing would pass whatever the recordings said
    it "refuses when no recording carries a query any module sends" do
      generate_module("cassette_unmatched")
      record("query Other { person(id: \"2\") { name } }", { "data" => { "person" => { "name" => "x" } } })

      result = invoke("cassettes:check")

      expect(result.status).to eq 1
      expect(result.err).to include "this checked nothing"
    end

    # A graph's namespace is where its constants live, so a task looking for
    # top-level ones finds none — and then refuses for having checked nothing,
    # blaming the cassette directory for a recording that was fine.
    it "finds the modules of a namespaced graph" do
      write_schema
      write_query("namespaced.graphql", "query { person(id: \"1\") { name } }")
      GraphWeaver.graph :namespaced do
        queries File.join(GraphWeaver.queries_paths.first)
        output File.join(GraphWeaver.generated_paths.first)
        namespace "CassetteNs"
      end
      invoke("generate")
      GraphWeaver.load_generated!
      record(CassetteNs::NamespacedQuery::QUERY, { "data" => { "person" => { "name" => "Daniel" } } })

      result = invoke("cassettes:check")

      expect(result.status).to eq 0
      expect(result.out).to include "1 checked"
      expect(result.out).to end_with "every recording still casts\n"
    ensure
      GraphWeaver.reset_graphs!
    end
  end

  describe "graph_weaver:cassettes:anonymize" do
    it "replaces recorded values in every cassette, naming each one" do
      write_schema
      GraphWeaver::Testing.config.cassette_dir = File.join(@root, "cassettes")
      FileUtils.mkdir_p(GraphWeaver::Testing.config.cassette_dir)
      path = File.join(GraphWeaver::Testing.config.cassette_dir, "person.yml")
      File.write(path, [{
        "query" => "query Person($id: ID!) { person(id: $id) { name } }",
        "variables" => { "id" => "1" },
        "response" => { "data" => { "person" => { "name" => "Daniel Pepper" } } },
      }].to_yaml)

      result = invoke("cassettes:anonymize")

      expect(result.status).to eq 0
      expect(result.out).to eq "anonymized #{path}\n"
      name = YAML.safe_load_file(path).first.dig("response", "data", "person", "name")
      expect(name).to be_a String
      expect(name).not_to eq "Daniel Pepper"
    end

    # every sibling task locates the dump (schema_path, else the first sibling
    # extension that exists) rather than opening schema_path itself — this one
    # opened it, so an app whose committed dump is SDL got Errno::ENOENT
    it "finds a dump whose extension isn't schema_path's" do
      GraphWeaver.schema_path = File.join(@root, "schema.json")
      File.write(File.join(@root, "schema.graphql"), Demo::Schema.to_definition)
      GraphWeaver::Testing.config.cassette_dir = File.join(@root, "cassettes")
      FileUtils.mkdir_p(GraphWeaver::Testing.config.cassette_dir)
      path = File.join(GraphWeaver::Testing.config.cassette_dir, "person.yml")
      File.write(path, [{
        "query" => "query Person($id: ID!) { person(id: $id) { name } }",
        "variables" => { "id" => "1" },
        "response" => { "data" => { "person" => { "name" => "Daniel Pepper" } } },
      }].to_yaml)

      expect(invoke("cassettes:anonymize")).to have_attributes(status: 0, out: "anonymized #{path}\n")
    end

    # config.cassette_dir is relative by default and rake runs from wherever
    # it runs from — Testing.cassette_dir resolves it against Rails.root for
    # exactly that reason, and Cassette.new already goes through it. A task
    # reading config directly looks somewhere else than the recordings live.
    it "resolves a relative cassette_dir against Rails.root" do
      write_schema
      stub_const("Rails", Module.new { def self.root = @root })
      Rails.instance_variable_set(:@root, Pathname.new(@root))
      GraphWeaver::Testing.config.cassette_dir = "cassettes"
      FileUtils.mkdir_p(File.join(@root, "cassettes"))
      path = File.join(@root, "cassettes", "person.yml")
      File.write(path, [{
        "query" => "query Person($id: ID!) { person(id: $id) { name } }",
        "variables" => { "id" => "1" },
        "response" => { "data" => { "person" => { "name" => "Daniel Pepper" } } },
      }].to_yaml)

      result = invoke("cassettes:anonymize")

      expect(result.status).to eq 0
      # found under the root, and reported back in the short form it was configured as
      expect(result.out).to eq "anonymized cassettes/person.yml\n"
      expect(File.read(path)).not_to include "Daniel Pepper"
    end

    # silence and exit 0 read as "done"; every sibling task says where it
    # looked, and a cassette_dir pointing somewhere else is the likely reason
    it "says where it looked when there are no recordings" do
      write_schema
      GraphWeaver::Testing.config.cassette_dir = File.join(@root, "cassettes")

      result = invoke("cassettes:anonymize")

      expect(result.status).to eq 0
      expect(result.out).to eq "no recordings in #{@root}/cassettes\n"
    end
  end
end
