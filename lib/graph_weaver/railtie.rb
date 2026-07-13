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
class GraphWeaver::Railtie < Rails::Railtie
  rake_tasks do
    require "graph_weaver/tasks"
  end

  # Rails.logger, unless the app already chose one (set
  # GraphWeaver.logger = nil in an initializer to silence)
  initializer "graph_weaver.logger" do
    GraphWeaver.logger = Rails.logger if GraphWeaver.logger.nil?
  end

  initializer "graph_weaver.load_generated", after: :load_config_initializers do
    GraphWeaver.load_generated! if Dir.exist?(GraphWeaver.generated_path)
  end
end
