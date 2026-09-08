require "tmpdir"



# Both formats a remote service can hand you — introspection JSON or SDL —
# load into schemas that generate byte-identical output to the live class.
describe GraphWeaver::SchemaLoader do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  # loaded schemas must generate byte-identically to the live class —
  # verified against the checked-in fixtures (shared inputs included)
  def codegen_parity(schema)
    root = File.expand_path("..", __dir__)

    expect(
      GraphWeaver.verify_generated!(
        schema:,
        queries: File.join(root, "spec/queries"),
        output: File.join(root, "spec/generated"),
        client: "Demo::Schema",
      ),
    ).to be true
  end

  it "loads an introspection dump (.json)" do
    path = File.join(@dir, "schema.json")
    File.write(path, JSON.generate(Demo::Schema.as_json))

    codegen_parity(described_class.load(path))
  end

  it "loads SDL (.graphql)" do
    path = File.join(@dir, "schema.graphql")
    File.write(path, Demo::Schema.to_definition)

    codegen_parity(described_class.load(path))
  end

  it "loads raw content: introspection JSON, SDL strings, and Hashes" do
    codegen_parity(described_class.load(Demo::Schema.to_definition))
    codegen_parity(described_class.load(Demo::Schema.as_json))
  end

  it "loads single-line SDL — what you'd type in a console" do
    schema = described_class.load("type Query { hi: String }")
    expect(schema.get_type("Query").fields.keys).to eq %w[hi]
  end

  it "rejects other formats, under the Error umbrella" do
    expect { described_class.load("schema.yaml") }.to raise_error(GraphWeaver::Error, /unsupported/)
    expect { described_class.load("not a schema at all") }.to raise_error(GraphWeaver::Error, /unsupported/)
    expect { described_class.load("nope\nnot this either") }.to raise_error(GraphWeaver::Error, /unsupported/)
    expect { described_class.load("no/such/schema.graphql") }
      .to raise_error(GraphWeaver::Error, %r{can't read the schema at no/such/schema.graphql})
  end

  # A .json that isn't JSON is the corrupt-dump case — a truncated download,
  # an interrupted write, a login page saved over it. JSON::ParserError names
  # neither the file nor what it holds, and escapes the Error umbrella.
  it "names the file when a .json dump isn't JSON" do
    login = File.join(@dir, "schema.json")
    File.write(login, "<!DOCTYPE html>\n<html><body>Sign in</body></html>\n")
    expect { described_class.load(login) }
      .to raise_error(GraphWeaver::Error, /#{Regexp.escape(login)} isn't JSON.*Sign in|isn't JSON/m)

    truncated = File.join(@dir, "half.json")
    File.write(truncated, '{"data": {"__sch')
    expect { described_class.load(truncated) }
      .to raise_error(GraphWeaver::Error, /#{Regexp.escape(truncated)} isn't JSON/)

    File.write(File.join(@dir, "empty.json"), "")
    expect { described_class.load(File.join(@dir, "empty.json")) }
      .to raise_error(GraphWeaver::Error, /isn't JSON/)

    # the same content handed over directly, with no file to name
    expect { described_class.load('{"data": {"__sch') }
      .to raise_error(GraphWeaver::Error, /the schema content isn't JSON/)
  end

  # the near miss worth naming: the cause is the missing scheme, not the format
  it "points a bare host at the url it meant" do
    expect { described_class.load("graphql.anilist.co") }
      .to raise_error(GraphWeaver::Error, %r{did you mean "https://graphql.anilist.co"})

    # a file whose format we simply don't read isn't a host
    expect { described_class.load("schema.yaml") }.to raise_error(GraphWeaver::Error) do |e|
      expect(e.message).not_to include("host")
    end
  end

  # the path/content disambiguation the SDL sniffing must not break
  it "still reads a path that starts with an SDL keyword" do
    Dir.mkdir(File.join(@dir, "types"))
    path = File.join(@dir, "types", "schema.graphql")
    File.write(path, Demo::Schema.to_definition)

    Dir.chdir(@dir) { codegen_parity(described_class.load("types/schema.graphql")) }
  end

  # Rails.root.join(...) is how a Rails app spells a path
  it "loads a Pathname" do
    path = File.join(@dir, "schema.graphql")
    File.write(path, Demo::Schema.to_definition)

    codegen_parity(described_class.load(Pathname.new(path)))
    codegen_parity(GraphWeaver.new(Pathname.new(path)).schema)
  end

  describe ".locate" do
    it "loads the conventional dump in whatever format exists" do
      expect(described_class.locate(File.join(@dir, "schema.json"))).to be_nil

      File.write(File.join(@dir, "schema.graphql"), Demo::Schema.to_definition)
      codegen_parity(described_class.locate(File.join(@dir, "schema.json")))
    end
  end

  describe ".introspect" do
    # counts how many introspections actually hit the "network"
    let(:counting_executor) do
      Class.new do
        attr_reader :calls

        def initialize
          @calls = 0
        end

        def execute(query, variables:, operation_name: nil)
          @calls += 1
          Demo::Schema.execute(query, variables:, operation_name:)
        end
      end.new
    end

    it "fetches a schema through an executor" do
      # a schema class is itself an executor, so this exercises the same
      # path a live HTTP endpoint would
      codegen_parity(described_class.introspect(Demo::Schema))
    end

    it "round-trips schemas through their own to_json for external caches" do
      # the Rails.cache pattern: introspect(...).to_json, then load
      schema = described_class.introspect(Demo::Schema)

      codegen_parity(described_class.load(schema.to_json))
    end

    it "caches the introspection result to a file" do
      path = File.join(@dir, "schema-cache.json")

      first = described_class.introspect(counting_executor, cache: path)
      second = described_class.introspect(counting_executor, cache: path)

      expect(counting_executor.calls).to eq 1
      expect(File).to exist(path)
      codegen_parity(first)
      codegen_parity(second)
    end

    it "cache: true defaults to GraphWeaver.schema_path" do
      path = File.join(@dir, "schema.json")
      GraphWeaver.schema_path = path

      described_class.introspect(counting_executor, cache: true)
      described_class.introspect(counting_executor, cache: true)

      expect(counting_executor.calls).to eq 1
      expect(File).to exist(path)

      expect {
        described_class.introspect(counting_executor, cache: File.join(@dir, "schema.yaml"))
      }.to raise_error(ArgumentError, /\.json or \.graphql/)
    ensure
      GraphWeaver.schema_path = nil
    end

    it "caches as SDL when the path says .graphql — reviewable dumps" do
      path = File.join(@dir, "schema.graphql")

      first = described_class.introspect(counting_executor, cache: path)
      expect(File.read(path)).to match(/^type Person/m) # SDL, not JSON

      cached = described_class.introspect(counting_executor, cache: path)
      expect(counting_executor.calls).to eq 1
      codegen_parity(first)
      codegen_parity(cached) # SDL round-trip generates identically
    end

    it "cache: :graphql picks the format, anchored at GraphWeaver.schema_path" do
      GraphWeaver.schema_path = File.join(@dir, "schema.json")

      described_class.introspect(counting_executor, cache: :graphql)

      expect(File).to exist(File.join(@dir, "schema.graphql"))
      expect(File).not_to exist(File.join(@dir, "schema.json"))

      expect {
        described_class.introspect(counting_executor, cache: :yaml)
      }.to raise_error(ArgumentError, /:json, :graphql, or :gql/)
    ensure
      GraphWeaver.schema_path = nil
    end

    it "reuses a fresh dump in any format instead of re-introspecting" do
      # a reviewed schema.graphql is already checked in; cache: true
      # (defaulting to schema.json) uses it rather than writing json
      GraphWeaver.schema_path = File.join(@dir, "schema.json")
      File.write(File.join(@dir, "schema.graphql"), Demo::Schema.to_definition)

      schema = described_class.introspect(counting_executor, cache: true)

      expect(counting_executor.calls).to eq 0
      expect(File).not_to exist(File.join(@dir, "schema.json"))
      codegen_parity(schema)
    ensure
      GraphWeaver.schema_path = nil
    end

    it "records provenance when the executor knows its url" do
      with_url = Class.new do
        def url = "https://api.example.com/graphql"

        def execute(query, variables:, operation_name: nil)
          Demo::Schema.execute(query, variables:, operation_name:)
        end
      end

      # distinct basenames: a fresh sibling dump in another format would
      # otherwise satisfy the cache and skip the write
      sdl_path = File.join(@dir, "sdl.graphql")
      described_class.introspect(with_url.new, cache: sdl_path)
      meta = described_class.provenance(sdl_path)
      expect(meta["url"]).to eq "https://api.example.com/graphql"
      expect(meta["introspected_at"]).to match(/\A\d{4}-/)
      codegen_parity(described_class.load(sdl_path)) # the header comment is valid SDL

      json_path = File.join(@dir, "wire.json")
      described_class.introspect(with_url.new, cache: json_path)
      expect(described_class.provenance(json_path)["url"]).to eq "https://api.example.com/graphql"
      codegen_parity(described_class.load(json_path)) # the sibling key is ignored on load

      # executors without a url (schema classes, fakes) stay unannotated
      plain_path = File.join(@dir, "plain.json")
      described_class.introspect(counting_executor, cache: plain_path)
      expect(described_class.provenance(plain_path)).to be_nil
    end

    it "stale? re-introspects and reports drift" do
      path = File.join(@dir, "schema.graphql")
      described_class.introspect(counting_executor, cache: path)

      expect(described_class.stale?(path, transport: counting_executor)).to be false

      drifted = GraphQL::Schema.from_definition("type Query { renamed: String }")
      expect(described_class.stale?(path, transport: drifted)).to be true

      # without transport: it needs a recorded url to rebuild one, and a dump
      # from a schema class never records one — say so rather than dead-end
      expect {
        described_class.stale?(path)
      }.to raise_error(
        GraphWeaver::Error,
        /records no source url — it wasn't introspected from one\. Pass transport:, or rebuild it from the schema class/,
      )
    end

    it "refreshes the cache when the ttl has elapsed" do
      path = File.join(@dir, "schema-cache.json")

      described_class.introspect(counting_executor, cache: path, ttl: 60)
      stale = Time.now - 3600
      File.utime(stale, stale, path)
      described_class.introspect(counting_executor, cache: path, ttl: 60)

      expect(counting_executor.calls).to eq 2
    end

    it "surfaces introspection failures" do
      failing = Class.new do
        def execute(_query, variables:, operation_name: nil)
          { "errors" => [{ "message" => "introspection disabled" }] }
        end
      end

      expect {
        described_class.introspect(failing.new)
      }.to raise_error(GraphWeaver::Error, /introspection failed/)
    end

    # the newcomer's mistake: a REST base url, a GraphiQL page, a proxy that
    # ate the path — 200, valid JSON, no __schema
    it "names the endpoint when a 200 body isn't an introspection result" do
      not_graphql = Class.new do
        def url = "https://httpbin.org/post"

        def execute(_query, variables:, operation_name: nil)
          { "json" => { "query" => "query IntrospectionQuery { ... }" } }
        end
      end

      expect { described_class.introspect(not_graphql.new) }.to raise_error(
        GraphWeaver::Error,
        %r{introspection at https://httpbin\.org/post returned no __schema — is that a GraphQL endpoint\? got: .*IntrospectionQuery},
      )
    end
  end

  describe ".refresh!" do
    before { GraphWeaver.schema_path = File.join(@dir, "schema.json") }

    after { GraphWeaver.schema_path = nil }

    # stands in for GraphWeaver.new(url).transport — no network, but it
    # records the url refresh! picked, which is the thing under test
    let(:introspected) { [] }

    before do
      urls = introspected # a local: define_singleton_method rebinds self
      allow(GraphWeaver).to receive(:new) do |url, **|
        transport = Object.new
        transport.define_singleton_method(:url) { url }
        transport.define_singleton_method(:execute) do |query, variables:, operation_name: nil|
          urls << url
          Demo::Schema.execute(query, variables:, operation_name:)
        end
        Struct.new(:transport).new(transport)
      end
    end

    it "bootstraps the first dump from a given url" do
      path, url = described_class.refresh!(url: "https://api.example.com/graphql")

      expect(path).to eq GraphWeaver.schema_path
      expect(introspected).to eq [url]
      expect(described_class.provenance(path)["url"]).to eq url
    end

    it "falls back to the url the dump recorded" do
      described_class.refresh!(url: "https://api.example.com/graphql")

      expect(described_class.refresh!).to eq [GraphWeaver.schema_path, "https://api.example.com/graphql"]
      expect(introspected.size).to eq 2 # ttl: 0 — never satisfied by the dump it just wrote
    end

    it "names the fix when there is no dump to read a url from" do
      expect { described_class.refresh! }
        .to raise_error(GraphWeaver::Error, /no schema dump.*URL=/)
    end

    it "names the fix when the dump records no url" do
      File.write(GraphWeaver.schema_path, JSON.generate(Demo::Schema.as_json))

      expect { described_class.refresh! }.to raise_error(
        GraphWeaver::Error,
        /records no source url.*URL=.*rebuilt from code, not re-fetched.*getting_started/m,
      )
    end
  end


  describe "federation supergraph SDL" do
    let(:supergraph) do
      <<~GRAPHQL
        schema @link(url: "https://specs.apollo.dev/link/v1.0") { query: Query }
        directive @link(url: String!) repeatable on SCHEMA
        directive @join__type(graph: join__Graph!, extension: Boolean! = false) repeatable on OBJECT
        directive @join__field(graph: join__Graph) on FIELD_DEFINITION
        scalar join__FieldSet
        enum join__Graph { A @join__graph(name: "a", url: "http://a") }
        type Query @join__type(graph: A) {
          thing(id: ID! @join__field(graph: A)): Thing @join__field(graph: A)
        }
        type Thing @join__type(graph: A) {
          id: ID!
          rank: Rank @join__field(graph: A)
        }
        enum Rank @join__type(graph: A) { HIGH @join__enumValue(graph: A) LOW }
      GRAPHQL
    end

    it "detects a supergraph by its @join__ markers, not a plain schema" do
      expect(described_class.federation_sdl?(supergraph)).to be(true)
      expect(described_class.federation_sdl?("type Query { a: Int }")).to be(false)
    end

    # a composed graph also declares the specs that compose it, which is the
    # only marker left when join was renamed or nothing was merged
    it "detects a composed graph that carries no @join__ marker" do
      expect(described_class.federation_sdl?(
        'schema @link(url: "https://specs.apollo.dev/join/v0.3", as: "j") { query: Query }',
      )).to be(true)
      expect(described_class.federation_sdl?(
        'schema @core(feature: "https://specs.apollo.dev/core/v0.2") { query: Query }',
      )).to be(true)
      # a subgraph links the federation spec, and stays a subgraph
      expect(described_class.federation_sdl?(
        'extend schema @link(url: "https://specs.apollo.dev/federation/v2.3", import: ["@key"])',
      )).to be(false)
    end

    it "strips the composition machinery, keeping the merged type shapes" do
      schema = described_class.load(supergraph)

      expect(schema.types.keys.grep(/join__|link__/)).to be_empty
      expect(schema.get_type("Thing").fields.keys).to eq %w[id rank]
      expect(schema.get_type("Rank").values.keys).to eq %w[HIGH LOW]
      # a real field survives with its type, minus the join plumbing
      expect(schema.get_type("Query").fields["thing"].type.unwrap.graphql_name).to eq "Thing"
    end

    it "leaves a plain (non-federation) schema untouched" do
      sdl = "type Query {\n  a: Int\n  b: String\n}"
      expect(described_class.load(sdl).get_type("Query").fields.keys).to eq %w[a b]
    end

    context "@inaccessible (deriving the API schema)" do
      let(:with_inaccessible) do
        <<~GRAPHQL
          directive @inaccessible on FIELD_DEFINITION | OBJECT | ENUM_VALUE | ARGUMENT_DEFINITION
          directive @join__type(graph: join__Graph!) repeatable on OBJECT | ENUM
          enum join__Graph { A @join__graph(name: "a", url: "http://a") }
          type Query @join__type(graph: A) {
            user: User
            secret: Secret @inaccessible
            thing(id: ID!, debug: Boolean @inaccessible): Thing
          }
          type User @join__type(graph: A) { id: ID! email: String @inaccessible rank: Rank }
          type Secret @join__type(graph: A) @inaccessible { code: String! }
          type Thing @join__type(graph: A) { id: ID! }
          enum Rank @join__type(graph: A) { HIGH LOW BETA @inaccessible }
        GRAPHQL
      end

      let(:api) { described_class.load(with_inaccessible) }

      it "drops @inaccessible fields, arguments, and enum values" do
        expect(api.get_type("User").fields.keys).to eq %w[id rank]         # email gone
        expect(api.get_type("Query").fields["thing"].arguments.keys).to eq %w[id]  # debug gone
        expect(api.get_type("Rank").values.keys).to eq %w[HIGH LOW]        # BETA gone
      end

      it "removes an @inaccessible type and cascades to fields that referenced it" do
        expect(api.get_type("Secret")).to be_nil
        expect(api.get_type("Query").fields.keys).to eq %w[user thing]     # secret cascaded away
        expect(api.types.keys.grep(/join__|link__/)).to be_empty
      end
    end

    context "review fixes" do
      it "keeps a user type whose name matches a federation directive (link)" do
        sdl = <<~GRAPHQL
          directive @link(url: String!) repeatable on SCHEMA
          directive @join__type(graph: join__Graph!) repeatable on OBJECT
          enum join__Graph { A @join__graph(name: "a", url: "http://a") }
          type link @join__type(graph: A) { id: ID! }
          type Query @join__type(graph: A) { node: link }
        GRAPHQL
        schema = described_class.load(sdl)

        expect(schema.get_type("link")).not_to be_nil
        expect(schema.get_type("Query").fields["node"].type.unwrap.graphql_name).to eq "link"
      end

      # graphql-ruby's printer omits a schema definition's root-types body when
      # the names are the GraphQL defaults, but still prints its directives —
      # so a survivor reprints as an unparseable braceless `schema @tag(...)`
      ['@tag(name: "public")', '@composeDirective(name: "@mine")'].each do |directive|
        it "loads a supergraph carrying #{directive[/\w+/]} on `schema`" do
          sdl = <<~GRAPHQL
            schema @link(url: "https://specs.apollo.dev/link/v1.0") #{directive} { query: Query }
            directive @link(url: String!) repeatable on SCHEMA
            directive @tag(name: String!) repeatable on SCHEMA | OBJECT
            directive @composeDirective(name: String!) repeatable on SCHEMA
            directive @join__type(graph: join__Graph!) repeatable on OBJECT
            enum join__Graph { A @join__graph(name: "a", url: "http://a") }
            type Query @join__type(graph: A) @tag(name: "public") { thing: String }
          GRAPHQL

          expect(described_class.load(sdl).get_type("Query").fields.keys).to eq %w[thing]
        end
      end

      # the printer DOES print the body here, so this loaded before the fix —
      # it's the case a too-eager fix would break
      it "keeps a supergraph's non-conventional root type names" do
        sdl = <<~GRAPHQL
          schema @tag(name: "public") { query: RootQuery }
          directive @tag(name: String!) repeatable on SCHEMA
          directive @join__type(graph: join__Graph!) repeatable on OBJECT
          enum join__Graph { A @join__graph(name: "a", url: "http://a") }
          type RootQuery @join__type(graph: A) { thing: String }
        GRAPHQL

        expect(described_class.load(sdl).query.graphql_name).to eq "RootQuery"
      end

      it "cascades into a directive definition's own arguments" do
        sdl = <<~GRAPHQL
          directive @inaccessible on SCALAR
          directive @join__type(graph: join__Graph!) repeatable on OBJECT
          directive @mine(x: Secret) on FIELD_DEFINITION
          enum join__Graph { A @join__graph(name: "a", url: "http://a") }
          scalar Secret @inaccessible
          type Query @join__type(graph: A) { a: String @mine }
        GRAPHQL

        expect(described_class.load(sdl).get_type("Query").fields.keys).to eq %w[a]
      end

      it "brands an unbuildable schema, naming the artifact it took the source for" do
        # a supergraph whose Query field points at a type nothing defines
        expect {
          described_class.load(<<~GRAPHQL)
            directive @join__type(graph: join__Graph!) repeatable on OBJECT
            enum join__Graph { A @join__graph(name: "a", url: "http://a") }
            type Query @join__type(graph: A) { thing: Nowhere }
          GRAPHQL
        }.to raise_error(GraphWeaver::Error, /supergraph SDL/)

        # a subgraph applying a directive outside the spec — we can't supply
        # that definition, so say what we thought we were reading
        expect {
          described_class.load("type Query {\n  a: String\n}\ntype User @key(fields: \"id\") @nope { id: ID! }")
        }.to raise_error(GraphWeaver::Error, /subgraph SDL/)

        expect { described_class.load("type Query {\n  thing: Nowhere\n}") }
          .to raise_error(GraphWeaver::Error, /plain SDL/)

        expect { described_class.load("type Query {\n  oops\n}") } # unparseable
          .to raise_error(GraphWeaver::Error, /plain SDL.*ParseError/m)

        expect { described_class.load({ "data" => {} }) }
          .to raise_error(GraphWeaver::Error, /introspection result/)
      end

      it "raises a clear error when @inaccessible removes everything queryable" do
        sdl = <<~GRAPHQL
          directive @inaccessible on OBJECT
          directive @join__type(graph: join__Graph!) repeatable on OBJECT
          enum join__Graph { A @join__graph(name: "a", url: "http://a") }
          type Query @join__type(graph: A) @inaccessible { thing: String }
        GRAPHQL
        expect { described_class.load(sdl) }.to raise_error(GraphWeaver::Error, /no object types/)
      end
    end
  end
end

RSpec.describe "#{GraphWeaver::SchemaLoader} federation directive lists" do
  # SUBGRAPH_MARKERS is the subset of SUBGRAPH_DIRECTIVE_DEFS unambiguous
  # enough to identify a subgraph — the rest (@tag, @link, @inaccessible…)
  # appear in supergraphs and plain SDL too. Only the subset rule is a
  # judgement; membership is not, and the two lists sit 15 lines apart, so a
  # rename in the definitions has to reach the markers.
  it "recognizes only directives it can also define" do
    loader = GraphWeaver::SchemaLoader
    defined = loader::SUBGRAPH_DIRECTIVE_DEFS.keys.map { |name| name.delete_prefix("@") }

    expect(loader::SUBGRAPH_MARKERS - defined).to be_empty
  end
end

RSpec.describe "#{GraphWeaver::SchemaLoader} auth provenance" do
  # `--auth MY_TOKEN` used to give an app that authenticated and rake tasks
  # that 401'd: the generator wrote ENV["MY_TOKEN"] into the initializer
  # while the schema tasks hardcoded GRAPHWEAVER_AUTH.
  it "reads the ENV var the dump recorded" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "schema.json")
      File.write(path, JSON.generate(
        "data" => { "__schema" => {} },
        "graph_weaver" => { "url" => "https://api.example.com/graphql", "auth_env" => "MY_TOKEN" },
      ))

      expect(GraphWeaver::SchemaLoader.auth_env(path)).to eq "MY_TOKEN"
    end
  end

  it "falls back for a dump that never named one" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "schema.json")
      File.write(path, JSON.generate(
        "data" => { "__schema" => {} },
        "graph_weaver" => { "url" => "https://api.example.com/graphql" },
      ))

      expect(GraphWeaver::SchemaLoader.auth_env(path)).to eq "GRAPHWEAVER_AUTH"
      expect(GraphWeaver::SchemaLoader.auth_env(nil)).to eq "GRAPHWEAVER_AUTH"
    end
  end
end
