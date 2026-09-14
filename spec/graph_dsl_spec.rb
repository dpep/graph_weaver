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
      client Demo::Schema
      namespace "Billing"
      types_module "Billing::Types"
    end

    expect(graph.name).to eq :billing
    expect(graph.named_schema?).to be true
    expect(graph.queries).to eq "app/graphql/billing"
    expect(graph.output).to eq "app/graphql/generated/billing"
    expect(graph.client).to eq Demo::Schema
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

  # namespace and types_module are spelled in generated source as a module
  # definition, so the constant itself says what its name says
  it "takes a constant where a constant's name goes" do
    graph = declared do
      schema Demo::Schema
      namespace Demo
      types_module Demo::Schema
    end

    expect(graph.namespace).to eq "Demo"
    expect(graph.types_module).to eq "Demo::Schema"
  end

  it "refuses an anonymous module, naming the setting" do
    expect { declared { namespace Module.new } }
      .to raise_error(ArgumentError, /namespace needs a constant/)
  end

  # nothing spells a client in generated source any more, so a live object is
  # as good a client as the constant holding one
  it "takes a live client object" do
    live = GraphWeaver::InProcess.new(Demo::Schema)
    graph = declared do
      schema Demo::Schema
      client live
    end

    expect(graph.client).to equal live
  end

  # a graph is declared in an initializer, where the constant holding the
  # client may not be defined yet — so a name is resolved when a module asks,
  # not when the block runs
  it "resolves a client named by a constant on first use, not at declaration" do
    graph = declared do
      schema Demo::Schema
      client "NotYetDefined::CLIENT"
    end

    expect { graph.client }.to raise_error(
      GraphWeaver::Error,
      /the client in graph :billing names "NotYetDefined::CLIENT" and nothing defines that constant/,
    )

    stub_const("NotYetDefined::CLIENT", Demo::Schema)
    expect(graph.client).to eq Demo::Schema
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

  # a leading :: is how you root-anchor a constant in Ruby, and it used to be
  # refused four steps later as a verdict on the .graphql file's name
  it "refuses a root-anchored namespace, naming the setting" do
    expect { declared { namespace "::Billing" } }.to raise_error(
      ArgumentError,
      'namespace "::Billing": drop the leading `::` — namespace names a module generated source ' \
      "defines, and it defines it at the top level either way",
    )
    expect { declared { types_module "::Billing::Types" } }
      .to raise_error(ArgumentError, /\Atypes_module "::Billing::Types": drop the leading `::`/)

    # client is a reference, not a definition, so ::Foo::CLIENT means what it says
    stub_const("Billing::CLIENT", Demo::Schema)
    expect(declared { client "::Billing::CLIENT" }.client).to eq Demo::Schema
  end

  # the lambda form is what a Rails initializer has to use, and a lambda
  # returns nil easily — a config value that wasn't set, a guarded `defined?`,
  # a safe_constantize. It used to reach codegen as nil.
  it "refuses a schema lambda that resolves to nil, naming the graph" do
    graph = declared { schema -> {} }

    [:schema, :dump_path, :supergraph, :live_schema].each do |reader|
      expect { graph.public_send(reader) }.to raise_error(
        GraphWeaver::Error,
        "schema in graph :billing resolved to nil — schema takes a graphql-ruby schema class, " \
        "a Client, a path to a dump, SDL, or a callable returning one",
      )
    end
  end

  # In Rails the graph and the scalars usually live in two initializers, and
  # initializers run in alphabetical filename order — so declaring a graph in
  # billing.rb and registering in graph_weaver.rb must generate the same code
  # as the other way round.
  it "reads the top-level registrations whenever they were made" do
    early = declared(:early) { schema Demo::Schema }
    GraphWeaver.register_scalar("Money", BigDecimal, requires: "bigdecimal")
    late = declared(:late) { schema Demo::Schema }

    expect(early.registry.scalar_registry).to have_key("Money")
    expect(early.registry.scalar_registry.keys).to eq late.registry.scalar_registry.keys
  end

  # the corollary: a top-level registration made later must not silently
  # replace what the block said about the same name
  it "keeps the block's own registration on top of a later top-level one" do
    graph = declared { register_scalar "Money", String }
    GraphWeaver.register_scalar("Money", BigDecimal, requires: "bigdecimal")

    expect(graph.registry.scalar("Money").type).to eq "String"
  end
end
