# typed: ignore — Rails::Generators DSL, only loaded by `rails g`
# frozen_string_literal: true

require "graph_weaver"

# rails g graph_weaver:install --url=https://api.example.com/graphql
#
# Scaffolds the conventional layout — initializer, query/generated
# directories, editor config — and bootstraps the schema dump, so the
# setup in docs/getting_started.md is one command.
#
# It reads nothing from the app: at install time the initializer doesn't
# exist yet, so the endpoint arrives as a flag.
module GraphWeaver
  module Generators
    class InstallGenerator < Rails::Generators::Base
      desc "Wire up GraphWeaver: initializer, app/graphql layout, editor config, schema dump"

      class_option :url, type: :string, required: true,
        desc: "GraphQL endpoint, e.g. https://api.example.com/graphql"
      class_option :auth, type: :string, default: "GRAPHWEAVER_AUTH",
        desc: "name of the ENV var holding the auth token"
      class_option :schema, type: :boolean, default: true,
        desc: "introspect the endpoint and write the schema dump"

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

      def fetch_schema
        return unless options[:schema]

        path, url = GraphWeaver::SchemaLoader.refresh!(url: options[:url], auth: ENV[options[:auth]])
        say_status :introspect, "#{path} from #{url}"
      rescue StandardError => e
        # the files above are the valuable part — don't lose them to a bad
        # token or an unreachable host
        say_status :failed, "#{e.message} — retry with `rake graph_weaver:schema:refresh`", :red
      end

      def next_steps
        say <<~TEXT

          Write a query in #{GraphWeaver.queries_path}, then:

              rake graph_weaver:generate

          Docs: https://github.com/dpep/graph_weaver/blob/main/docs/getting_started.md
        TEXT
      end

      private

      def initializer
        <<~RUBY
          # frozen_string_literal: true

          GraphWeaver.client = GraphWeaver.new(
            "#{options[:url]}",
            auth: ENV["#{options[:auth]}"],
            cache: true, # reuse the committed dump; delete it to re-introspect
          )

          # Custom scalars, enums and type mixins go here — `rake graph_weaver:generate`
          # bakes them into the generated source, so they must be registered first:
          #
          #   GraphWeaver.register_scalar("DateTime", Time, serialize: :iso8601, requires: "time")
          #   GraphWeaver.extend_type("Person", Greetable)
        RUBY
      end

      # fragments are in documents: too — without them an editor reports
      # `Unknown fragment` on any query that spreads a shared one
      def editor_config
        <<~YAML
          # Autocomplete and validation for .graphql files in VS Code / RubyMine.
          # https://github.com/dpep/graph_weaver/blob/main/docs/editors.md
          schema: #{GraphWeaver.schema_path}
          documents:
            - #{GraphWeaver.queries_path}/**/*.graphql
            - #{GraphWeaver.fragments_path}/**/*.graphql
        YAML
      end
    end
  end
end
