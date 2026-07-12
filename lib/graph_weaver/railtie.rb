# typed: ignore — Rails::Railtie DSL
# frozen_string_literal: true

# Auto-register the rake tasks in Rails apps: Rails.application.load_tasks
# collects every Railtie's rake_tasks block, so graph_weaver:* tasks
# appear with no Rakefile edit. (Outside Rails there is no task-discovery
# hook — add `require "graph_weaver/tasks"` to your Rakefile.)
class GraphWeaver::Railtie < Rails::Railtie
  rake_tasks do
    require "graph_weaver/tasks"
  end
end
