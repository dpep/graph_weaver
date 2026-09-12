# typed: ignore — exercises eval-defined constants
require "bigdecimal"

# The block a graph is declared with. Everything a graph knows is said inside
# it, in call style, and the block runs where it is written.
describe "GraphWeaver.graph block" do
  after do
    GraphWeaver.reset_graphs!
    GraphWeaver::Codegen.reset_registrations!
  end

  def declared(name = :billing, &block) = GraphWeaver.graph(name, &block)

  it "sets each setting by calling it" do
    graph = declared do
      schema "billing.graphql"
      queries "app/graphql/billing"
      output "app/graphql/generated/billing"
      client "Billing::CLIENT"
      namespace "Billing"
      types_module "Billing::Types"
    end

    expect(graph.name).to eq :billing
    expect(graph.named_schema?).to be true
    expect(graph.queries).to eq "app/graphql/billing"
    expect(graph.output).to eq "app/graphql/generated/billing"
    expect(graph.client).to eq "Billing::CLIENT"
    expect(graph.namespace).to eq "Billing"
    expect(graph.types_module).to eq "Billing::Types"
  end

  # the reason there is no `schema = x` form: instance_eval makes that a local
  # variable, so a setter that reads like one would silently do nothing
  it "reads the current value back from a bare call" do
    seen = []
    declared do
      seen << schema
      schema Demo::Schema
      seen << schema
    end

    expect(seen).to eq [nil, Demo::Schema]
  end

  # a setting the graph doesn't say falls back to the top-level one
  it "leaves a setting it never says to the top level" do
    graph = declared { schema Demo::Schema }

    expect(graph.queries).to eq GraphWeaver.queries_paths
    expect(graph.output).to eq GraphWeaver.generated_paths.first
    expect(graph.namespace).to be_nil
    expect(graph.types_module).to eq GraphWeaver.types_module
  end

  it "refuses a call it doesn't take, naming what it does" do
    expect { declared { schmea "billing.graphql" } }
      .to raise_error(ArgumentError,
        /schmea.*did you mean.*schema.*queries, output, client, namespace, types_module, register_scalar, register_enum, extend_type/m)
  end

  it "refuses keywords, naming the block form" do
    expect { GraphWeaver.graph(:billing, schema: "billing.graphql") }
      .to raise_error(ArgumentError, /takes a block, not keywords.*GraphWeaver\.graph :billing do/m)
  end

  it "refuses a declaration with no block" do
    expect { GraphWeaver.graph(:billing) }.to raise_error(ArgumentError, /needs a block/)
  end

  it "refuses a name that isn't a Symbol or a String" do
    expect { GraphWeaver.graph(Demo::Schema) { schema Demo::Schema } }
      .to raise_error(ArgumentError, /Symbol or a String/)
  end

  # client, namespace and types_module are all spelled in generated source, so
  # the constant itself says what its name says
  it "takes a constant where a constant's name goes" do
    graph = declared do
      schema Demo::Schema
      client Demo::Schema
      namespace Demo
      types_module Demo::Schema
    end

    expect(graph.client).to eq "Demo::Schema"
    expect(graph.namespace).to eq "Demo"
    expect(graph.types_module).to eq "Demo::Schema"
  end

  it "refuses an anonymous module, naming the setting" do
    expect { declared { namespace Module.new } }
      .to raise_error(ArgumentError, /namespace needs a constant/)
  end

  # a live client can't be written into a generated file; the constant holding
  # it can, and that refusal already says so
  it "still refuses a live client object" do
    graph = declared do
      schema Demo::Schema
      client GraphWeaver::InProcess.new(Demo::Schema)
    end

    expect { GraphWeaver::Codegen.new(schema: Demo::Schema, query: "{ __typename }", client: graph.client) }
      .to raise_error(ArgumentError, /named constant or String/)
  end

  # the block runs where it is written, so a registration that can't work says
  # so at the declaration rather than at the next generation
  it "runs its registrations at declaration" do
    expect { declared { register_enum "Species", "PetKind" } }
      .to raise_error(ArgumentError, /not its name/)
  end

  # what a Rails initializer gets for `register_enum "Status", AccountStatus`:
  # Ruby raises before the registration is even called, so only the block can
  # say why — and the answer is the one a top-level registration already has
  it "points a constant that hasn't autoloaded yet at to_prepare" do
    expect { declared { register_enum "Status", NotAutoloadedYet } }
      .to raise_error(NameError, /uninitialized constant NotAutoloadedYet.*to_prepare.*:billing/m)
  end

  it "keeps its registrations to itself, on top of the top-level ones" do
    GraphWeaver.register_scalar("Money", BigDecimal, requires: "bigdecimal")
    graph = declared { register_scalar "Doubloon", String }

    expect(graph.registry.scalar_registry).to include("Money", "Doubloon")
    expect(GraphWeaver::Codegen.scalar_registry).not_to have_key("Doubloon")
  end
end
