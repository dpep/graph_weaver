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
      # call that names none of them. Caught where the sink line carries the
      # module's own name, or a local a line above assigned from it.
      SINKS = /\b(?:to_h|to_json|as_json|serialize|deconstruct_keys)\b|render\s+json:/
      # `result = PersonQuery.execute!(...)` — the name a response lands in.
      # Following one is what lets the sink be on the NEXT line, which is how
      # anyone actually writes a controller. The `@` is part of the capture:
      # it is what says the name outlives the method. Excludes == and =~.
      ASSIGN = /(@?\b[a-z_]\w*)\s*=[^=~]/
      # Where a plain local stops standing for the module it was assigned
      # from: the next method is a new scope, and a block param there that
      # happens to share the name holds someone else's value. An ivar crosses
      # it — `before_action` loading `@result` for the action to render is
      # the shape every Rails controller has.
      SCOPE = /^[ \t]*def\s/
      # A graphql-ruby TYPE class NAMES every field the server offers, as
      # `field :sku` and as a resolver method — which is the server answering,
      # not this app reading a prop back. Without this an app that serves the
      # graph it consumes (graphql_in_process) marks every prop read, and the
      # task reports nothing however much it over-fetches.
      #
      # Type kinds only: GraphQL::Schema::Resolver and ::Mutation hold
      # application logic — in a BFF that is exactly where an upstream graph
      # gets read — and skipping those files lost every read in them. Both
      # spellings, because graphql-ruby's own generator emits the app-owned
      # base class (`< Types::BaseObject`), not the gem's.
      TYPE_KINDS = "Object|Interface|Union|Enum|Scalar|InputObject"
      SCHEMA = /^[ \t]*(?:class \w+ < (?:GraphQL::Schema::|Types::Base)(?:#{TYPE_KINDS})\b|include GraphQL::Schema::Interface\b)/
      # What the sweep can read. A prop read from anywhere else — a .vue, a
      # .json.erb's sibling JS — is a blind spot, and the footer says so.
      # .rake and .builder are Ruby too.
      EXTENSIONS = %w[.rb .rake .builder .erb .slim .haml .jbuilder].freeze
      # Ruby that carries no extension to recognise it by. In a non-Rails
      # project the entry points live here, so skipping them skipped the
      # files that read the query.
      SCRIPT_DIRS = Set["bin", "exe"].freeze
      RUBY_SHEBANG = /\A#!.*\bruby\b/
      # Directories that hold no app source. "generated" covers both a graph's
      # own output under the convention and a spec/generated fixture dir; a
      # graph that writes somewhere else is pruned by #outputs.
      SKIP = Set["vendor", "node_modules", "tmp", "log", "generated"].freeze
      # enough of the quoted line to judge it by, without wrapping a terminal
      SNIPPET = 100

      # Measured against real corpora (actionview, activesupport, graphql and
      # six Rails gems swept together): half to two thirds of genuinely unread
      # selections go unreported, rising with corpus size. Saying so is the
      # difference between a lint and a number somebody trusts.
      FOOTER = "This is a lint, not a proof — it matches prop names as text, so a common name reads " \
        "as\nused the moment anything says it. It can't see a prop reached by public_send, or a " \
        "read\nin a file type it doesn't sweep — #{EXTENSIONS.join(", ")},\nplus Ruby with no " \
        "extension (any name under bin/ or exe/, a ruby shebang elsewhere). On\na real app half to " \
        "two thirds of genuinely unread selections go unreported; silence is\nthe safe direction."

      # query: the .graphql that selected it. struct/prop: where it landed.
      # wire: how the query spells that prop, when it differs.
      Selection = Struct.new(:query, :module_name, :struct, :prop, :wire) do
        # The GraphQL-side name, which is what you go and delete: the struct's
        # own name is the response key, so `Person.birthday` reads the way the
        # query does — and a camelCase field, an alias or a reserved rename
        # reads the way the query spells it, not the way the prop does.
        def coordinate = "#{struct.name.split("::").last}.#{wire || prop}"

        # …and the Ruby side, so the report is greppable both ways.
        def constant = "#{struct.name}##{prop}"
      end

      # Why a module's props were all counted read, and on what evidence. Via
      # is the local the value was standing in when it reached the serializer,
      # nil when the sink line named the module itself.
      Excuse = Struct.new(:path, :number, :source, :via) do
        def reason
          where = "handed whole to a serializer at #{path}:#{number}"
          via ? "#{where}, as `#{via}`" : where
        end
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
        # A root that isn't there sweeps nothing, and sweeping nothing reports
        # every prop unread — under STRICT, a red build demanding you delete
        # fields you use. `0 files swept` was the only tell, printed beneath
        # the accusations.
        missing = @roots.reject { |root| Dir.exist?(root) }
        return if missing.empty?

        raise GraphWeaver::Error,
          "no directory at #{missing.map { |root| Util.relative(root) }.join(", ")} — " \
          "PATHS= names directories under #{GraphWeaver.root}"
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
        lines = wholly_used.flat_map do |name, excuse|
          ["#{name}: every prop counted as read — #{excuse.reason}", "  #{excuse.source[0, SNIPPET]}"]
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
        "#{selections.size} selections, #{findings.size} unread — " \
          "#{count(selections.map(&:query).uniq.size, "query", "queries")}, " \
          "#{count(swept, "file", "files")} swept under #{where}"
      end

      def count(number, one, many) = "#{number} #{(number == 1) ? one : many}"

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

            # ONE line has to carry the module — itself, or a local a line
            # above assigned from it. Anywhere-in-the-file was the first cut
            # and it suppressed this gem's whole report: a doc comment naming
            # PersonQuery three hundred lines above an unrelated to_h counted
            # as serializing it. Following the local is what the line rule
            # missed, and it is the shape every Rails controller has:
            # `result = Q.execute!(...)`, then `render json: result.person`.
            locals = Hash.new { |hash, key| hash[key] = [] }
            body.each_line.with_index(1) do |line, number|
              locals.each_value { |names| names.select! { |n| n.start_with?("@") } } if SCOPE.match?(line)
              candidates.each do |name, base|
                locals[name] << Regexp.last_match(1) if line.include?(base) && ASSIGN.match(line)
              end
              next unless SINKS.match?(line)

              candidates.each do |name, base|
                # the line naming the module is the better evidence; the local
                # is what it falls back to
                via = locals[name].find { |local| line.match?(/(?<![\w@])#{Regexp.escape(local)}\b/) } \
                  unless line.include?(base)
                next unless via || line.include?(base)

                whole[name] ||= Excuse.new(Util.relative(path), number, line.strip, via)
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
            source = File.read(path)
            name = graph.generated_names(path, source).first
            next [] unless Object.const_defined?(name)

            result = Object.const_get(name)
            next [] unless result.const_defined?(:Result, false)

            keys = response_keys(GraphQL.parse(source).definitions)
            props(result.const_get(:Result, false))
              .map { |struct, prop| Selection.new(path, name, struct, prop, wire_word(keys, prop)) }
          end
        end
      end

      # How the query spells a prop, when that isn't the prop's own name — a
      # camelCase field, an alias, a reserved rename. Read back off the query
      # rather than derived from the prop, since no rule inverts an alias; nil
      # when the query spells it the same way, which is most of the time.
      def wire_word(keys, prop)
        keys.find { |key| key != prop.to_s && GraphWeaver::Codegen.prop_name(key) == prop.to_s }
      end

      # Every response key the document asks for. The coordinate is the
      # selection to go and delete, so it can only be one of these: scanning
      # the file's text let `$id: ID!` — or a comment — name a field the query
      # never selected.
      def response_keys(nodes, found = [])
        nodes.each do |node|
          found << (node.alias || node.name) if node.is_a?(GraphQL::Language::Nodes::Field)
          response_keys(node.selections, found) if node.respond_to?(:selections)
        end
        found
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
        @files ||= @roots
          .flat_map { |root| collect(root, [], SCRIPT_DIRS.include?(File.basename(root))) }
          .uniq.sort
      end

      # Pruned as it walks rather than globbed and filtered: node_modules is
      # the directory you most want never to descend into. scripts says we are
      # inside bin/ or exe/, which the walk knows and a path doesn't.
      def collect(dir, found, scripts)
        Dir.children(dir).sort.each do |entry|
          path = File.join(dir, entry)
          # lstat, so a symlinked directory can't loop the walk
          stat = File.lstat(path)
          if stat.directory?
            collect(path, found, scripts || SCRIPT_DIRS.include?(entry)) unless skip_dir?(entry, path)
          elsif stat.file? && ruby?(path, entry, scripts)
            found << path
          end
        end
        found
      rescue SystemCallError
        found
      end

      # An extension names most of it. A file with none is Ruby if it sits
      # under bin/ or exe/ — that is what those directories are for — or if
      # its first line says so.
      def ruby?(path, entry, scripts)
        return true if EXTENSIONS.include?(File.extname(entry))
        return false unless File.extname(entry).empty?

        scripts || shebang?(path)
      end

      def shebang?(path)
        File.open(path) { |file| file.gets(chomp: true) }&.match?(RUBY_SHEBANG) || false
      rescue SystemCallError, ArgumentError
        false
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
