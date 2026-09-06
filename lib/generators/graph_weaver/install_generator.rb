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

      class_option :auth, type: :string,
        desc: "name of the ENV var holding the auth token (url only) — default GRAPHWEAVER_AUTH"
      class_option :schema, type: :boolean, default: true,
        desc: "write the schema dump codegen reads"

      # a Ruby constant path names a schema class; anything that is neither
      # this nor a url is taken as a path to a dump
      CONSTANT = /\A[A-Z]\w*(::[A-Z]\w*)*\z/

      DEFAULT_AUTH = "GRAPHWEAVER_AUTH"

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

      def create_layout
        create_file File.join(GraphWeaver.queries_path, ".keep"), ""
        create_file File.join(GraphWeaver.generated_path, ".keep"), ""
      end

      # editor autocomplete + validation for .graphql files (docs/editors.md)
      def create_editor_config
        create_file "graphql.config.yml", editor_config
      end

      # A url is introspected and a schema class dumped; a dump the app
      # already has is left where it is (schema_path points at it instead).
      def fetch_schema
        return unless options[:schema] && form != :path

        if form == :url
          GraphWeaver::SchemaLoader.refresh!(url: source, auth: ENV[auth_var])
        else
          # a schema class is its own introspection source; ttl: 0 so an
          # existing dump never counts as fresh
          GraphWeaver::SchemaLoader.introspect(schema_class, cache: schema_path, ttl: 0)
        end
        say_status :introspect, "#{schema_path} from #{source}"
      rescue StandardError => e
        # the files above are the valuable part — don't lose them to a bad
        # token or an unreachable host
        say_status :failed, "#{e.message} — retry with `#{refresh_command}`", :red
      end

      def next_steps
        say <<~TEXT

          Write a query in #{GraphWeaver.queries_path}, then:

              rake graph_weaver:generate

          Docs: https://github.com/dpep/graph_weaver/blob/main/docs/getting_started.md
        TEXT
      end

      private

      # Which of GraphWeaver.new's source forms this is — the url test is
      # its own, so the generator and the client can't disagree about what
      # counts as one.
      def form
        @form ||= if source.match?(GraphWeaver::Client::URL) then :url
        elsif source.match?(CONSTANT) then :schema_class
        else :path
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

      def auth_var = options[:auth] || DEFAULT_AUTH

      def refresh_command
        (form == :url) ? "rake graph_weaver:schema:refresh" : "rails g graph_weaver:install #{source}"
      end

      def initializer
        <<~RUBY
          # frozen_string_literal: true

          #{client_setup}
          # Custom scalars, enums and type mixins go here — `rake graph_weaver:generate`
          # bakes them into the generated source, so they must be registered first:
          #
          #   GraphWeaver.register_scalar("DateTime", Time, serialize: :iso8601, requires: "time")
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
              auth: ENV["#{auth_var}"],
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

      # fragments are in documents: too — without them an editor reports
      # `Unknown fragment` on any query that spreads a shared one
      def editor_config
        <<~YAML
          # Autocomplete and validation for .graphql files in VS Code / RubyMine.
          # https://github.com/dpep/graph_weaver/blob/main/docs/editors.md
          schema: #{schema_path}
          documents:
            - #{GraphWeaver.queries_path}/**/*.graphql
            - #{GraphWeaver.fragments_path}/**/*.graphql
        YAML
      end
    end
  end
end
