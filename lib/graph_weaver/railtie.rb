# typed: ignore — Rails::Railtie DSL
# frozen_string_literal: true

# Rails wiring, so the conventional layout needs no ceremony:
#
# - rake tasks: Rails.application.load_tasks collects every Railtie's
#   rake_tasks block, so graph_weaver:* tasks appear with no Rakefile
#   edit. (Outside Rails there is no task-discovery hook — add
#   `require "graph_weaver/tasks"` to your Rakefile.)
# - generated modules: required at boot when generated_path exists,
#   after config/initializers (registrations and GraphWeaver.client=
#   run first — block-built type helpers must exist before the files
#   that include them load). load_generated! stays idempotent, so
#   calling it yourself too is harmless.
# - Zeitwerk: the generated directory is hidden from it, since the
#   default one lives under app/ and its files define top-level
#   constants.
class GraphWeaver::Railtie < Rails::Railtie
  rake_tasks do
    require "graph_weaver/tasks"
  end

  # generated/person_query.rb defines ::PersonQuery, but Zeitwerk infers
  # Generated::PersonQuery from the path — and app/graphql/generated is
  # inside an autoload root by default, so eager loading raised
  # "uninitialized constant Generated::PersonQuery" in production while
  # development (lazy) was fine. load_generated! below requires them.
  initializer "graph_weaver.ignore_generated", before: :setup_main_autoloader do
    Rails.autoloaders.each do |loader|
      # patterns, not paths — generated_paths may be globs, and Zeitwerk
      # expands its own at setup (which is what this runs before)
      GraphWeaver.generated_paths.each { |path| loader.ignore(Rails.root.join(path).to_s) }
    end
  end

  # Rails.logger, unless the app already chose one (set
  # GraphWeaver.logger = nil in an initializer to silence)
  initializer "graph_weaver.logger" do
    GraphWeaver.logger = Rails.logger if GraphWeaver.logger.nil?
  end

  initializer "graph_weaver.load_generated", after: :load_config_initializers do
    # The graph_weaver tasks write these files and need none of them loaded.
    # Loading them would let a stale one block its own repair: a dropped
    # extend_type leaves a dangling include, and generate depends on
    # :environment, so boot failed before the task that would regenerate it.
    next if GraphWeaver.skip_generated_load

    # entries may be globs, so Dir[] rather than Dir.exist?
    GraphWeaver.load_generated! if GraphWeaver.generated_paths.any? { |path| Dir[path].any? }
  end
end
