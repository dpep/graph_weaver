# typed: ignore — stubs Rails/Rake constants sorbet can't resolve
require "rake"


describe "GraphWeaver::Railtie" do
  it "registers the rake tasks with Rails when present" do
    captured = []
    railtie_base = Class.new do
      define_singleton_method(:rake_tasks) { |&block| captured << block }
    end
    stub_const("Rails", Module.new)
    Rails.const_set(:Railtie, railtie_base)

    load File.expand_path("../lib/graph_weaver/railtie.rb", __dir__)

    expect(captured.size).to eq 1
    captured.first.call
    expect(Rake::Task.task_defined?("graph_weaver:generate")).to be true
    expect(Rake::Task.task_defined?("graph_weaver:schema:verify")).to be true
  ensure
    GraphWeaver.send(:remove_const, :Railtie) if GraphWeaver.const_defined?(:Railtie, false)
  end
end
