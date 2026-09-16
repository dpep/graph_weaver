# typed: ignore — writes and reads generated trees
# frozen_string_literal: true

require "tmpdir"

# A block-form extend_type mints its mixin at registration, so no source file
# declares it — and a generated `# typed: strict` file `include`s it by name.
# The app's `srb tc` then failed on every such include ("Unable to resolve
# constant GraphWeaver::TypeHelpers::Pet"), because the constant exists nowhere
# statically. One rule: generation declares every constant it includes.
#
# The declaration goes in an .rbi, which Ruby never loads — so a dropped
# registration keeps failing loudly at require (see load_generated!'s "nothing
# registers it") instead of silently handing the struct an empty module.
RSpec.describe "the .rbi declaring block-built type helpers" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      FileUtils.mkdir_p(queries)
      File.write(File.join(queries, "pet_shout.graphql"), "query { person(id: 1) { pets { name } } }")
      example.run
    end
  end

  after do
    GraphWeaver.reset_graphs!
    GraphWeaver::Codegen.reset_registrations!
  end

  def queries = File.join(@dir, "queries")
  def output = File.join(@dir, "generated")
  def rbi = File.join(output, "type_helpers.rbi")

  def generate!
    GraphWeaver.generate!(schema: Demo::Schema, queries:, output:)
  end

  it "declares the module the block minted, so the include resolves" do
    GraphWeaver.extend_type("Pet") { def shout = "#{name}!" }
    generate!

    expect(File.read(File.join(output, "pet_shout_query.rb")))
      .to include("include GraphWeaver::TypeHelpers::Pet")
    expect(File.read(rbi)).to include("module GraphWeaver::TypeHelpers::Pet; end")
  end

  # a graph's helpers hang off a module named for the graph, and `module A::B`
  # doesn't define A — so each outer segment is opened first
  it "opens a graph's namespace before the helper under it" do
    from, to = queries, output
    GraphWeaver.graph(:billing) do
      schema Demo::Schema
      queries from
      output to
      extend_type("Pet") { def shout = "#{name}!" }
    end
    GraphWeaver.generate!

    expect(File.read(rbi).lines.map(&:chomp)).to include(
      "module GraphWeaver::TypeHelpers; end",
      "module GraphWeaver::TypeHelpers::Billing; end",
      "module GraphWeaver::TypeHelpers::Billing::Pet; end",
    )
  end

  # the whole point: an app's typecheck can resolve what generation wrote
  it "is the only thing standing between the include and srb tc" do
    GraphWeaver.extend_type("Pet") { def shout = "#{name}!" }
    generate!
    declared = File.read(rbi).scan(/^module (\S+); end$/).flatten

    expect(declared).to include("GraphWeaver::TypeHelpers::Pet")
    expect(File.read(rbi)).to start_with("# typed: strict\n")
  end

  # a named module has its own source file, which srb tc already reads
  it "says nothing for a mixin the app declares itself" do
    GraphWeaver.extend_type("Pet", AbstractMixin::PetFields)
    generate!

    expect(File.exist?(rbi)).to be false
  end

  it "writes no .rbi when no block helper is registered" do
    generate!

    expect(Dir[File.join(output, "*.rbi")]).to be_empty
  end

  # Ruby never loads an .rbi, so the include is still the only thing that
  # resolves the constant at runtime — which is what keeps a dropped
  # registration loud rather than silently method-less
  it "leaves a dropped registration failing loudly at load" do
    GraphWeaver.extend_type("Pet") { def shout = "#{name}!" }
    generate!
    GraphWeaver::Codegen.reset_type_helpers!
    GraphWeaver::TypeHelpers.send(:remove_const, :Pet)

    expect { GraphWeaver.load_generated!(output) }
      .to raise_error(GraphWeaver::Error, /includes GraphWeaver::TypeHelpers::Pet, but nothing registers it/)
  end

  # pruning promises to leave nothing behind, and a stale declaration would
  # keep srb tc green over an include that is gone
  it "is pruned when the last block helper goes" do
    GraphWeaver.extend_type("Pet") { def shout = "#{name}!" }
    generate!
    expect(File.exist?(rbi)).to be true

    GraphWeaver::Codegen.reset_type_helpers!
    generate!

    expect(File.exist?(rbi)).to be false
  end

  it "counts a stale declaration as stale for verify_generated!" do
    GraphWeaver.extend_type("Pet") { def shout = "#{name}!" }
    generate!
    GraphWeaver::Codegen.reset_type_helpers!

    expect { GraphWeaver.verify_generated!(schema: Demo::Schema, queries:, output:) }
      .to raise_error(GraphWeaver::Error, /stale.*type_helpers\.rbi/m)
  end
end
