# typed: true
# frozen_string_literal: true

require "set"

require_relative "../internal"

module GraphWeaver
  module Internal
    # Which generated props no code in the app reads — the over-fetch that
    # collects when a template stops using a field and nobody edits the
    # .graphql. graphql-client catches it at runtime by masking the data it
    # didn't declare; the structs are checked in here, so it can be recovered
    # without running anything.
    #
    # Name-based on purpose. The generated structs say which props exist; one
    # sweep of the app's own source says which names it mentions. That makes
    # this a lint rather than a proof — #report says so in its own footer,
    # because a finding is a prompt to look, never a verdict.
    class Unused
      # Where a prop shows up when it is READ: a method call, a pattern-match
      # or hash key, a symbol, a string. A bare word in prose matches none of
      # them, which is what keeps comments and locals out.
      READ = /[.:"']([a-z_]\w*)|\b([a-z_]\w*):/
      # Hand a struct to one of these and every prop is read at once, by a
      # call that names none of them. Caught only where the module's own name
      # is on the same line — once the value is in a local it is out of reach,
      # which the footer says.
      SINKS = /\b(?:to_h|to_json|as_json|serialize|deconstruct_keys)\b|render\s+json:/
      # A graphql-ruby type class NAMES every field the server offers, as
      # `field :sku` and as a resolver method — which is the server answering,
      # not this app reading a prop back. Without this an app that serves the
      # graph it consumes (graphql_in_process) marks every prop read, and the
      # task reports nothing however much it over-fetches.
      SCHEMA = /^\s*(?:class \w+ < GraphQL::Schema::|include GraphQL::Schema::Interface\b)/
      # What the sweep can read. A prop read from anywhere else — a .vue, a
      # .json.erb's sibling JS — is a blind spot, and the footer says so.
      EXTENSIONS = %w[.rb .erb .slim .haml .jbuilder].freeze
      # Directories that hold no app source. "generated" covers both a graph's
      # own output under the convention and a spec/generated fixture dir; a
      # graph that writes somewhere else is pruned by #outputs.
      SKIP = Set["vendor", "node_modules", "tmp", "log", "generated"].freeze
      # enough of the quoted line to judge it by, without wrapping a terminal
      SNIPPET = 100

      FOOTER = "This is a lint, not a proof — it matches prop names as text, so a common name reads " \
        "as\nused the moment anything says it. It can't see a prop reached by public_send, a " \
        "struct\nthat reaches a serializer through a local variable, or a read in a file type it " \
        "doesn't\nsweep (#{EXTENSIONS.join(", ")})."

      # query: the .graphql that selected it. struct/prop: where it landed.
      Selection = Struct.new(:query, :module_name, :struct, :prop) do
        # The GraphQL-side name, which is what you go and delete: the struct's
        # own name is the response key, so `Person.birthday` reads the way the
        # query does.
        def coordinate = "#{struct.name.split("::").last}.#{prop}"

        # …and the Ruby side, so the report is greppable both ways.
        def constant = "#{struct.name}##{prop}"
      end

      # What one pass over the files answers.
      Sweep = Struct.new(:names, :wholly_used, :files)

      # paths: the directories to sweep, defaulting to the whole root. Narrowed
      # here rather than by the caller, so an empty PATHS= sweeps everything
      # instead of nothing — nothing would report every prop unread.
      def initialize(graphs: GraphWeaver.graphs, paths: nil)
        @graphs = graphs
        given = Array(paths).map { |path| path.to_s.strip }.reject(&:empty?)
        @roots = (given.empty? ? ["."] : given).map { |path| Util.resolve(path) }
      end

      # Every selection nothing reads, grouped the way the report prints them.
      def findings
        @findings ||= selections
          .reject { |selection| read?(selection) }
          .sort_by { |selection| [Util.relative(selection.query), selection.coordinate] }
      end

      def report
        # The evidence, not just the verdict: name-matching a serializer call
        # is the mushiest thing here, and a suppression that was wrong should
        # be obvious at a glance rather than silently eating the report.
        lines = wholly_used.flat_map do |name, (path, number, source)|
          ["#{name}: every prop counted as read — handed whole to a serializer at #{path}:#{number}",
            "  #{source[0, SNIPPET]}"]
        end
        lines += findings.map do |selection|
          "#{Util.relative(selection.query)}: #{selection.coordinate} — selected, never read " \
            "(#{selection.constant})"
        end
        # a run that checked nothing would report "0 unread" whatever the
        # queries said, which is worse than saying so
        lines << nothing_loaded if selections.empty?
        [*lines, "", summary, "", FOOTER].join("\n")
      end

      # What the summary counts, so the task can phrase its own STRICT abort.
      def summary
        queries = selections.map(&:query).uniq.size
        "#{selections.size} selections, #{findings.size} unread — " \
          "#{queries} #{(queries == 1) ? "query" : "queries"}, #{swept} files swept under #{where}"
      end

      private

      def read?(selection)
        wholly_used.key?(selection.module_name) || names.include?(selection.prop.to_s)
      end

      def names = sweep.names
      def wholly_used = sweep.wholly_used
      def swept = sweep.files

      # One pass over the files for all three answers — the names anything
      # reads, the modules something serializes whole, and how many files that
      # took. Per-prop searching is what makes a tool like this too slow to run.
      def sweep
        @sweep ||= begin
          read = Set.new
          whole = {}
          short = selections.to_h { |selection| [selection.module_name, selection.module_name.split("::").last] }
          files.each do |path|
            # scrub: a stray non-UTF-8 byte in a template is not a reason to
            # refuse to lint the other 500 files
            body = File.read(path).scrub
            next if SCHEMA.match?(body)

            body.scan(READ) { |method, key| read << (method || key) }
            next unless SINKS.match?(body)

            # Both substring checks before walking the lines: `to_h` is in
            # most files and a query module's name is in almost none, so this
            # is what keeps the line pass off the other 95%.
            candidates = short.reject { |name, base| whole.key?(name) || !body.include?(base) }
            next if candidates.empty?

            # ONE line has to carry both the module's name and the sink.
            # Anywhere-in-the-file was the first cut and it suppressed this
            # gem's whole report: a doc comment naming PersonQuery three
            # hundred lines above an unrelated to_h counted as serializing it.
            body.each_line.with_index(1) do |line, number|
              next unless SINKS.match?(line)

              candidates.each do |name, base|
                whole[name] ||= [Util.relative(path), number, line.strip] if line.include?(base)
              end
            end
          end
          Sweep.new(read, whole, files.size)
        end
      end

      # Every generated prop, per query file. Query-driven like everything
      # else: a struct exists because a query selected it.
      def selections
        @selections ||= @graphs.flat_map do |graph|
          Util.query_files(graph.queries).flat_map do |path|
            name = graph.generated_names(path, File.read(path)).first
            next [] unless Object.const_defined?(name)

            result = Object.const_get(name)
            next [] unless result.const_defined?(:Result, false)

            props(result.const_get(:Result, false)).map { |struct, prop| Selection.new(path, name, struct, prop) }
          end
        end
      end

      # Nested structs are nested constants, so the props of a whole response
      # are one walk down. Reported flat: a parent nothing reads makes its
      # children unread too, and saying both is the honest count.
      def props(struct, found = [])
        struct.props.each_key { |prop| found << [struct, prop] }
        struct.constants(false).each do |const|
          nested = struct.const_get(const, false)
          props(nested, found) if nested.is_a?(Class) && nested < T::Struct
        end
        found
      end

      def files
        @files ||= @roots.flat_map { |root| collect(root, []) }.uniq.sort
      end

      # Pruned as it walks rather than globbed and filtered: node_modules is
      # the directory you most want never to descend into.
      def collect(dir, found)
        Dir.children(dir).sort.each do |entry|
          path = File.join(dir, entry)
          # lstat, so a symlinked directory can't loop the walk
          stat = File.lstat(path)
          if stat.directory?
            collect(path, found) unless skip_dir?(entry, path)
          elsif stat.file? && EXTENSIONS.include?(File.extname(entry))
            found << path
          end
        end
        found
      rescue SystemCallError
        found
      end

      def skip_dir?(entry, path) = entry.start_with?(".") || SKIP.include?(entry) || outputs.include?(path)

      # The generated directories a name check can't catch: a graph that sets
      # `output` somewhere of its own.
      def outputs
        @outputs ||= (Util.generated_dirs + @graphs.map(&:output))
          .flat_map { |pattern| Dir.glob(Util.resolve(pattern), File::FNM_PATHNAME) }
          .to_set
      end

      def where
        @roots.map { |root| (root == GraphWeaver.root) ? "." : Util.relative(root) }.join(", ")
      end

      def nothing_loaded
        "nothing to check: no generated module is loaded for any query here (rake graph_weaver:generate)"
      end
    end
  end
end
