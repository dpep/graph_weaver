require "graph_weaver/transport/faraday"
require "graph_weaver/testing"
require "logger"
require "stringio"
require "tmpdir"

# app-owned types for the enum-mapping and type-helper specs
class PetKind < T::Enum
  enums do
    Cat = new("cat")
    Dog = new("dog")
    Unknown = new("unknown")
  end
end

class CatsOnly < T::Enum
  enums do
    Cat = new("cat")
  end
end

module PetShouting
  def shout = "#{name}!"
end

describe GraphWeaver::Client do
  include_context "graphql http server"

  describe "from a url" do
    it "builds the transport, introspects the schema lazily, and executes" do
      client = GraphWeaver.new(url)

      expect(client.transport).to be_a GraphWeaver::Transport::HTTP # no retry wrapper by default
      expect(client.execute!("query { person(id: 1) { name } }").person&.name).to eq "Daniel"
      expect(client.schema.types).to have_key "Person"
    end

    it "sends bearer auth, or a verbatim scheme, or custom headers" do
      GraphWeaver.new(url, auth: "t0ken").execute!("query { person(id: 1) { id } }")
      expect(@requests.last[:headers]["authorization"]).to eq ["Bearer t0ken"]

      GraphWeaver.new(url, auth: "Basic dXNlcg==").execute!("query { person(id: 1) { id } }")
      expect(@requests.last[:headers]["authorization"]).to eq ["Basic dXNlcg=="]

      GraphWeaver.new(url, headers: { "X-Api-Key" => "k" }).execute!("query { person(id: 1) { id } }")
      expect(@requests.last[:headers]["x-api-key"]).to eq ["k"]
    end

    it "stays on the built-in transport even when faraday is loaded" do
      expect(defined?(::Faraday)).to be_truthy # transitively present, never chosen

      expect(GraphWeaver.new(url).transport).to be_a GraphWeaver::Transport::HTTP
      expect(GraphWeaver.new(url, transport: :http).transport).to be_a GraphWeaver::Transport::HTTP
    end

    it "builds Faraday on an explicit request or a middleware block" do
      expect(GraphWeaver.new(url, transport: :faraday).transport).to be_a GraphWeaver::Transport::Faraday

      client = GraphWeaver.new(url) { |conn| conn.options.timeout = 3 }
      expect(client.transport).to be_a GraphWeaver::Transport::Faraday
    end

    it "logs the transport it built" do
      io = StringIO.new
      GraphWeaver.logger = Logger.new(io, level: Logger::INFO)
      GraphWeaver.new(url, transport: :faraday)
      expect(io.string).to include("transport: GraphWeaver::Transport::Faraday -> #{url}")
    ensure
      GraphWeaver.logger = nil
    end

    it "rejects an unknown transport, a block against :http, and a symbol without a url" do
      expect { GraphWeaver.new(url, transport: :typhoeus) }.to raise_error(ArgumentError, /:http or :faraday/)
      expect { GraphWeaver.new(url, transport: Demo::Schema) }.to raise_error(ArgumentError, /:http or :faraday/)
      expect { GraphWeaver.new(url, transport: :http) { |conn| conn } }.to raise_error(ArgumentError, /:faraday/)
      expect { GraphWeaver.new(Demo::Schema, transport: :faraday) }.to raise_error(ArgumentError, /needs a url/)
    end

    it "names the missing gem when faraday isn't installed" do
      hide_const("Faraday")

      expect { GraphWeaver.new(url, transport: :faraday) }.to raise_error(ArgumentError, /faraday gem/)
      expect { GraphWeaver.new(url) { |conn| conn } }.to raise_error(ArgumentError, /faraday gem/)
    end

    it "threads timeouts through to either transport" do
      faraday = GraphWeaver.new(url, transport: :faraday, open_timeout: 2, read_timeout: 5).transport
      expect(faraday.instance_variable_get(:@connection).options.open_timeout).to eq 2
      expect(faraday.instance_variable_get(:@connection).options.read_timeout).to eq 5

      http = GraphWeaver.new(url, read_timeout: 5).transport
      expect(http.instance_variable_get(:@read_timeout)).to eq 5
      expect(http.instance_variable_get(:@open_timeout)).to eq 10 # untouched default
    end

    it "tunes retries with a Hash, or disables them" do
      slept = []
      # nothing listens on port 1: every attempt is a connection refusal
      client = GraphWeaver.new("http://127.0.0.1:1/graphql", retries: { tries: 3, sleeper: ->(s) { slept << s } })

      expect { client.execute!("query { person(id: 1) { id } }") }.to raise_error(GraphWeaver::TransportError)
      expect(slept.size).to eq 2 # the Hash reached the Retry

      expect(GraphWeaver.new(url, retries: true).transport).to be_a GraphWeaver::Retry
      expect(GraphWeaver.new(url, retries: false).transport).to be_a GraphWeaver::Transport::HTTP
    end

    it "parses typed modules bound to its transport" do
      mod = GraphWeaver.new(url).parse("query Who { person(id: 1) { name } }")

      expect(mod.execute!.person&.name).to eq "Daniel"
    end

    it "load_queries! defines a module per query file, reloadably" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "person.graphql"), "query($id: ID!) { person(id: $id) { name } }")
        File.write(File.join(dir, "people.graphql"), "query { people { name } }")
        namespace = Module.new

        mods = GraphWeaver.new(url).load_queries!(dir, namespace:)

        expect(mods.size).to eq 2
        expect(namespace::PersonQuery.execute!(id: "1").person&.name).to eq "Daniel"
        expect(namespace::PeopleQuery.execute!.people.map(&:name)).to include "Daniel"

        # reloadable: a second pass replaces the constants without warning
        expect { GraphWeaver.new(url).load_queries!(dir, namespace:) }.not_to output.to_stderr
      end
    end

    it "load_queries! logs what replacing a loaded module means for its objects" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "person.graphql"), "query($id: ID!) { person(id: $id) { name } }")
        namespace = Module.new
        client = GraphWeaver.new(url)
        client.load_queries!(dir, namespace:)

        io = StringIO.new
        GraphWeaver.logger = Logger.new(io, level: Logger::INFO)
        client.load_queries!(dir, namespace:)

        expect(io.string)
          .to include("replacing PersonQuery — objects built from the previous module stay instances of it")
      ensure
        GraphWeaver.logger = nil
      end
    end

    it "load_queries! walks every configured queries_path" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "person.graphql"), "query($id: ID!) { person(id: $id) { name } }")
        namespace = Module.new

        GraphWeaver.queries_paths << dir
        mods = GraphWeaver.new(url).load_queries!(namespace:)

        expect(mods.size).to eq 1
        expect(namespace::PersonQuery.execute!(id: "1").person&.name).to eq "Daniel"
      ensure
        GraphWeaver.queries_paths = nil
      end
    end

  end

  describe "from a schema source" do
    it "a live schema class executes in-process" do
      client = GraphWeaver.new(Demo::Schema)

      expect(client.execute!("query { person(id: 1) { name } }").person&.name).to eq "Daniel"
      expect(client.schema).to equal Demo::Schema
    end

    it "accepts retries: nil (off), like a url client" do
      expect { GraphWeaver.new(Demo::Schema, retries: nil) }.not_to raise_error
      expect { GraphWeaver.new(Demo::Schema, retries: true) }.to raise_error(ArgumentError, /url/)
    end

    it "is self-contained: the app default never leaks into an explicit client" do
      recorded = []
      recorder = Class.new do
        define_method(:execute) do |query, variables:, operation_name: nil|
          recorded << query
          Demo::Schema.execute(query, variables:, operation_name:)
        end
      end

      GraphWeaver.client = recorder.new
      GraphWeaver.new(Demo::Schema).execute!("query { person(id: 1) { id } }")

      expect(recorded).to be_empty # the explicit client ran in-process
    ensure
      GraphWeaver.client = nil
    end

    it "a dump is type information only — no transport to run against" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "schema.graphql")
        File.write(path, Demo::Schema.to_definition)

        client = GraphWeaver.new(path)
        expect(client.schema.types).to have_key "Person"
        expect { client.execute("query { person(id: 1) { id } }") }
          .to raise_error(GraphWeaver::Error, /no transport/)

        # bring your own transport
        with_transport = GraphWeaver.new(path, transport: Demo::Schema)
        expect(with_transport.execute!("query { person(id: 1) { name } }").person&.name).to eq "Daniel"
      end
    end

    it "rejects url-only options" do
      expect { GraphWeaver.new(Demo::Schema, auth: "t0ken") }.to raise_error(ArgumentError, /url/)
      # a schema source never introspects — a cache would silently no-op
      expect { GraphWeaver.new(Demo::Schema, cache: true) }.to raise_error(ArgumentError, /introspection/)
    end

    it "parsed modules run against the client's schema class" do
      mod = GraphWeaver.new(Demo::Schema).parse("query Who { person(id: 1) { name } }")

      expect(mod.execute!.person&.name).to eq "Daniel" # no global wiring needed
    end
  end

  describe "GraphWeaver.client=" do
    # parsed without a client, so it follows the global fallback chain
    let(:mod) { GraphWeaver.parse(schema: Demo::Schema, query: "query Who { person(id: 1) { name } }") }

    after { GraphWeaver.client = nil }

    it "wires generated modules to the default client" do
      expect { mod.execute! }.to raise_error(GraphWeaver::Error, /no client/)

      GraphWeaver.client = GraphWeaver.new(url)
      expect(mod.execute!.person&.name).to eq "Daniel"
    end

    it "a per-call client beats the app default" do
      GraphWeaver.client = GraphWeaver.new("http://127.0.0.1:1/graphql") # nothing listens

      expect(mod.execute!(Demo::Schema).person&.name).to eq "Daniel"
    end
  end

  describe "schema caching" do
    it "memoizes, and honors cache: on disk" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "schema.json")
        client = GraphWeaver.new(url, cache: path)

        expect(client.schema).to equal client.schema # memoized
        expect(File).to exist(path)

        # a fresh client reads the dump instead of re-introspecting
        @requests.clear
        expect(GraphWeaver.new(url, cache: path).schema.types).to have_key "Person"
        expect(@requests).to be_empty
      end
    end
  end

  describe "client-scoped scalars" do
    let(:query) { "query { person(id: 1) { birthday } }" }

    it "overlays the global registry per client, without leaking" do
      client = GraphWeaver.new(Demo::Schema)
      client.register_scalar("Date", String, cast: :itself, serialize: :itself)

      # this client: Date stays a raw String off the wire
      expect(client.execute!(query).person&.birthday).to be_a String

      # other clients and the global registry are untouched
      expect(GraphWeaver.new(Demo::Schema).execute!(query).person&.birthday).to be_a Date
      expect(GraphWeaver::Codegen.scalar("Date").type).to eq "Date"
    end

    it "catches typo'd scalar names like the other registrars" do
      client = GraphWeaver.new(Demo::Schema)

      expect { client.register_scalar("Dtae", String) }
        .to raise_error(GraphWeaver::Error, /register_scalar\("Dtae"\).*did you mean 'Date'/)
    end
  end

  describe "enum mappings" do
    let(:client) { GraphWeaver.new(Demo::Schema) }
    let(:query) { "query { person(id: 1) { pets { species } } }" }
    let(:mutation) { "mutation($species: Species!) { addPet(name: \"Rex\", species: $species) { species } }" }

    it "casts wire values into the registered app enum, and serializes back" do
      client.register_enum("Species", PetKind)

      species = client.execute!(query).person&.pets&.map(&:species)
      expect(species).to eq [PetKind::Dog, PetKind::Cat]

      # variables accept the member or its wire value
      expect(client.execute!(mutation, species: PetKind::Dog).add_pet.species).to eq PetKind::Dog
      expect(client.execute!(mutation, species: "CAT").add_pet.species).to eq PetKind::Cat

      # other clients still generate their own T::Enum
      other = GraphWeaver.new(Demo::Schema).execute!(query).person&.pets&.first&.species
      expect(other).not_to be_a PetKind
    end

    it "checks exhaustiveness at generation, naming the gaps" do
      client.register_enum("Species", CatsOnly)

      expect { client.parse(query) }
        .to raise_error(GraphWeaver::Error, /CatsOnly has no member for Species value\(s\) DOG/)
    end

    it "fallback: absorbs unknown wire values on cast; inputs stay strict" do
      client.register_enum("Species", CatsOnly, fallback: CatsOnly::Cat)

      species = client.execute!(query).person&.pets&.map(&:species)
      expect(species).to eq [CatsOnly::Cat, CatsOnly::Cat] # DOG absorbed

      expect { client.execute!(mutation, species: "DOG") }.to raise_error(KeyError)
    end

    it "register_enums maps several at once" do
      client.register_enums("Species" => PetKind)

      expect(client.execute!(query).person&.pets&.first&.species).to eq PetKind::Dog
    end
  end

  describe "type helpers" do
    let(:query) { "query { person(id: 1) { pets { name species } } }" }

    it "includes registered modules into structs generated from the type" do
      client = GraphWeaver.new(Demo::Schema)
      client.extend_type("Pet", PetShouting)

      pet = client.execute!(query).person&.pets&.first
      expect(pet&.shout).to eq "Shelby!"
      expect(pet&.name).to eq "Shelby" # the wire value stays honest

      # scoped: another client's structs don't get the helpers
      other = GraphWeaver.new(Demo::Schema).execute!(query).person&.pets&.first
      expect(other).not_to respond_to(:shout)
    end

    it "catches typo'd registrations at the call site when the schema is in hand" do
      client = GraphWeaver.new(Demo::Schema)

      expect { client.extend_type("Pett", PetShouting) }
        .to raise_error(GraphWeaver::Error, /extend_type\("Pett"\).*did you mean 'Pet'/)
      expect { client.register_enum("Specis", PetKind) }
        .to raise_error(GraphWeaver::Error, /register_enum\("Specis"\).*did you mean 'Species'/)
    end

    it "names the map: keyword when a value map is passed positionally" do
      # a bare "given 3, expected 2" never mentions the keyword
      message = 'register_enum: the value map is a keyword — register_enum("Species", PetKind, map: {...})'

      expect { GraphWeaver.new(Demo::Schema).register_enum("Species", PetKind, { "cat" => PetKind::Cat }) }
        .to raise_error(GraphWeaver::Error, message)
      expect { GraphWeaver.register_enum("Species", PetKind, { "cat" => PetKind::Cat }) }
        .to raise_error(GraphWeaver::Error, message)
    end

    it "catches typo'd registrations at generation when the schema is lazy" do
      # a url client hasn't introspected yet — registration can't validate
      # eagerly, so the next parse raises instead
      mod = GraphWeaver::Codegen
      expect {
        mod.generate(schema: Demo::Schema, query:, module_name: "Typo",
          types: { "Pett" => { mixins: [PetShouting], requires: [] } })
      }.to raise_error(GraphWeaver::Error, /extend_type\("Pett"\).*did you mean 'Pet'/)
    end

    it "builds a mixin from a block, auto-named for generated source" do
      client = GraphWeaver.new(Demo::Schema)
      client.extend_type("Pet") do
        def whisper = "#{name.downcase}..."
      end

      pet = client.execute!(query).person&.pets&.first
      expect(pet&.whisper).to eq "shelby..."
      expect(GraphWeaver::TypeHelpers.const_defined?(:Pet)).to be true

      # a second block registration stacks under a fresh name
      client.extend_type("Pet") { def echo = name * 2 }
      expect(client.execute!(query).person&.pets&.first&.echo).to eq "ShelbyShelby"

      expect { client.extend_type("Pet") }.to raise_error(ArgumentError, /helper modules, a block, or alias/)
    end
  end
end
