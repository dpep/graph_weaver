# typed: ignore — the federation fixture schemas are graphql-ruby DSL
require "logger"
require "stringio"
require "tmpdir"

# filter_parameters keeps a password out of the debug log. An error message
# is the other way a value reaches a log — and Error#initialize puts every
# one of them at warn, above the debug gate.
describe "filtered messages" do
  let(:io) { StringIO.new }

  around do |example|
    GraphWeaver.logger = Logger.new(io, level: Logger::WARN)
    example.run
  ensure
    GraphWeaver.logger = nil
    GraphWeaver.filter_parameters = GraphWeaver::DEFAULT_FILTER_PARAMETERS
  end

  def parse(query, schema: Demo::Schema) = GraphWeaver.parse(schema:, query:)

  it "hides a filtered variable's value in the message and the warn line" do
    module_ = parse("query Login($password: Int) { search(term: \"x\", first: $password) { __typename } }")

    expect { module_.execute(password: "hunter2") }
      .to raise_error(GraphWeaver::InputError, /\$password of Login: \[FILTERED\]/)

    expect(io.string).to include("[FILTERED]")
    expect(io.string).not_to include("hunter2")
  end

  it "keeps an unfiltered variable's value, which is usually the diagnosis" do
    module_ = parse("query Counted($count: Int) { search(term: \"x\", first: $count) { __typename } }")

    expect { module_.execute(count: "lots") }
      .to raise_error(GraphWeaver::InputError, /\$count of Counted: expected an Int, got "lots"/)
    expect(io.string).to include('"lots"')
  end

  describe "input object fields" do
    it "hides a nested field's value under a filtered key" do
      schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
        input Credentials { user: String!, token: Int }
        input Wrapper { credentials: Credentials }
        type Query { login(with: Wrapper): Boolean }
        schema { query: Query }
      GRAPHQL
      module_ = parse("query In($with: Wrapper) { login(with: $with) }", schema:)

      expect { module_.execute(with: { credentials: { user: "d", token: "nope" } }) }
        .to raise_error(GraphWeaver::InputError, /token: \[FILTERED\]/)

      expect(io.string).not_to include("nope")
    end

    # a scalar registered to a Ruby class with no coercer reaches sorbet's own
    # prop check, whose message spells the value inside a sentence no filter
    # can see into — so the prop, not the sentence, has to carry the report
    it "hides a value only sorbet rejected, naming the prop" do
      GraphWeaver.register_scalar("Metadata", Hash)
      module_ = parse("query Pets($where: PetFilter) { findPets(where: $where) { name } }")

      expect { module_.execute(where: { metadata: "brown" }) }
        .to raise_error(GraphWeaver::InputError, /metadata: expected T::Hash.*, got "brown"/)

      GraphWeaver.filter_parameters = [:metadata]
      expect { module_.execute(where: { metadata: "brown" }) }
        .to raise_error(GraphWeaver::InputError, /metadata: expected T::Hash.*, got \[FILTERED\]/)
    ensure
      GraphWeaver.reset_registrations!
    end
  end

  it "hides a filtered @key value in a representation refusal" do
    GraphWeaver.filter_parameters = [:sku]
    sdl = FederationDemo::Catalog::Schema.execute("{ _service { sdl } }").to_h.dig("data", "_service", "sdl")
    source = GraphWeaver::Codegen.new(
      schema: GraphWeaver::SchemaLoader.load(sdl), client: "Fake", module_name: "SkuEntities",
      query: "query($reps: [_Any!]!) { _entities(representations: $reps) { ... on Product { upc } } }",
    ).generate
    reps = Module.new.tap { |m| m.module_eval(source, "(graph_weaver spec)", 1) }::SkuEntities::Representations

    expect { reps.product(upc: "u-1", sku: "forty-two") }
      .to raise_error(GraphWeaver::InputError, /Product representation sku: \[FILTERED\]/)
    expect(io.string).not_to include("forty-two")
  end

  # the transport and the in-process client both scrub what they log; the
  # router is the third thing that writes a variables= line
  it "hides a filtered variable in the router's debug line" do
    GraphWeaver.logger = Logger.new(io, level: Logger::DEBUG)
    router = GraphWeaver::Testing::Router.new(
      supergraph: RouterGraph::SUPERGRAPH, subgraphs: RouterGraph::SUBGRAPHS,
    )

    router.execute("query($password: Boolean!) { me { username @include(if: $password) } }",
      variables: { "password" => true })

    expect(io.string).to include("variables=")
    expect(io.string).to include("[FILTERED]")
    expect(io.string).not_to include('"password":true')
  end

  it "hides a filtered variable in a missing-cassette report" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "login.yml")
      query = "query Login($password: Int) { people { name } }"
      File.write(path, YAML.dump([
        { "query" => query, "variables" => { "password" => "0ldsecret" }, "response" => { "data" => {} } },
      ]))

      expect { GraphWeaver::Testing.cassette(path).execute(query, variables: { "password" => "hunter2" }) }
        .to raise_error(GraphWeaver::Testing::MissingRecording, /\[FILTERED\]/)

      expect(io.string).not_to include("hunter2")
      expect(io.string).not_to include("0ldsecret")
    end
  end
end
