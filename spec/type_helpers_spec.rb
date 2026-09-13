# typed: ignore — exercises block-built constants
require "bigdecimal"

# What a block-form extend_type mints, and what it is called. The name ends up
# in generated source, so it has to be a function of the source and nothing
# else: a graph's registrations are replayed on every read of its registry
# (see Graph#registry), and naming by "what constant already exists" made the
# name a function of how many times THIS process happened to read it — so
# `rake graph_weaver:generate` baked a name a plain boot never creates, and
# verify, reading the registry the same number of times, agreed with itself.
describe "a block-built type helper's name" do
  after do
    GraphWeaver.reset_graphs!
    GraphWeaver::Codegen.reset_registrations!
  end

  def helper_names(registry) = registry.type_registry.fetch("Pet")[:mixins].map(&:name)

  describe "in a graph block" do
    it "is the same module however often the registry is read" do
      graph = GraphWeaver.graph(:billing) { extend_type("Pet") { def shout = name.upcase } }

      reads = 3.times.map { graph.registry.type_registry.fetch("Pet")[:mixins] }
      expect(reads.map { |mixins| mixins.map(&:name) }.uniq)
        .to eq [["GraphWeaver::TypeHelpers::Billing::Pet"]]
      expect(reads.map(&:first).uniq.size).to eq 1
    end

    # the reload case: to_prepare re-runs the initializer, so the same source
    # declares the graph again in the same process and must mint the same name
    it "is the same across two declarations of the same source" do
      first = GraphWeaver.graph(:billing) { extend_type("Pet") { def shout = name.upcase } }
      again = GraphWeaver.graph(:billing) { extend_type("Pet") { def shout = name.upcase } }

      expect(helper_names(again.registry)).to eq helper_names(first.registry)
      expect(helper_names(again.registry)).to eq ["GraphWeaver::TypeHelpers::Billing::Pet"]
    end

    # two graphs extending the same type name share one TypeHelpers namespace
    it "tells two graphs' helpers for one type apart" do
      billing = GraphWeaver.graph(:billing) { extend_type("Pet") { def shout = name.upcase } }
      ledger = GraphWeaver.graph(:ledger) { extend_type("Pet") { def shout = name.downcase } }

      expect(helper_names(billing.registry)).to eq ["GraphWeaver::TypeHelpers::Billing::Pet"]
      expect(helper_names(ledger.registry)).to eq ["GraphWeaver::TypeHelpers::Ledger::Pet"]
    end

    it "stacks a second block on the same type under a fresh name" do
      graph = GraphWeaver.graph(:billing) do
        extend_type("Pet") { def shout = name.upcase }
        extend_type("Pet") { def whisper = name.downcase }
      end

      expect(helper_names(graph.registry)).to eq [
        "GraphWeaver::TypeHelpers::Billing::Pet",
        "GraphWeaver::TypeHelpers::Billing::PetV2",
      ]
    end
  end

  describe "at the top level" do
    it "is named for the type alone" do
      GraphWeaver.extend_type("Pet") { def shout = name.upcase }

      expect(helper_names(GraphWeaver::Codegen.registry)).to eq ["GraphWeaver::TypeHelpers::Pet"]
    end

    it "is the same after the registrations are reset and re-made" do
      GraphWeaver.extend_type("Pet") { def shout = name.upcase }
      GraphWeaver::Codegen.reset_registrations!
      GraphWeaver.extend_type("Pet") { def shout = name.upcase }

      expect(helper_names(GraphWeaver::Codegen.registry)).to eq ["GraphWeaver::TypeHelpers::Pet"]
    end
  end

  # the generated code has to name it, so it has to still be the graph's own
  it "reaches generated source under the name it was minted with" do
    GraphWeaver.graph(:billing) do
      schema Demo::Schema
      extend_type("Pet") { def shout = "#{name}!" }
    end
    graph = GraphWeaver.graphs.first
    code = GraphWeaver::Codegen.new(
      schema: Demo::Schema,
      query: "query { person(id: 1) { pets { name } } }",
      name: "PetQuery",
      registry: graph.registry,
    ).generate

    expect(code).to include("include GraphWeaver::TypeHelpers::Billing::Pet")
  end
end
