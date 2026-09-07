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
  # Loaded ONCE, into an application of its own. Other specs `load` tasks.rb
  # per example, which resets Ruby's per-file coverage counters and leaves
  # whichever example ran last as the only one measured.
  TASKS = Rake::Application.new
  begin
    previous, Rake.application = Rake.application, TASKS
    load "graph_weaver/tasks.rb"
  ensure
    Rake.application = previous
  end

  Ran = Struct.new(:out, :err, :status)

  # Runs the task the way rake would, and reports both streams plus the exit
  # status — `abort` raises SystemExit, which must not escape into the suite.
  def invoke(name, out: StringIO.new, err: StringIO.new, **env)
    previous, Rake.application = Rake.application, TASKS
    TASKS.tasks.each(&:reenable) # rake runs a task once per process otherwise
    env.each { |key, value| ENV[key.to_s] = value }
    status = 0
    begin
      $stdout, $stderr = out, err
      TASKS["graph_weaver:#{name}"].invoke
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
    previous, Rake.application = Rake.application, TASKS
    Rake::Task.define_task(:environment) { boot.call }
    Rake.application = previous
    yield
  ensure
    # Rake has no public task removal, and one left behind would boot the app
    # for every later example
    TASKS.instance_variable_get(:@tasks).delete("environment")
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

    it "names the stale file and exits non-zero" do
      invoke("generate")
      File.write(File.join(@root, "generated", "person_query.rb"), "# edited by hand\n")

      result = invoke("verify")

      expect(result.status).to eq 1
      expect(result.err).to include "person_query.rb", "rake graph_weaver:generate"
    end
  end

  describe "graph_weaver:schema:diff" do
    it "names the path it looked at when there is no dump" do
      result = invoke("schema:diff")

      expect(result.status).to eq 1
      expect(result.err).to eq "no schema dump at #{GraphWeaver.schema_path}\n"
    end

    it "says the dump matches, and exits zero" do
      write_schema
      allow(GraphWeaver::SchemaLoader).to receive(:stale?).and_return(false)

      expect(invoke("schema:diff"))
        .to have_attributes(status: 0, out: "#{GraphWeaver.schema_path} matches the server\n")
    end

    it "names the task that repairs a drifted dump, and exits non-zero" do
      write_schema
      allow(GraphWeaver::SchemaLoader).to receive(:stale?).and_return(true)

      result = invoke("schema:diff")

      expect(result.status).to eq 1
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
      allow(GraphWeaver::Schemas).to receive(:loaded).and_return([])

      result = invoke("federation:diff", SUPERGRAPH: RouterGraph::SUPERGRAPH)

      expect(result.status).to eq 1
      expect(result.err).to include "config.rake_eager_load"
    end

    it "says what to pass when there is no supergraph to compare against" do
      result = invoke("federation:diff")

      expect(result.status).to eq 1
      expect(result.err).to include "SUPERGRAPH=supergraph.graphql"
    end
  end

  describe "graph_weaver:federation:subgraphs" do
    it "says what to pass when there is no supergraph" do
      result = invoke("federation:subgraphs")

      expect(result.status).to eq 1
      expect(result.err).to include "SUPERGRAPH=supergraph.graphql"
    end

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
      expect(result.out.lines.first).to eq "17/17 queries plannable locally (100%)\n"
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
  end
end
