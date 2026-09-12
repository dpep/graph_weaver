# typed: ignore — the federation fixture schemas are graphql-ruby DSL
require "json"
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

  # the key a value arrives under is all a sentence-level filter can ask about,
  # so a filtered key one level inside the value used to be invisible to it —
  # the message quoted the raw hash while #value beside it read [FILTERED]
  it "hides a filtered key nested inside the value a message quotes" do
    module_ = parse("query Counted($count: Int) { search(term: \"x\", first: $count) { __typename } }")

    # Hash#inspect spells differently across Rubies; the quoted hash is whatever this one writes
    shown = Regexp.escape({ "token" => "[FILTERED]" }.inspect)
    expect { module_.execute(count: { "token" => "t0ps3cret" }) }
      .to raise_error(GraphWeaver::InputError, /\$count of Counted: expected an Int, got #{shown}/)

    expect(io.string).not_to include("t0ps3cret")
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

    # a filter matches the key the caller SUPPLIED, and a typo is by definition
    # not the key they meant — so the one error whose whole job is "you meant
    # a list element has no key of its own; the list's key is what the filter
    # matches, and the element learns it only as the path is built outward
    it "hides a refused element of a filtered list" do
      GraphWeaver.filter_parameters = ["token"]
      schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { revoke(tokens: [String!]!): Boolean }
        schema { query: Query }
      GRAPHQL
      module_ = parse("query Revoke($tokens: [String!]!) { revoke(tokens: $tokens) }", schema:)

      expect { module_.execute(tokens: ["ok", 5]) }
        .to raise_error(GraphWeaver::InputError) { |e|
          expect(e.path).to eq ["tokens", 1]
          expect(e.value).to eq "[FILTERED]"
          expect(e.message).not_to include "5"
        }
    end

    # this other key" is the one the filter cannot see
    it "hides a typo'd key's value, which no filter can match" do
      GraphWeaver.filter_parameters = ["token"]
      schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
        input Credentials { user: String!, token: String }
        type Query { login(with: Credentials): Boolean }
        schema { query: Query }
      GRAPHQL
      module_ = parse("query In($with: Credentials) { login(with: $with) }", schema:)

      expect { module_.execute(with: { user: "d", tokne: "t0ps3cret" }) }
        .to raise_error(GraphWeaver::InputError) { |e|
          expect(e.details[:suggestion]).to eq "token"
          expect(e.value).to be_nil
          expect(JSON.generate(e.to_h)).not_to include "t0ps3cret"
        }

      expect(io.string).not_to include("t0ps3cret")
    end
  end

  # graphql-ruby quotes the rejected value in its explanation as a matter of
  # course, so the server half leaks wherever the client half doesn't
  describe "a server's rejection" do
    def input_error(hash) = GraphWeaver::GraphQLError.from_h(hash).input_errors.first

    before { GraphWeaver.filter_parameters = ["password"] }

    it "hides it in a variable-coercion problem" do
      error = input_error(
        "message" => "Variable $creds of type Creds! was provided invalid value",
        "extensions" => {
          "value" => { "password" => "hunter2" },
          "problems" => [{ "path" => ["password"], "explanation" => 'Could not coerce value "hunter2" to Int' }],
        },
      )

      expect(error.message).to eq GraphWeaver::FILTERED
      expect(error.value).to eq GraphWeaver::FILTERED
    end

    it "hides it in a coded validation error" do
      error = input_error(
        "message" => 'Invalid input: password "hunter2" is too short',
        "extensions" => { "code" => "BAD_USER_INPUT", "argumentName" => "password", "value" => "hunter2" },
      )

      expect(error.message).to eq GraphWeaver::FILTERED
      expect(error.value).to eq GraphWeaver::FILTERED
    end

    it "hides it in the extensions.input convention" do
      error = input_error(
        "message" => 'password "hunter2" is not acceptable',
        "extensions" => { "input" => { "kind" => "invalid_format", "path" => ["password"], "value" => "hunter2" } },
      )

      expect(error.message).to eq GraphWeaver::FILTERED
      expect(error.value).to eq GraphWeaver::FILTERED
    end

    it "keeps an unfiltered server message, which is usually the diagnosis" do
      error = input_error(
        "message" => "Variable $qty of type Int! was provided invalid value",
        "extensions" => {
          "value" => "x",
          "problems" => [{ "path" => [], "explanation" => 'Could not coerce value "x" to Int' }],
        },
      )

      expect(error.message).to eq 'Could not coerce value "x" to Int'
    end
  end

  # #value is the second place the offending value appears — as data this
  # time, which no message filter would have seen — so the same list decides it
  it "hides a filtered value on InputError#value, at any depth" do
    module_ = parse("query Login($password: Int) { search(term: \"x\", first: $password) { __typename } }")

    expect { module_.execute(password: "hunter2") }
      .to raise_error(GraphWeaver::InputError) { |e| expect(e.value).to eq GraphWeaver::FILTERED }

    schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
      input Credentials { user: String!, token: Int }
      type Query { login(with: Credentials): Boolean }
      schema { query: Query }
    GRAPHQL
    nested = parse("query In($with: Credentials) { login(with: $with) }", schema:)

    expect { nested.execute(with: { user: "d", token: "t0ps3cret" }) }
      .to raise_error(GraphWeaver::InputError) { |e|
        expect(e.path).to eq %w[with token]
        expect(e.value).to eq GraphWeaver::FILTERED
      }
  end

  it "hides a filtered @key value in a representation refusal" do
    GraphWeaver.filter_parameters = [:sku]
    sdl = FederationDemo::Catalog::Schema.execute("{ _service { sdl } }").to_h.dig("data", "_service", "sdl")
    source = GraphWeaver::Codegen.new(
      schema: GraphWeaver::SchemaLoader.load(sdl), client: "Fake", name: "SkuEntities",
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
