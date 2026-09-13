# typed: ignore — Rake DSL at top level, loaded from Rakefiles
# frozen_string_literal: true

# Rake tasks — add to your Rakefile:
#
#      require "graph_weaver/tasks"
#
# The tasks use the conventional paths (GraphWeaver.queries_paths /
# generated_paths / schema_path — override in your Rakefile or an
# initializer). Register custom scalars before the tasks run — they're
# baked into generated source.
#
# Each task names its own subject — generated code, the schema dump, the
# queries — so which question you're asking is the task name:
#
#      rake graph_weaver:generate        # queries_paths -> generated_paths.first
#      rake graph_weaver:graphs          # which graphs this app has, and where each writes
#      rake graph_weaver:verify          # fail if generated files are stale (CI)
#      rake graph_weaver:unused          # report selections no code reads
#      rake graph_weaver:queries:check   # fail if a query no longer validates (CI)
#      rake graph_weaver:schema:diff     # fail if the server has drifted from the dump
#      rake graph_weaver:schema:refresh  # re-introspect and rewrite the dump
#      rake graph_weaver:federation:diff       # fail if the supergraph wasn't recomposed
#      rake graph_weaver:federation:coverage   # what the local test router can plan
#      rake graph_weaver:federation:subgraphs  # which schema serves which subgraph
#      rake graph_weaver:cassettes:check       # fail if a recording no longer casts
require_relative "../graph_weaver"

module GraphWeaver
  module Internal
    # helpers the rake tasks share
    module Tasks
      # What a federation task runs over: SUPERGRAPH= for one run, else every
      # declared graph that names a composed supergraph — an app that said
      # where its supergraph is has already answered. Each entry is the graph
      # and its supergraph; SUPERGRAPH= has no graph behind it, so a
      # single-schema app's output is what it always was.
      def self.supergraphs!(task)
        return [[nil, ENV["SUPERGRAPH"]]] if ENV["SUPERGRAPH"]

        found = GraphWeaver.graphs.filter_map do |graph|
          supergraph = graph.supergraph
          [graph, supergraph] if supergraph
        end
        found.empty? ? abort(no_supergraph(task)) : found
      end

      # The other half of :diff — every task here walks the supergraph's
      # subgraph list, so a subgraph dropped from the composition whose Ruby
      # class is still loaded was invisible to all of them. Asked once over
      # the whole run: a multi-graph app's other supergraph places its own
      # schemas, so only one no supergraph here has a subgraph for is named.
      #
      # A warning, not a failure. A process that loads a subgraph of a
      # supergraph this run never reads is the same picture — the gem's own
      # suite is one — and failing on it would break a setup that is fine.
      def self.warn_unplaced(drifts)
        unplaced = drifts.map(&:unplaced).reduce(:&).to_a
        return if unplaced.empty?

        names = drifts.flat_map(&:subgraphs).uniq.sort
        warn "", "not placed — no subgraph of any supergraph read here is:",
          *unplaced.map { |schema| "  #{schema.name}" },
          "A subgraph retired from a composition leaves exactly this behind, and so does a " \
            "process that loads a subgraph of a supergraph nobody here reads — which is why " \
            "this is a warning and not drift. The subgraphs read here: #{names.join(", ")}."
      end

      # The spellings a CI config turns a flag off with. STRICT=0 used to be
      # "set, therefore on" — the one answer nobody means by it.
      OFF = %w[0 false no off].freeze

      # An ENV flag, as a boolean: unset, empty and the OFF spellings are off,
      # anything else is on.
      def self.flag?(name)
        value = ENV[name].to_s.strip
        !value.empty? && !OFF.include?(value.downcase)
      end

      # Every directory the app's graphs read queries from, and whether any
      # holds one. Two tasks reach an empty app and both should say the same
      # sentence about it rather than report 0 of 0 and advise a generate that
      # would generate nothing.
      def self.query_dirs = GraphWeaver.graphs.flat_map(&:queries).uniq

      def self.no_queries = "no queries in #{query_dirs.join(", ")}"

      def self.queries? = GraphWeaver::Internal::Util.query_files(query_dirs).any?

      # A section heading, so a multi-graph app can tell whose report it is
      # reading. Nothing for the default graph: a single-schema app never
      # said the word "graph" and its output shouldn't either.
      def self.heading(graph) = ("graph #{graph.name.inspect}" if graph&.name)

      # Which graphs a verdict is about — "graph :a, graph :b: " — or nothing
      # at all, so a single-schema app's aborts read exactly as they did.
      def self.whose(graphs)
        named = graphs.filter_map { |graph| heading(graph) }
        named.empty? ? "" : "#{named.join(", ")}: "
      end

      # Nothing composed anywhere. Says where it looked — one line per graph,
      # because the adopter's question is "why didn't it find mine" — then the
      # two ways to answer it.
      def self.no_supergraph(task)
        declared = GraphWeaver.graphs
        example = declared.map(&:name).compact.first || :api
        ["no composed supergraph here — a federation task reads the @join__* routing table, " \
          "and nothing this app declares carries one:",
          *declared.map { |graph| "  #{looked_at(graph)}" },
          "Pass one for this run — rake graph_weaver:federation:#{task} " \
            "SUPERGRAPH=supergraph.graphql — or name it where the graph is declared, so every " \
            "run finds it: GraphWeaver.graph(#{example.inspect}) { schema \"supergraph.graphql\" }."]
          .join("\n")
      end

      # Where one graph's schema came from, in the three shapes it comes in.
      def self.looked_at(graph)
        label = graph.name ? "graph #{graph.name.inspect}" : "this app's schema"
        path = graph.dump_path
        return "#{label}: #{GraphWeaver::Internal::Util.relative(path)}" if path

        live = graph.live_schema
        found =
          if live then "#{live.name}, a live class — composition is what writes a routing table"
          else "nothing on disk at #{GraphWeaver.schema_path}"
          end
        "#{label}: #{found}"
      end
      private_class_method :looked_at

      # What the run found worth saying about the registry, once each: the
      # registrations it couldn't match, and the scalars nothing registered.
      # The logger is the runtime channel and is silent by default (in Rails it
      # writes to a file); this task's own output is the build channel, and the
      # build is where someone regenerating is looking — so both advisories go
      # there rather than one each way.
      def self.report_registry
        GraphWeaver.unmatched_registrations.each { |message| puts message }
        report = GraphWeaver::Internal::Util.untyped_scalars_report(GraphWeaver.untyped_scalars_by_graph)
        puts report if report
      end

      # What one graph registers, for the graphs task — the answer an app
      # otherwise reads out of every initializer by hand. A pre-registered
      # built-in isn't app intent; one an app has REPLACED is, which is why
      # this asks whether the entry is still the library's rather than
      # dropping the built-in names.
      def self.registrations(graph)
        registry = graph.registry
        {
          "scalars" => registry.scalar_registry.keys.reject { |name| registry.builtin_scalar?(name) },
          "enums" => registry.enum_registry.keys,
          "extend_type" => registry.type_registry.keys,
        }.filter_map { |kind, names| "  #{kind}: #{names.sort.join(", ")}" if names.any? }
      end

      # Neither task that needs the committed dump can take one itself, so both
      # say which task can — the same sentence SchemaLoader gives on refresh.
      def self.no_dump
        "no schema dump at #{GraphWeaver.schema_path} — take one: " \
          "rake graph_weaver:schema:refresh URL=https://api.example.com/graphql"
      end

      # What the schema tasks work on, one entry per graph: the dump
      # generation reads and the source behind it.
      #
      # One rule — the dump is the contract generation reads; `refresh`
      # rewrites it from the graph's source, `diff` says how far that source
      # has drifted from it, whichever the source is. A graph whose schema IS
      # a live class reads no dump at all, so it has neither.
      def self.dumps = GraphWeaver.graphs.map { |graph| [graph, graph.dump_path, graph.dump_source] }

      # A graph that generates straight from a schema class has no dump
      # between the code and the output — so there is nothing here to
      # refresh or compare, and nothing that can be stale.
      def self.no_dump_needed(graph, source)
        whose = heading(graph) || "this app"
        # a dump this graph names and hasn't written yet — refresh writes it
        # from the url its modules post to, so there is one task to name
        if (missing = graph.named_dump_path)
          return "#{whose}: no schema dump at #{missing} yet — take one: " \
            "rake graph_weaver:schema:refresh"
        end
        return "#{whose}: #{no_dump}" unless source

        "#{whose} generates from #{source_name(source)} directly — no dump to keep in step"
      end

      # How a dump's source reads in a report: a url as itself, a schema
      # class by name.
      def self.source_name(source) = source.is_a?(Module) ? GraphWeaver::SchemaLoader.endpoint(source) : source
    end
  end
end

namespace :graph_weaver do
  # In Rails, boot the app first — initializers register scalars/enums/
  # helpers and they're baked into generated source. Rails defines
  # :environment *after* every railtie's rake_tasks block (see
  # Rails::Application#run_tasks_blocks), so whether it exists can only be
  # asked when the task runs, not when this file loads.
  task :environment do
    # These tasks read queries, the schema and the registrations, not a
    # generated module. Saying so lets the railtie skip loading them, so a
    # stale generated file can't block the task that repairs it. It's reset
    # below, so cassettes:check — which does read them — loads them itself.
    GraphWeaver.skip_generated_load = true
    Rake::Task["environment"].invoke if Rake::Task.task_defined?("environment")
  ensure
    # only meaningful while booting — leaving it set would silently disable
    # loading for anything that boots later in the same process
    GraphWeaver.skip_generated_load = false
  end

  # the default, not GraphWeaver.queries_paths: a desc is baked when this file
  # loads, which in Rails is before :environment has run an initializer that
  # moves it — interpolating would print the default as though it were the setting
  desc "Generate typed query modules (default app/graphql/queries -> app/graphql/generated)"
  task generate: :environment do
    # every graph's output, not just the default one's: this is the "pruned"
    # report, and a file deleted in one graph is as much a diff as in another
    globs = GraphWeaver.graphs.map { |graph| File.join(GraphWeaver::Internal::Util.resolve(graph.output), "**/*.rb") }
    before = globs.flat_map { |glob| Dir[glob] }

    # schema auto-located at GraphWeaver.schema_path, any supported extension
    written = GraphWeaver.generate!
    changed = GraphWeaver.changed_files
    changed.each { |path| puts "wrote #{path}" }
    puts "#{written.size - changed.size} already up to date" if changed.size < written.size
    # generated files are checked in, so a delete this task made is a diff the
    # user is about to find; a run that printed nothing at all had done both
    (before - globs.flat_map { |glob| Dir[glob] }).each do |path|
      puts "pruned #{GraphWeaver::Internal::Util.relative(path)}"
    end
    puts GraphWeaver::Internal::Tasks.no_queries if written.empty?
    GraphWeaver::Internal::Tasks.report_registry
  rescue GraphWeaver::Error => e
    # a typo'd query is a user error — the message names file, position and
    # fix, and a rake backtrace through codegen only buries it
    abort e.message
  end

  # `rake -T` can't name them: a desc is baked when this file loads, and in
  # Rails that is before :environment, so before the initializer that declares
  # them has run. This is the task that can.
  desc "List the configured graphs and where each one generates"
  task graphs: :environment do
    GraphWeaver.graphs.each do |graph|
      name = graph.name ? graph.name.inspect : "(the default graph — GraphWeaver's own settings)"
      puts "#{name}  #{Array(graph.queries).join(", ")} -> #{GraphWeaver::Internal::Util.relative(graph.output)}"
      puts "  namespace: #{graph.namespace}" if graph.namespace
      # which server a graph's modules call — the one thing this task couldn't
      # say. A graph that bakes none falls back to GraphWeaver.client, which is
      # an app-wide setting and not this task's subject.
      puts "  client: #{graph.client}" if graph.client
      # a registration is scoped to one graph, and nothing else says which
      GraphWeaver::Internal::Tasks.registrations(graph).each { |line| puts line }
    end
  end

  desc "Verify generated query modules are up to date"
  task verify: :environment do
    GraphWeaver.verify_generated!
    puts "generated queries up to date"
    GraphWeaver::Internal::Tasks.report_registry
  rescue GraphWeaver::Error => e
    abort e.message
  end

  # The over-fetch nothing else here can see. verify says the Ruby matches the
  # query; this asks whether the query still asks for what the app uses — the
  # drift that happens on the app's side, silently, when a template stops
  # reading a field. Nothing is edited, and the default exit is 0: a finding is
  # a prompt to look.
  desc "Report selections whose generated props no code reads (PATHS= to scope, STRICT=1 to fail)"
  task unused: :environment do
    require "graph_weaver/internal/unused"

    # an app with no queries has nothing to over-fetch: sweeping it to report
    # 0 of 0 and advise `rake graph_weaver:generate` answers a question nobody
    # asked, where its sibling says the one true thing in one line
    next puts GraphWeaver::Internal::Tasks.no_queries unless GraphWeaver::Internal::Tasks.queries?

    # like cassettes:check, this reads generated modules — they are what says
    # which props a query produced
    GraphWeaver.load_generated!
    unused = GraphWeaver::Internal::Unused.new(paths: ENV["PATHS"]&.split(","))
    puts unused.report

    # abort writes to unbuffered stderr; the report above went to
    # block-buffered stdout, so a piped CI log shows it first
    $stdout.flush
    count = unused.findings.size
    if count.positive? && GraphWeaver::Internal::Tasks.flag?("STRICT")
      abort "#{count} #{(count == 1) ? "selection" : "selections"} nothing reads — drop " \
        "#{(count == 1) ? "it" : "them"} from the query and regenerate (rake graph_weaver:generate)"
    end
  rescue GraphWeaver::Error => e
    abort e.message
  end

  namespace :schema do
    # One rule, per graph: the dump is the contract generation reads;
    # :refresh rewrites it from the graph's source and :diff says how far
    # that source has drifted from it — whichever the source is. A url is
    # re-introspected (GRAPHWEAVER_AUTH supplies a token for private APIs);
    # a graphql-ruby schema class this process runs answers introspection
    # itself, so an app that serves its own schema needs no network.

    desc "Fail when the schema behind the dump has drifted from it"
    task diff: :environment do
      subjects = GraphWeaver::Internal::Tasks.dumps
      abort GraphWeaver::Internal::Tasks.no_dump if subjects.none? { |_, path, _| path }

      stale = subjects.filter_map do |graph, path, source|
        heading = GraphWeaver::Internal::Tasks.heading(graph)
        puts heading if heading
        # a graph that names a live class generates straight from it: no
        # dump between the code and the output, so nothing can be stale
        next puts GraphWeaver::Internal::Tasks.no_dump_needed(graph, source) unless path

        # a schema class answers introspection itself; left nil, diff builds
        # the dump's own transport, auth and all
        diff = GraphWeaver::SchemaLoader.diff(path, transport: (source if source.is_a?(Module)))
        dump = GraphWeaver::Internal::Util.relative(path)
        next puts "#{dump} matches #{GraphWeaver::Internal::Tasks.source_name(source)}" if diff.empty?

        puts diff.report
        dump
      end

      # abort writes to unbuffered stderr; the summaries above went to
      # block-buffered stdout, so a piped CI log shows them first
      $stdout.flush
      unless stale.empty?
        abort "#{stale.join(", ")} is stale — the schema behind it has drifted " \
          "(rake graph_weaver:schema:refresh)"
      end
    rescue GraphWeaver::Error => e
      # e.g. a dump that is its own source — same clean exit as :refresh
      abort e.message
    end

    desc "Rewrite the local dump from the schema behind it (URL= to bootstrap the first one)"
    task refresh: :environment do
      # anything else in URL= reaches introspection as a schema *source*, and
      # fails talking about file extensions rather than the flag just typed
      if ENV["URL"] && !ENV["URL"].match?(GraphWeaver::Client::URL)
        abort "URL= takes an endpoint: rake graph_weaver:schema:refresh URL=https://api.example.com/graphql"
      end

      # URL= names one endpoint, so it bootstraps the conventional dump —
      # before any graph has a dump to read a source off
      if ENV["URL"]
        path, source = GraphWeaver::SchemaLoader.refresh!(url: ENV["URL"])
        next puts "refreshed #{GraphWeaver::Internal::Util.relative(path)} from #{source}"
      end

      GraphWeaver::Internal::Tasks.dumps.each do |graph, path, source|
        heading = GraphWeaver::Internal::Tasks.heading(graph)
        puts heading if heading
        # a graph that names a live class generates straight from it — no
        # dump to write. One that names a dump it hasn't got yet has one, and
        # its source is the url its modules already post to: that bootstraps a
        # second graph's dump, which URL= can't, naming one endpoint for an
        # app with one per graph. The default graph names neither, so it lands
        # below and refresh! bootstraps its first dump (or says how).
        path ||= graph.named_dump_path
        next puts GraphWeaver::Internal::Tasks.no_dump_needed(graph, source) if !path && graph.named_schema?

        written, from = GraphWeaver::SchemaLoader.refresh!(url: (source unless source.is_a?(Module)),
          schema: (source if source.is_a?(Module)), path:)
        puts "refreshed #{GraphWeaver::Internal::Util.relative(written)} from #{from}"
      end
    rescue GraphWeaver::Error => e
      abort e.message
    end
  end

  namespace :queries do
    desc "Report checked-in queries that no longer validate against the server's schema"
    task check: :environment do
      failures = GraphWeaver.check_queries
      failures.each do |path, errors|
        puts path
        errors.each do |error|
          position = [error["line"], error["column"]].compact.join(":")
          puts "  #{position.empty? ? "" : "#{position}  "}#{error["message"]}"
        end
        puts
      end

      # abort writes to unbuffered stderr; the detail above went to
      # block-buffered stdout, so a piped CI log shows the verdict first
      $stdout.flush
      abort "#{failures.size} invalid #{(failures.size == 1) ? "query" : "queries"}" if failures.any?
      puts "every query validates against the schema"
    end
  end

  namespace :federation do
    # Every task here answers "which loaded schema serves which subgraph",
    # and Rails leaves config.rake_eager_load false in every environment —
    # so without this each of them reports on zero subgraphs, and :diff
    # exits 0 having compared nothing. Asked when the task runs, not when
    # this file loads: :environment doesn't exist yet at load time.
    task loaded: :environment do
      Rails.application.eager_load! if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
    end

    # needs no network, so it gates a PR the way verify does
    desc "Fail when a subgraph here changed and the supergraph wasn't recomposed (SUPERGRAPH= overrides)"
    task diff: :loaded do
      require "graph_weaver/federation"

      # every graph's supergraph is its own gate: one that drifted fails the
      # run whatever its neighbours say, and so does one that checked nothing
      checked = GraphWeaver::Internal::Tasks.supergraphs!("diff").map do |graph, supergraph|
        heading = GraphWeaver::Internal::Tasks.heading(graph)
        puts heading if heading
        drift = GraphWeaver::Federation::Drift.new(supergraph:)
        puts drift.report
        puts if heading
        [graph, drift]
      end

      # A partly-local supergraph is a supported setup, so a subgraph this
      # process doesn't serve isn't a failure — but comparing against NONE
      # of them is: the gate passes whatever the subgraphs say, which is
      # worse than failing.
      $stdout.flush
      # not .any? — the default graph is nil in this slot, and [nil].any? is false
      stale = checked.select { |_, drift| drift.drift? }.map(&:first)
      unless stale.empty?
        abort "#{GraphWeaver::Internal::Tasks.whose(stale)}the supergraph is out of date — " \
          "recompose it and commit the result"
      end
      vacuous = checked.select { |_, drift| drift.vacuous? }.map(&:first)
      unless vacuous.empty?
        abort "#{GraphWeaver::Internal::Tasks.whose(vacuous)}this checked nothing, so it proved " \
          "nothing. No schema in this process defines what the supergraph says any of its " \
          "subgraphs resolves — load them (in Rails, that is config.eager_load / " \
          "config.rake_eager_load), or, if they all run elsewhere, drop this task from CI: there " \
          "is nothing here for it to gate."
      end
      GraphWeaver::Internal::Tasks.warn_unplaced(checked.map(&:last))
    rescue GraphWeaver::Error => e
      abort e.message
    end

    desc "Show which loaded schema serves each subgraph, as a paste-ready map (SUPERGRAPH= overrides)"
    task subgraphs: :loaded do
      require "graph_weaver/testing"

      GraphWeaver::Internal::Tasks.supergraphs!("subgraphs").each do |graph, supergraph|
        heading = GraphWeaver::Internal::Tasks.heading(graph)
        puts heading if heading

        # Testing::Router derives this map itself; this is for reading what
        # detection sees when it refuses, and for committing the map instead.
        table = GraphWeaver::SchemaLoader.routing_table(supergraph)
        rows = table.subgraphs.map do |name|
          found = GraphWeaver::Internal::Subgraphs.candidates(table, name)
          sought = GraphWeaver::Internal::Subgraphs.expected(table, name)
          [name, found, sought]
        end
        width = rows.map { |name, found, _| %("#{name}" => #{found.first&.name || "nil"},).length }.max

        puts "subgraphs: {"
        rows.each do |name, found, sought|
          entry = %(  "#{name}" => #{found.one? ? found.first.name : "nil"},).ljust(width + 2)
          # fields first: every schema has a Query, so only the fields say why
          evidence = (sought.grep(/\./) | sought).first(3).join(", ")
          note = if found.one?
            "# matched: defines #{evidence}"
          elsif found.any?
            "# AMBIGUOUS: #{found.map(&:name).sort.join(", ")} all match — pick one"
          else
            "# no loaded schema defines #{evidence} — fill this in"
          end
          puts "#{entry}  #{note}"
        end
        puts "}"
        puts if heading
      end
    rescue GraphWeaver::Error => e
      abort e.message
    end

    desc "Report how many queries the local test router can plan (SUPERGRAPH=/QUERIES= override)"
    task coverage: :loaded do
      require "graph_weaver/testing"

      GraphWeaver::Internal::Tasks.supergraphs!("coverage").each do |graph, supergraph|
        heading = GraphWeaver::Internal::Tasks.heading(graph)
        puts heading if heading
        # the graph's own queries, not the top-level setting: a graph that
        # names its own supergraph names its own queries too, and measuring
        # the neighbour's against this one reports a coverage nobody has
        puts GraphWeaver::Testing::Coverage.new(
          supergraph:,
          queries: ENV["QUERIES"] || (graph ? graph.queries : GraphWeaver.queries_paths),
        ).report
        puts if heading
      end
    rescue GraphWeaver::Error => e
      # a supergraph the routing table can't read fully is itself the answer:
      # nothing is plannable, and the message says which construct
      abort e.message
    end
  end

  namespace :cassettes do
    # The drift the other checks structurally can't see. verify, queries:check
    # and schema:diff all ask about the local side; a cassette is the one
    # artifact recorded from someone else's server, and when that server's
    # answers stop fitting the generated structs the failure surfaces mid-spec
    # as a cast error naming a struct and a sorbet frame — nothing points at
    # the stale file.
    desc "Fail when a recorded response no longer casts into the generated structs"
    task check: :environment do
      require "graph_weaver/testing"

      # unlike its siblings this task reads generated modules — they are what
      # a recording is checked against
      GraphWeaver.load_generated!
      # asked of each graph, not of the top-level settings: a graph's queries
      # are its own and its constants live under its namespace, so a top-level
      # lookup finds nothing in a namespaced app and then refuses for having
      # checked nothing
      modules = GraphWeaver.graphs.flat_map do |graph|
        GraphWeaver::Internal::Util.query_files(graph.queries).filter_map do |path|
          name = graph.generated_names(path, File.read(path)).first
          Object.const_get(name) if Object.const_defined?(name)
        end
      end.uniq

      # Testing.cassette_dir, not config.cassette_dir: the configured path is
      # relative by default and rake runs from wherever it runs from
      dir = GraphWeaver::Testing.cassette_dir
      shown = GraphWeaver::Internal::Util.relative(dir)
      checks = Dir[File.join(dir, "*.yml")].sort.map do |path|
        GraphWeaver::Testing::Cassette.new(path).check(modules)
      end
      checks.each { |check| puts check.report }

      stale = checks.sum { |check| check.stale.size }
      $stdout.flush
      if stale.positive?
        # the structs move when a REGISTRATION moves, not only when the dump
        # does — and re-recording a fresh response doesn't fix that half
        abort "#{stale} stale #{(stale == 1) ? "recording" : "recordings"} — the recorded server's " \
          "answers no longer fit the structs generated from your schema. Regenerate if the schema " \
          "dump or a registration moved (rake graph_weaver:generate), or re-record if the server's " \
          "answer did (GRAPHWEAVER_RECORD=1, with a live client:)."
      end
      if checks.sum(&:checked).zero?
        # a green run that compared nothing is worse than a failure: it would
        # pass whatever the recordings said (see federation:diff)
        abort "this checked nothing, so it proved nothing: no recording in #{shown} carries a query " \
          "any of the #{modules.size} generated modules sends. Drop this task from CI if you " \
          "don't record cassettes, or check that #{shown} is where yours live."
      end

      puts "every recording still casts"
    end

    desc "Anonymize every cassette in Testing.config.cassette_dir (PII-safe to commit)"
    task anonymize: :environment do
      require "graph_weaver/testing"

      # locate, not schema_path: the dump is whichever supported extension is
      # actually on disk, and every sibling task asks the same way
      schema = GraphWeaver::SchemaLoader.locate or abort GraphWeaver::Internal::Tasks.no_dump
      dir = GraphWeaver::Testing.cassette_dir
      paths = Dir[File.join(dir, "*.yml")].sort
      paths.each do |path|
        GraphWeaver::Testing::Cassette.new(path).anonymize!(schema:)
        puts "anonymized #{GraphWeaver::Internal::Util.relative(path)}"
      end
      # silence and exit 0 read as "done" — say where we looked, the way every
      # sibling task does
      puts "no recordings in #{GraphWeaver::Internal::Util.relative(dir)}" if paths.empty?
    end
  end
end
