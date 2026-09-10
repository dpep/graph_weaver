# typed: ignore — Rake DSL, and the tasks are loaded rather than required
# frozen_string_literal: true

require "rake"

# The gem's rake tasks, in an application of their own — the one every spec
# file that drives them shares.
#
# It has to be ONE load: `load "graph_weaver/tasks.rb"` per example resets
# Ruby's per-file coverage counters, leaving whichever example ran last as the
# only one measured. Five spec files each carried the same guarded copy of
# that load, racing to define a top-level TASKS.
module RakeHarness
  # Loaded on first ask, so a run that never touches rake never loads them.
  def self.application
    @application ||= begin
      app = Rake::Application.new
      previous = Rake.application
      begin
        Rake.application = app
        # require, not load: the railtie's own `require "graph_weaver/tasks"`
        # runs in a spec, and against a `load`ed file that is a second
        # definition of every task — each action then runs twice.
        require "graph_weaver/tasks"
      ensure
        Rake.application = previous
      end
      app
    end
  end
end
