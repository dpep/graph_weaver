# typed: ignore — stubs Rails/Rake constants sorbet can't resolve
require "rake"
require "tmpdir"


describe "GraphWeaver::Railtie" do
  # a minimal Rails::Railtie stand-in capturing the registration blocks
  def load_railtie(tasks, initializers)
    railtie_base = Class.new do
      define_singleton_method(:rake_tasks) { |&block| tasks << block }
      define_singleton_method(:initializer) { |_name, **, &block| initializers << block }
    end
    stub_const("Rails", Module.new)
    Rails.const_set(:Railtie, railtie_base)

    load File.expand_path("../lib/graph_weaver/railtie.rb", __dir__)
  ensure
    GraphWeaver.send(:remove_const, :Railtie) if GraphWeaver.const_defined?(:Railtie, false)
  end

  it "registers the rake tasks with Rails when present" do
    tasks = []
    load_railtie(tasks, [])

    expect(tasks.size).to eq 1
    tasks.first.call
    expect(Rake::Task.task_defined?("graph_weaver:generate")).to be true
    expect(Rake::Task.task_defined?("graph_weaver:schema:verify")).to be true
  end

  it "loads generated modules at boot when the directory exists" do
    initializers = []
    load_railtie([], initializers)
    expect(initializers.size).to eq 1

    Dir.mktmpdir do |dir|
      GraphWeaver.generated_path = dir
      File.write(File.join(dir, "boot_probe_query.rb"), "module RailtieBootProbe; end")

      initializers.first.call

      expect(defined?(RailtieBootProbe)).to be_truthy
    ensure
      GraphWeaver.generated_path = nil
      Object.send(:remove_const, :RailtieBootProbe) if Object.const_defined?(:RailtieBootProbe)
    end
  end

  it "boots quietly when there is nothing generated" do
    initializers = []
    load_railtie([], initializers)

    GraphWeaver.generated_path = "no/such/dir"
    expect { initializers.first.call }.not_to raise_error
  ensure
    GraphWeaver.generated_path = nil
  end
end
