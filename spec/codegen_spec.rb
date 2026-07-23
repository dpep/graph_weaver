
require_relative "generated/add_pet_query"
require_relative "generated/adopt_query"
require_relative "generated/find_pets_query"
require_relative "generated/named_query"
require_relative "generated/person_query"
require_relative "generated/search_query"

describe GraphWeaver::Codegen do
  it "keeps the checked-in generated files up to date" do
    root = File.expand_path("..", __dir__)

    expect(
      GraphWeaver.verify_generated!(
        schema: Demo::Schema,
        queries: File.join(root, "spec/queries"),
        output: File.join(root, "spec/generated"),
        client: Demo::Schema,
      ),
    ).to be true
  end

  describe "eval safety" do
    it "rejects module names that are not constant names" do
      expect {
        described_class.generate(
          schema: Demo::Schema,
          query: "query People { people { name } }",
          module_name: "Foo; end; puts :evil; module Bar",
        )
      }.to raise_error(ArgumentError, /constant name/)
    end

    it "survives queries containing bare GRAPHQL lines (block strings)" do
      query = %(query Sneaky { search(term: """\nGRAPHQL\n""") { __typename ... on Named { name } } })

      mod = GraphWeaver.parse(schema: Demo::Schema, query:, client: Demo::Schema)
      expect(mod::QUERY).to include(%("""\nGRAPHQL\n"""))
      expect(mod.execute.errors?).to be false
    end
  end

  it "rejects live executor objects when generating files" do
    expect {
      described_class.generate(
        schema: Demo::Schema,
        client: GraphWeaver::Transport::HTTP.new("http://example.com"),
        query: "query People { people { name } }",
      )
    }.to raise_error(ArgumentError, /named constant/)
  end

  it "camelizes snake_case schema type names (Hasura-style) into valid constants" do
    schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
      type Query { pokemon_v2_pokemon(limit: Int): [pokemon_v2_pokemon!]! }
      type pokemon_v2_pokemon { id: Int! name: String! }
    GRAPHQL

    executor = Class.new do
      def execute(_query, variables:)
        { "data" => { "pokemon_v2_pokemon" => [{ "id" => 1, "name" => "bulbasaur" }] } }
      end
    end

    mod = GraphWeaver.parse(schema:, query: "query { pokemon_v2_pokemon { id name } }", client: executor.new)
    pokemon = mod.execute!.pokemon_v2_pokemon.first

    expect(pokemon.class.name).to end_with("Result::PokemonV2Pokemon")
    expect(pokemon&.name).to eq "bulbasaur"
  end

  describe "hostile prop names" do
    def schema_with_input(fields)
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { ok: Boolean }
        type Mutation { save(input: Tricky!): Boolean }
        input Tricky { #{fields} }
      GRAPHQL
    end

    it "a field named result/value serializes correctly despite the generated locals" do
      schema = schema_with_input("result: String value: String other: String")
      mod = GraphWeaver.parse(
        schema:,
        query: "mutation Save($input: Tricky!) { save(input: $input) }",
        client: Demo::Schema, # never called; serialize is pure
      )

      wire = mod::Tricky.new(result: "kept", value: "also kept").serialize
      expect(wire).to eq({ "result" => "kept", "value" => "also kept" })
    end

    it "refuses input fields that collide with keywords or generated methods" do
      expect {
        GraphWeaver.parse(schema: schema_with_input("nil: String"), query: "mutation($input: Tricky!) { save(input: $input) }", name: "T1")
      }.to raise_error(GraphWeaver::Error, /Tricky\.nil.*Ruby keyword/)

      expect {
        GraphWeaver.parse(schema: schema_with_input("serialize: String"), query: "mutation($input: Tricky!) { save(input: $input) }", name: "T2")
      }.to raise_error(GraphWeaver::Error, /generated #serialize/)
    end

    it "refuses variables whose kwarg would be a Ruby keyword" do
      expect {
        GraphWeaver.parse(schema: Demo::Schema, query: "query($end: ID!) { person(id: $end) { id } }")
      }.to raise_error(GraphWeaver::Error, /\$end.*Ruby keyword/)
    end

    it "nothing is reserved: a variable named $client or $executor is fine" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: "query($executor: ID!) { person(id: $executor) { name } }",
      )

      expect(mod.execute!(executor: "1").person&.name).to eq "Daniel"
    end
  end

  it "wraps unparseable queries as ValidationError, not GraphQL::ParseError" do
    expect { GraphWeaver.parse(schema: Demo::Schema, query: "query {") }
      .to raise_error(GraphWeaver::ValidationError)
  end

  it "rejects queries that do not validate against the schema" do
    codegen = described_class.new(
      schema: Demo::Schema,
      client: Demo::Schema,
      query: "{ nope }",
      module_name: "Bad",
    )

    expect { codegen.generate }.to raise_error(GraphWeaver::ValidationError, /invalid query/)
  end

  describe "the generated module" do
    let(:response) { PersonQuery.execute(id: "1") }
    let(:result) { response.data! }
    let(:person) { result.person }

    it "freezes QUERY (frozen_string_literal covers the heredoc)" do
      expect(PersonQuery::QUERY).to be_frozen
    end

    it "executes and casts into the generated structs" do
      expect(response).to be_a GraphWeaver::Response
      expect(result).to be_a PersonQuery::Result
      expect(person).to be_a PersonQuery::Result::Person
      expect(person.name).to eq "Daniel"
      expect(person.birthday).to eq Date.new(1990, 6, 15)
      expect(person.pets.map(&:name)).to eq %w[Shelby Brownie]
    end

    it "returns errors in the envelope; data! raises QueryError" do
      failing = Class.new do
        def execute(_query, variables:)
          { "errors" => [{ "message" => "boom", "extensions" => { "code" => "OOPS" } }] }
        end
      end

      response = PersonQuery.execute(failing.new, id: "1")
      expect(response.errors?).to be true
      expect(response.errors.first.code).to eq "OOPS"
      expect { response.data! }.to raise_error(GraphWeaver::QueryError, /boom/)
    end

    it "execute! returns the result directly, raising QueryError on errors" do
      expect(PersonQuery.execute!(id: "1").person&.name).to eq "Daniel"

      failing = Class.new do
        def execute(_query, variables:) = { "errors" => [{ "message" => "boom" }] }
      end
      expect { PersonQuery.execute!(failing.new, id: "1") }
        .to raise_error(GraphWeaver::QueryError)
    end
  end

  describe "from_response — standalone deserialization (no client)" do
    let(:raw) do
      {
        "data" => { "person" => { "id" => "1", "name" => "Daniel", "birthday" => "1990-06-15", "pets" => [{ "name" => "Shelby" }] } },
        "extensions" => { "cost" => 1 },
      }
    end

    it "deserializes a raw response hash into the typed envelope" do
      response = PersonQuery.from_response(raw)
      expect(response).to be_a GraphWeaver::Response
      expect(response.data!.person&.name).to eq "Daniel"
      expect(response.data!.person&.birthday).to eq Date.new(1990, 6, 15)
      expect(response.data!.person&.pets&.map(&:name)).to eq ["Shelby"]
      expect(response.extensions).to eq({ "cost" => 1 })
      expect(response.errors?).to be false
    end

    it "accepts anything responding to #to_h (e.g. a schema result)" do
      hash = raw # capture: the singleton method body runs with self = wrapped
      wrapped = Object.new.tap { |o| o.define_singleton_method(:to_h) { hash } }
      expect(PersonQuery.from_response(wrapped).data!.person&.name).to eq "Daniel"
    end

    it "carries top-level errors into the envelope" do
      response = PersonQuery.from_response("errors" => [{ "message" => "boom" }])
      expect(response.errors?).to be true
      expect(response.data).to be_nil
    end

    it "from_response! returns the result, raising QueryError on errors" do
      expect(PersonQuery.from_response!(raw).person&.name).to eq "Daniel"
      expect { PersonQuery.from_response!("errors" => [{ "message" => "boom" }]) }
        .to raise_error(GraphWeaver::QueryError)
    end
  end

  describe "unions and fragments" do
    let(:results) { SearchQuery.execute(term: "el").data!.search }

    it "dispatches each result to its member struct via __typename" do
      expect(results.map(&:class)).to eq [
        SearchQuery::Result::SearchResult::Person,
        SearchQuery::Result::SearchResult::Pet,
      ]
      expect(results.map(&:__typename)).to eq %w[Person Pet]
    end

    it "casts member fields, including interface-condition and fragment-spread selections" do
      person, pet = results

      expect(person.name).to eq "Daniel" # selected via `... on Named`
      expect(person.birthday).to eq Date.new(1990, 6, 15)
      expect(pet.name).to eq "Shelby"
      expect(pet.species).to eq SearchQuery::Result::SearchResult::Pet::Species::Dog
    end

    it "deserializes enums into generated T::Enums" do
      species = SearchQuery::Result::SearchResult::Pet::Species

      expect(species.values).to eq [species::Cat, species::Dog]
      expect(species::Dog.serialize).to eq "DOG"
    end

    it "requires __typename when the selection varies by concrete type" do
      codegen = described_class.new(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: 'query { search(term: "x") { ... on Pet { species } ... on Person { email } } }',
        module_name: "Bad",
      )

      expect { codegen.generate }.to raise_error(ArgumentError, /__typename/)
    end
  end

  describe "narrowed abstract selections" do
    it "interface-level fields need no __typename — one struct, no dispatch" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: 'query { named(name: "Shelby") { name } }',
      )

      named = mod.execute!.named
      expect(named&.name).to eq "Shelby"
      expect(named).not_to respond_to(:species) # one shared struct, not a Pet member
    end

    it "refuses to narrow when every field is @skip/@include-conditional" do
      # a matching Pet with all fields skipped returns {} — byte-identical
      # to a non-match, so narrowing would silently drop real matches
      expect {
        GraphWeaver.parse(
          schema: Demo::Schema,
          query: 'query($d: Boolean!) { search(term: "el") { ... on Pet { name @include(if: $d) } } }',
        )
      }.to raise_error(GraphWeaver::Error, /at least one field not under @skip/)
    end

    it "a single `... on Type` condition narrows: matches cast, mismatches are nil" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: 'query { search(term: "el") { ... on Pet { name species } } }',
      )

      results = mod.execute!.search
      expect(results&.first).to be_nil # Daniel is a Person — narrowed away
      expect(results&.last&.name).to eq "Shelby"
    end
  end

  describe "interface-typed fields" do
    it "dispatches to member structs like unions" do
      pet = NamedQuery.execute(name: "Shelby").data!.named
      person = NamedQuery.execute(name: "Daniel").data!.named

      expect(pet).to be_a NamedQuery::Result::Named::Pet
      expect(pet.name).to eq "Shelby" # interface field, gathered into every member
      expect(pet.species).to eq NamedQuery::Result::Named::Pet::Species::Dog
      expect(person).to be_a NamedQuery::Result::Named::Person
      expect(person.name).to eq "Daniel"
    end
  end

  describe "mutations and typed variables" do
    it "executes mutations with typed kwargs, serializing enum variables" do
      result = AddPetQuery.execute(name: "Rex", species: AddPetQuery::Species::Dog).data!

      expect(result.add_pet.name).to eq "Rex"
      expect(result.add_pet.species).to eq AddPetQuery::Result::Pet::Species::Dog
    end

    it "hints when a result field is called by its camelCase wire name" do
      result = AddPetQuery.execute!(name: "Rex", species: "DOG")

      expect { result.addPet }.to raise_error(NoMethodError, /use 'add_pet'/)
      expect { result.add_pet.bogusField }.to raise_error(NoMethodError) do |e|
        expect(e.message).not_to include("use") # nothing to hint at
      end
    end

    it "suggests the nearest prop for a typo, in either casing" do
      result = AddPetQuery.execute!(name: "Rex", species: "DOG")

      expect { result.addPt }.to raise_error(NoMethodError, /did you mean 'add_pet'\?/)
      expect { result.add_pt }.to raise_error(NoMethodError, /did you mean 'add_pet'\?/)
      expect { result.add_pet.nmae }.to raise_error(NoMethodError, /did you mean 'name'\?/)
    end

    it "flattens a single input-object variable into typed kwargs" do
      pet = AdoptQuery.execute!(name: "Rex", species: AdoptQuery::Species::Dog).adopt
      expect(pet.name).to eq "Rex"
      expect(pet.species).to eq AdoptQuery::Result::Pet::Species::Dog

      # enums accept their wire value; optional fields ride along when
      # set, stay off the wire when nil
      expect(AdoptQuery.execute!(name: "Rex", species: "DOG", nickname: "Rexy").adopt.name).to eq "Rexy"

      # bad shapes fail loudly at the boundary
      expect { AdoptQuery.execute!(species: "DOG") }.to raise_error(ArgumentError)
      expect { AdoptQuery.execute!(name: "Rex", species: "DRAGON") }.to raise_error(KeyError)
    end

    it "keeps the input: kwarg when other variables ride along" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: <<~GRAPHQL,
          mutation($input: AdoptionInput!, $detail: Boolean!) {
            adopt(input: $input) {
              name
              species @include(if: $detail)
            }
          }
        GRAPHQL
      )

      pet = mod.execute!(input: { name: "Rex", species: "DOG" }, detail: false).adopt
      expect(pet.name).to eq "Rex"
      expect(pet.species).to be_nil
    end

    it "still generates the input struct — nested inputs, building by hand" do
      nicknamed = AdoptQuery::AdoptionInput.new(
        name: "Rex",
        species: AdoptQuery::Species::Dog,
        nickname: "Rexy",
      )
      expect(nicknamed.serialize).to include("nickname" => "Rexy", "species" => "DOG")
      expect(nicknamed.to_h).to eq nicknamed.serialize

      bare = AdoptQuery::AdoptionInput.new(name: "Rex", species: AdoptQuery::Species::Dog)
      expect(bare.serialize).not_to have_key("nickname")

      # coerce: underscored Symbol/String keys, enums as wire values
      coerced = AdoptQuery::AdoptionInput.coerce({ "name" => "Rex", species: "CAT" })
      expect(coerced.species).to eq AdoptQuery::Species::Cat

      # a typo'd key raises with a hint instead of silently dropping
      expect { AdoptQuery::AdoptionInput.coerce({ name: "Rex", species: "CAT", nickame: "Rexy" }) }
        .to raise_error(ArgumentError, /nickame \(did you mean 'nickname'\?\)/)
    end

    it "supports recursive input types (Hasura-style bool_exp filters)" do
      schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { pokemon(where: pokemon_bool_exp): [pokemon!]! }
        type pokemon { id: Int! name: String! }
        input pokemon_bool_exp {
          _and: [pokemon_bool_exp!]
          _not: pokemon_bool_exp
          name: String_comparison_exp
          species: species_bool_exp
        }
        input species_bool_exp {
          name: String_comparison_exp
          pokemons: pokemon_bool_exp
        }
        input String_comparison_exp { _eq: String }
      GRAPHQL

      executor = Class.new do
        attr_reader :variables

        def execute(_query, variables:)
          @variables = variables
          { "data" => { "pokemon" => [{ "id" => 25, "name" => "pikachu" }] } }
        end
      end.new

      mod = GraphWeaver.parse(
        schema:,
        client: executor,
        query: "query($where: pokemon_bool_exp) { pokemon(where: $where) { id name } }",
      )

      # self-recursion and a cross-type cycle, built by hand
      where = mod::PokemonBoolExp.new(
        _and: [mod::PokemonBoolExp.new(name: mod::StringComparisonExp.new(_eq: "pikachu"))],
        _not: mod::PokemonBoolExp.new(species: mod::SpeciesBoolExp.new(
          pokemons: mod::PokemonBoolExp.new(name: mod::StringComparisonExp.new(_eq: "ditto")),
        )),
      )

      expect(mod.execute!(where:).pokemon.first.name).to eq "pikachu"
      expect(executor.variables).to eq(
        "where" => {
          "_and" => [{ "name" => { "_eq" => "pikachu" } }],
          "_not" => { "species" => { "pokemons" => { "name" => { "_eq" => "ditto" } } } },
        },
      )

      # plain hashes coerce through the same cycle
      mod.execute!(where: { _not: { name: { _eq: "mew" } } })
      expect(executor.variables).to eq("where" => { "_not" => { "name" => { "_eq" => "mew" } } })
    end

    it "executes a checked-in recursive filter end to end" do
      # the generated module is srb tc'd; the schema applies the filter
      where = FindPetsQuery::PetFilter.coerce(
        _and: [{ species: "DOG" }],
        _not: { name: "Brownie" },
      )

      expect(FindPetsQuery.execute!(where:).find_pets.map(&:name)).to eq %w[Shelby]
      expect(FindPetsQuery.execute!.find_pets.size).to eq 2 # no filter

      # unregistered scalar (Metadata): T.untyped pass-through, both ways
      shelby = FindPetsQuery.execute!(where: { metadata: { "color" => "brown" } }).find_pets.first
      expect(shelby&.metadata).to eq("color" => "brown")
    end

    it "omits optional variables from the wire when nil" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: <<~GRAPHQL,
          query($term: String = "el") {
            search(term: $term) {
              __typename
              ... on Named {
                name
              }
            }
          }
        GRAPHQL
      )

      names = mod.execute.data!.search.map(&:name)
      expect(names).to eq %w[Daniel Shelby] # server applied the "el" default
    end
  end

  describe "@skip / @include directives" do
    it "makes conditional fields nilable, whatever the schema says" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: <<~GRAPHQL,
          query WithPets($withPets: Boolean!) {
            person(id: 1) {
              name
              pets @include(if: $withPets) {
                name
              }
            }
          }
        GRAPHQL
      )

      included = mod.execute!(with_pets: true).person
      expect(included&.pets&.map(&:name)).to eq %w[Shelby Brownie]

      skipped = mod.execute!(with_pets: false).person
      expect(skipped&.name).to eq "Daniel"
      expect(skipped&.pets).to be_nil # absent from the wire, typed nilable
    end
  end

  describe "GraphWeaver.parse (dynamic mode)" do
    it "evals a module on the fly, deriving the name from the operation" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: "query People { people { name } }",
      )

      expect(mod.execute.data!.people.map(&:name)).to eq ["Daniel"]
    end

    it "derives the module name from a .graphql file" do
      # person.graphql's operation is anonymous, so this only works if
      # the name comes from the file name
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: File.expand_path("queries/person.graphql", __dir__),
      )

      expect(mod.execute(id: "1").data!.person&.name).to eq "Daniel"
    end

    it "parses anonymous raw query strings, defaulting the name" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: "query { people { name } }",
      )

      expect(mod.execute.data!.people.map(&:name)).to eq ["Daniel"]
    end

    it "still requires a deliberate name when generating files" do
      expect {
        described_class.generate(schema: Demo::Schema, query: "query { people { name } }")
      }.to raise_error(ArgumentError, /module_name/)
    end

    it "does not leak global constants" do
      GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: "query Leaky { people { name } }",
      )

      expect(defined?(::Leaky)).to be_nil
    end
  end

  describe "client resolution" do
    let(:mod) do
      GraphWeaver.parse(schema: Demo::Schema, query: "query People { people { name } }")
    end

    it "falls back to GraphWeaver.client, raising when unconfigured" do
      expect { mod.execute }.to raise_error(GraphWeaver::Error, /no client configured/)

      begin
        GraphWeaver.client = Demo::Schema
        expect(mod.execute.data!.people.map(&:name)).to eq ["Daniel"]
      ensure
        GraphWeaver.client = nil
      end
    end

    it "supports per-module override" do
      mod.client = Demo::Schema

      expect(mod.execute.data!.people.map(&:name)).to eq ["Daniel"]
    end
  end

  describe "GraphWeaver.execute (one-shot)" do
    it "runs a query in-process with variables" do
      result = GraphWeaver.execute!(
        Demo::Schema,
        "query($id: ID!) { person(id: $id) { name } }",
        id: "1",
      )

      expect(result.person&.name).to eq "Daniel"
    end

    it "execute returns the envelope, execute! the result" do
      query = "query($id: ID!) { person(id: $id) { name } }"

      expect(GraphWeaver.execute(Demo::Schema, query, id: "1")).to be_a GraphWeaver::Response
      expect(GraphWeaver.execute!(Demo::Schema, query, id: "1").person&.name).to eq "Daniel"
    end

    it "accepts graphql-cased variable keys" do
      result = GraphWeaver.execute!(
        Demo::Schema,
        'query($term: String!) { search(term: $term) { __typename ... on Named { name } } }',
        "term" => "el",
      )

      expect(result.search.map(&:name)).to eq %w[Daniel Shelby]
    end

    it "a schema-source one-shot is self-contained — the app default does not leak in" do
      recorded = []
      recorder = Class.new do
        define_method(:initialize) { |log| @log = log }
        define_method(:execute) do |query, variables:|
          @log << variables
          Demo::Schema.execute(query, variables:)
        end
      end

      begin
        GraphWeaver.client = recorder.new(recorded)
        result = GraphWeaver.execute!(
          Demo::Schema,
          "query($id: ID!) { person(id: $id) { name } }",
          id: "1",
        )

        expect(result.person&.name).to eq "Daniel"
        expect(recorded).to be_empty # ran in-process, not through the app default
      ensure
        GraphWeaver.client = nil
      end
    end

    it "a Client source runs through that client" do
      begin
        GraphWeaver.client = Class.new { def execute(*) = { "errors" => [{ "message" => "wrong" }] } }.new
        result = GraphWeaver.execute!(
          GraphWeaver.new(Demo::Schema),
          "query($id: ID!) { person(id: $id) { name } }",
          id: "1",
        )

        expect(result.person&.name).to eq "Daniel"
      ensure
        GraphWeaver.client = nil
      end
    end
  end
end
