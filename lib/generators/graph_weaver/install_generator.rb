# typed: ignore — Rails::Generators DSL, only loaded by `rails g`
# frozen_string_literal: true

require "graph_weaver"

# rails g graph_weaver:install https://api.example.com/graphql
# rails g graph_weaver:install MyApp::Schema
# rails g graph_weaver:install db/schema.graphql
#
# Scaffolds the conventional layout — initializer, query/generated
# directories, editor config — and bootstraps the schema dump, so the
# setup in docs/getting_started.md is one command.
#
# The argument is what you'd pass to GraphWeaver.new, and the same three
# source forms are accepted; the initializer it writes reflects the one
# you chose. The source arrives on the command line rather than being read
# from config: at install time the initializer doesn't exist yet.
module GraphWeaver
  module Generators
    class InstallGenerator < Rails::Generators::Base
      desc <<~TEXT
        Wire up GraphWeaver: initializer, app/graphql layout, editor config, schema dump.

        SOURCE is what you'd pass to GraphWeaver.new:

            rails g graph_weaver:install https://api.example.com/graphql   # an endpoint
            rails g graph_weaver:install MyApp::Schema                     # a graphql-ruby schema, in-process
            rails g graph_weaver:install db/schema.graphql                 # a schema dump you already have
      TEXT

      argument :source, type: :string, banner: "SOURCE",
        desc: "what you'd pass to GraphWeaver.new: an endpoint url, a graphql-ruby schema class, or a schema dump path"

      # the default is SchemaLoader's, not one restated here — an --auth the
      # generator omits from the dump is one the schema tasks then can't find
      class_option :auth, type: :string,
        desc: "name of the ENV var holding the auth token (url only) — " \
          "default #{GraphWeaver::SchemaLoader::DEFAULT_AUTH_ENV}"
      class_option :schema, type: :boolean, default: true,
        desc: "write the schema dump codegen reads"

      # Before anything is written: a mistyped source or a flag that doesn't
      # apply to it is a mistake in the command just typed, so say so there
      # rather than at boot, three files later.
      def check_source
        if options[:auth] && form != :url
          raise Thor::Error, "--auth applies to a url — #{source} is a #{form == :schema_class ? "schema class" : "schema dump"}"
        end

        schema_class if form == :schema_class
      end

      # Every write goes through create_file, so a re-run prompts with a
      # diff rather than overwriting an initializer you've edited.
      def create_initializer
        create_file "config/initializers/graph_weaver.rb", initializer
      end

      # fragments too: the editor config below globs it, and a shared fragment
      # then has an obvious home rather than being invented later
      def create_layout
        create_file File.join(GraphWeaver.queries_paths.first, ".keep"), ""
        create_file File.join(GraphWeaver.fragments_paths.first, ".keep"), ""
        create_file File.join(GraphWeaver.generated_paths.first, ".keep"), ""
      end

      # editor autocomplete + validation for .graphql files (docs/editors.md)
      def create_editor_config
        create_file "graphql.config.yml", editor_config
      end

      # Generated files are machine-written and say "do not edit", but plain
      # `rubocop` still fires Style/Documentation, Style/ClassAndModuleChildren
      # and Metrics/* on every one of them. Only an app that already lints is
      # touched: writing a .rubocop.yml would turn rubocop on for a project
      # that never asked for it.
      def exclude_generated_from_rubocop
        return unless File.exist?(rubocop_config)

        body = File.read(rubocop_config)
        # already excluded — a re-run, or done by hand
        globs = generated_globs.reject { |glob| body.include?(glob) }
        return if globs.empty?

        entries = globs.map { |glob| "    - #{glob.inspect}" }.join("\n")
        reason =
          if body.match?(/^AllCops:/)
            # rubocop takes the LAST of two duplicate keys, so appending a second
            # AllCops: would replace the app's own rather than add to it
            "sets AllCops already, and a second one would replace it rather than merge"
          elsif yaml_documents(body) > 1
            # rubocop reads only the first document, so the append lands where
            # nothing will ever read it
            "holds more than one YAML document, and rubocop reads only the first"
          end

        # Name the lines instead of guessing where inside theirs they belong.
        if reason
          say <<~TEXT

            #{RUBOCOP_CONFIG} #{reason} — so add this under AllCops/Exclude:

            #{entries}
          TEXT
        else
          # inherit_mode is what makes this an addition: rubocop REPLACES an
          # Exclude array on merge, so without it the block below wipes the
          # effective list — rubocop's own vendor/node_modules/tmp defaults
          # included, along with any Exclude reaching here through inherit_from.
          append_to_file RUBOCOP_CONFIG, <<~YAML + entries + "\n"

            # Machine-written by `rake graph_weaver:generate` — not yours to style.
            AllCops:
              inherit_mode:
                merge:
                  - Exclude
              Exclude:
          YAML
        end
      end

      # The `graphql:` tags need this require, and it has to be somewhere
      # rspec actually loads. A spec/support file is not: rspec-rails ships
      # the spec/support glob commented out, so the require sat there doing
      # nothing and a tagged example silently ran against the real client.
      def wire_rspec
        helper = RSPEC_HELPERS.find { |path| File.exist?(File.join(GraphWeaver.root, path)) }

        unless helper
          say "\nTesting: add `#{RSPEC_REQUIRE}` to your spec helper for the " \
            "`graphql:` tags (docs/testing.md)."
          return
        end

        body = File.read(File.join(GraphWeaver.root, helper))
        return if body.match?(REQUIRED_ALREADY) # a re-run, or done by hand

        # after rspec-rails' own require where there is one, at the end
        # otherwise — either way top-level in a file every spec loads
        if (anchor = body[RSPEC_RAILS_REQUIRE])
          insert_into_file helper, "#{RSPEC_REQUIRE}\n", after: anchor
        else
          append_to_file helper, "\n#{RSPEC_REQUIRE}\n"
        end
      end

      # A url is introspected and a schema class dumped; a dump the app
      # already has is left where it is (schema_path points at it instead).
      def fetch_schema
        return unless options[:schema] && form != :path
        return if keep_existing_dump

        if form == :url
          # pass the var name, not just the token — it lands in the dump's
          # provenance so schema:refresh/:diff read the same one the
          # initializer does, instead of defaulting to GRAPHWEAVER_AUTH
          GraphWeaver::SchemaLoader.refresh!(url: source, auth_env: auth_var)
        else
          # a schema class is its own introspection source; ttl: 0 so an
          # existing dump never counts as fresh
          GraphWeaver::SchemaLoader.introspect(schema_class, cache: schema_path, ttl: 0)
        end
        say_status :introspect, "#{schema_path} from #{source}"
      rescue StandardError => e
        # the files above are the valuable part — don't lose them to a bad
        # token or an unreachable host
        @schema_failed = true
        say_status :failed, "#{e.message} — retry with `#{refresh_command}`", :red
      end

      def next_steps
        # generation reads the dump, so without one the step below can't run —
        # say that next to it rather than leaving the red line above to be
        # scrolled past. A re-run that already has a dump is not blocked.
        if @schema_failed && !GraphWeaver::SchemaLoader.locate_path
          say "\nThere's no schema dump yet, so `rake graph_weaver:generate` has nothing to read."
        end

        say <<~TEXT

          Write a query in #{GraphWeaver.queries_paths.first}, then:

              rake graph_weaver:generate

          Docs: https://github.com/dpep/graph_weaver/blob/main/docs/getting_started.md
        TEXT

        say federated_steps if subgraphs
      end

      private

      RUBOCOP_CONFIG = ".rubocop.yml"

      # rails_helper first: rspec-rails writes both, and only rails_helper
      # has Rails booted by the time the require runs.
      RSPEC_HELPERS = ["spec/rails_helper.rb", "spec/spec_helper.rb"].freeze
      RSPEC_REQUIRE = 'require "graph_weaver/rspec"'
      # the newline is part of the anchor: Thor inserts directly after the
      # match, so without it the require lands on the end of that line
      RSPEC_RAILS_REQUIRE = %r{^require ["']rspec/rails["'].*\n}
      REQUIRED_ALREADY = %r{^\s*require ["']graph_weaver/rspec["']}

      def rubocop_config = File.join(GraphWeaver.root, RUBOCOP_CONFIG)

      # Parsed, not counted: a `---` can also be a line inside a block scalar.
      # A file rubocop itself can't read is left to rubocop to complain about.
      def yaml_documents(body)
        YAML.parse_stream(body).children.size
      rescue Psych::SyntaxError
        1
      end

      # Every graph's output directory, so a multi-schema app is covered by
      # the same run — read off the graphs rather than restated here.
      def generated_globs
        GraphWeaver.graphs.map { |graph| File.join(graph.output, "**/*") }.uniq
      end

      # This install run is the one moment the user is guaranteed to be
      # reading, and a composed supergraph changes what the next steps are:
      # the test client is the interesting one, and there's a CI gate to add.
      def federated_steps
        <<~TEXT

          #{source} is a composed supergraph (#{subgraphs.size} subgraphs: #{subgraphs.join(", ")}), so:

              rake graph_weaver:federation:diff       # CI gate: a subgraph changed, nobody recomposed
              rake graph_weaver:federation:subgraphs  # which schema here serves which subgraph

          and specs run against your real resolvers across all of them, in-process:

              describe "checkout", graphql: :router do ... end   # require "graph_weaver/rspec"

          Docs: https://github.com/dpep/graph_weaver/blob/main/docs/federation.md
        TEXT
      end

      # The subgraph names this source composes, or nil when it isn't a
      # composed supergraph. Read off the routing table rather than guessed —
      # the same reader Testing::Router and federation:diff use.
      def subgraphs
        return @subgraphs if defined?(@subgraphs)

        @subgraphs =
          begin
            (GraphWeaver::SchemaLoader.routing_table(source).subgraphs if form == :path)
          rescue StandardError
            # not a supergraph, or not readable — nothing to say either way
            nil
          end
      end

      # Which of GraphWeaver.new's source forms this is. Neither test is its
      # own — a url is whatever the client calls one, a constant path whatever
      # codegen will spell — so the generator can't disagree with either about
      # what it just wrote an initializer for. Anything that is neither is
      # taken as a path to a dump.
      def form
        @form ||=
          if source.match?(GraphWeaver::Client::URL)
            :url
          elsif source.match?(GraphWeaver::Codegen::CONSTANT_NAME)
            :schema_class
          else
            :path
          end
      end

      # The named schema class, resolved now: `rails g` boots the app, so a
      # typo is catchable here rather than as a NameError at the next boot.
      def schema_class
        @schema_class ||= begin
          klass = Object.const_get(source)
          unless klass.respond_to?(:execute)
            raise Thor::Error, "#{source} isn't a graphql-ruby schema (no .execute) — pass the class that inherits GraphQL::Schema"
          end

          klass
        rescue NameError
          raise Thor::Error, "uninitialized constant #{source} — pass your graphql-ruby schema class " \
            "(rails g graphql:install writes app/graphql/<app>_schema.rb), an endpoint url, or a path to a schema dump"
        end
      end

      # A dump the app already has stays where it is; every other form
      # writes the conventional one.
      def schema_path = (form == :path) ? source : GraphWeaver.schema_path

      def auth_var = options[:auth] || GraphWeaver::SchemaLoader::DEFAULT_AUTH_ENV

      # The dump is the one file the generator doesn't write through
      # create_file, so Thor can't prompt on it — declining every conflict on
      # a re-run still replaced it, and with it the source url it records.
      # It is never overwritten here: `schema:refresh` is the command for
      # that, and it re-fetches in place without touching anything else.
      # True when there is one, having said so.
      def keep_existing_dump
        path = GraphWeaver::SchemaLoader.locate_path or return false

        recorded = GraphWeaver::SchemaLoader.provenance(path)&.dig("url")
        # a re-run naming a different endpoint would otherwise be answered
        # silently by the dump the old one left
        from = " (introspected from #{recorded})" if recorded && recorded != source
        say_status :keep, "#{GraphWeaver::Internal::Util.relative(path)}#{from} — " \
          "delete it and re-run to re-introspect", :yellow
        true
      end

      # --auth is what says this API takes a token. Without it the line is
      # shown rather than wired: a public API's initializer shouldn't read an
      # ENV var nobody set, and the commented line is how you add one later.
      def auth_setting
        return %(auth: ENV["#{auth_var}"],) if options[:auth]

        %(# auth: ENV["#{auth_var}"],  # uncomment when the API needs a token)
      end

      # The command just typed, retyped. One rule for every source form, and
      # the only one that always works: the files already written come back
      # "identical", and --auth rides along — where schema:refresh has no flag
      # for it, and with no dump written has no url to read either.
      def refresh_command
        "rails g graph_weaver:install #{source}#{" --auth #{options[:auth]}" if options[:auth]}"
      end

      def initializer
        <<~RUBY
          # frozen_string_literal: true

          #{client_setup}
          # Custom scalars, enums and type mixins go here — `rake graph_weaver:generate`
          # bakes them into the generated source, so they must be registered first:
          #
          #   GraphWeaver.register_scalar("Money", BigDecimal)
          #   GraphWeaver.extend_type("Person", Greetable)
        RUBY
      end

      # The load-bearing lines, per source form: what generated modules
      # resolve to at execute time, and where codegen reads the schema.
      def client_setup
        case form
        when :url
          <<~RUBY
            GraphWeaver.client = GraphWeaver.new(
              "#{source}",
              #{auth_setting}
              cache: true, # reuse the committed dump; delete it to re-introspect
            )
          RUBY
        when :schema_class
          # to_prepare, not a bare assignment: the schema class is autoloaded,
          # so it isn't resolvable this early, and a dev reload replaces it
          # with a new class object the client would otherwise still hold.
          <<~RUBY
            Rails.application.config.to_prepare do
              # queries run in-process against the app's own schema — no socket
              GraphWeaver.client = GraphWeaver.new(#{source})
            end
          RUBY
        when :path
          if subgraphs
            <<~RUBY
              GraphWeaver.schema_path = "#{source}"

              # A composed supergraph: your queries are generated against the whole
              # graph, and a router serves it. Point the app default at the gateway:
              #
              #   GraphWeaver.client = GraphWeaver.new("https://gateway.example.com/graphql")
              #
              # Specs don't need one — `graphql: :router` plans against this
              # supergraph and runs your own subgraph resolvers in-process
              # (docs/federation.md).
            RUBY
          else
            <<~RUBY
              GraphWeaver.schema_path = "#{source}"

              # A dump is type information only — it has no resolvers, so it can't
              # execute. Point the app default at whatever serves this API:
              #
              #   GraphWeaver.client = GraphWeaver.new("https://api.example.com/graphql")
            RUBY
          end
        end
      end

      # fragments are in documents: too — without them an editor reports
      # `Unknown fragment` on any query that spreads a shared one. The glob is
      # codegen's, so the editor validates exactly the files codegen reads.
      def editor_config
        <<~YAML
          # Autocomplete and validation for .graphql files in VS Code / RubyMine.
          # https://github.com/dpep/graph_weaver/blob/main/docs/editors.md
          schema: #{schema_path}
          documents:
            - #{File.join(GraphWeaver.queries_paths.first, GraphWeaver::Codegen::DOCUMENT_GLOB)}
            - #{File.join(GraphWeaver.fragments_paths.first, GraphWeaver::Codegen::DOCUMENT_GLOB)}
        YAML
      end
    end
  end
end
