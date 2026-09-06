
require "graph_weaver/testing" # FakeClient walks the same Selection module codegen does

require_relative "generated/add_pet_mutation"
require_relative "generated/adopt_mutation"
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

  it "generates byte-identical source for the same inputs" do
    # the checked-in-parity spec above pins determinism ACROSS processes; this
    # pins it across calls, where a generator that leaked state between runs
    # (caches, collected requires, hoisted names) would drift
    query = File.read(File.expand_path("queries/search.graphql", __dir__))
    args = { schema: Demo::Schema, query:, module_name: "SearchQuery" }

    expect(described_class.generate(**args)).to eq(described_class.generate(**args))
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
      def execute(_query, variables:, operation_name: nil)
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
      }.to raise_error(GraphWeaver::Error, /Tricky\.serialize.*every struct defines/)
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

  it "names the file and position of each validation error" do
    expect {
      described_class.generate(schema: Demo::Schema, module_name: "Bad", path: "queries/typo.graphql",
        query: "query { person(id: 1) { nmae } }")
    }.to raise_error(GraphWeaver::ValidationError, %r{queries/typo\.graphql:1:25 Field 'nmae'})
  end

  describe "the generated module" do
    let(:response) { PersonQuery.execute(id: "1") }
    let(:result) { response.data! }
    let(:person) { result.person }

    it "freezes QUERY (frozen_string_literal covers the heredoc)" do
      expect(PersonQuery::QUERY).to be_frozen
    end

    it "emits the operation's name beside QUERY, nil when the document is anonymous" do
      expect(SearchQuery::OPERATION_NAME).to eq "Search"
      expect(PersonQuery::OPERATION_NAME).to be_nil
    end

    # the client slot stays duck-typed: a graphql-ruby schema class takes
    # operation_name: as a kwarg, so widening the contract didn't shut it out
    it "runs against a bare graphql-ruby schema class in the client slot" do
      expect(SearchQuery.execute(Demo::Schema, term: "el").data!.search).not_to be_empty
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
        def execute(_query, variables:, operation_name: nil)
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
        def execute(_query, variables:, operation_name: nil) = { "errors" => [{ "message" => "boom" }] }
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

    # the sig on Result.from_h fires before the struct's own rescue, so these
    # used to escape as raw Sorbet TypeErrors
    {
      "a non-object data" => { "data" => "nope" },
      "an object for errors" => { "errors" => { "message" => "boom" } },
      "an array of strings for errors" => { "errors" => ["boom"] },
      "non-object extensions" => { "extensions" => "cost" },
    }.each do |label, body|
      it "brands #{label} under the error umbrella" do
        expect { PersonQuery.from_response(body) }.to raise_error(GraphWeaver::TypeError)
      end
    end

    it "brands a body that isn't an object at all" do
      # String#[] answers "data" with nil, so this used to deserialize to an
      # empty envelope rather than saying the server misbehaved
      body = Object.new.tap { |o| o.define_singleton_method(:to_h) { "<html>502</html>" } }
      expect { PersonQuery.from_response(body) }.to raise_error(GraphWeaver::TypeError, /must be an object/)
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

    it "requires the dispatched __typename to be unconditional" do
      # from_h reads data.fetch("__typename") on every response
      expect {
        GraphWeaver.parse(
          schema: Demo::Schema,
          query: 'query($d: Boolean!) { search(term: "x") { __typename @skip(if: $d) ' \
            "... on Pet { species } ... on Person { email } } }",
        )
      }.to raise_error(ArgumentError, /not under @skip/)
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

    it "narrows on the tag when __typename is selected alongside the condition" do
      # selecting __typename means a non-match is never an empty object, so
      # emptiness can't tell a Pet from a Person. Person.email is nullable, so
      # the mis-cast used to be silent rather than a raise.
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        query: 'query { search(term: "el") { __typename ... on Person { email } } }',
      )

      results = mod.from_response!("data" => { "search" => [
        { "__typename" => "Person", "email" => "d@e.f" },
        { "__typename" => "Pet" },
      ] }).search

      expect(results&.map(&:class)).to eq [mod::Result::Person, NilClass]
      expect(results&.first&.email).to eq "d@e.f"
    end

    it "narrows an interface-typed field on the tag too" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        query: "query { named(name: \"x\") { __typename ... on Pet { species } } }",
      )

      expect(mod.from_response!("data" => { "named" => { "__typename" => "Person" } }).named).to be_nil
      expect(mod.from_response!("data" => { "named" => { "__typename" => "Pet", "species" => "DOG" } }).named)
        .to be_a(mod::Result::Pet)
    end
  end

  describe "interface-typed fields" do
    it "dispatches to member structs like unions" do
      pet = NamedQuery.execute(name: "Shelby").data!.named
      person = NamedQuery.execute(name: "Daniel").data!.named

      expect(pet).to be_a NamedQuery::Result::Named::Pet
      expect(pet.name).to eq "Shelby" # interface field, gathered into every member
      expect(pet.species).to eq NamedQuery::Result::Named::Pet::Species::Dog
      # the query names no Person fields, so Person shares the catch-all with
      # every other Named implementation — the interface-level fields still cast
      expect(person).to be_a NamedQuery::Result::Named::Other
      expect(person.name).to eq "Daniel"
    end
  end

  describe "mutations and typed variables" do
    it "executes mutations with typed kwargs, serializing enum variables" do
      result = AddPetMutation.execute(name: "Rex", species: AddPetMutation::Species::Dog).data!

      expect(result.add_pet.name).to eq "Rex"
      # one Species class per module: the value read out of the result is the
      # very one execute takes back in
      expect(result.add_pet.species).to eq AddPetMutation::Species::Dog
      expect(AddPetMutation.execute(name: "Rex", species: result.add_pet.species).data!.add_pet.species)
        .to eq AddPetMutation::Species::Dog
    end

    it "accepts wire strings for enums inside a list variable, like a scalar one" do
      schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
        enum Sort { ASC DESC }
        type Query { items(sort: [Sort!], one: Sort): [String!]! }
      GRAPHQL
      sent = nil
      executor = Class.new do
        define_method(:execute) do |_query, variables:, operation_name: nil|
          sent = variables
          { "data" => { "items" => [] } }
        end
      end.new

      mod = GraphWeaver.parse(schema:, query: "query Q($sort: [Sort!], $one: Sort) { items(sort: $sort, one: $one) }")
      mod.execute!(executor, sort: ["DESC", mod::Sort::Asc], one: "ASC")

      expect(sent).to eq("sort" => %w[DESC ASC], "one" => "ASC")
    end

    it "refuses enum values that would share one Ruby constant" do
      schema = GraphQL::Schema.from_definition("enum E { active ACTIVE }\ntype Query { e: E }")

      # T::Enum raises "Enum values must be assigned to constants" at LOAD time
      expect { GraphWeaver::Codegen.generate(schema:, query: "query Q { e }", module_name: "Q") }
        .to raise_error(GraphWeaver::Error, /ACTIVE and active both become the constant Active/)
    end

    it "leaves values that merely look alike alone" do
      schema = GraphQL::Schema.from_definition(
        "enum E { AB A_B IN_PROGRESS INPROGRESS }\ntype Query { e: E }",
      )
      src = GraphWeaver::Codegen.generate(schema:, query: "query Q { e }", module_name: "Q")

      expect(src).to include("Ab = new", "AB = new", "InProgress = new", "Inprogress = new")
    end

    it "types a result enum and the same variable enum as one class" do
      # separate classes for one GraphQL enum failed both srb tc and the runtime
      # sig on the obvious move: read a value out, feed it back in
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        client: Demo::Schema,
        query: "mutation($species: Species!) { addPet(name: \"Rex\", species: $species) { species } }",
      )

      species = mod.execute!(species: mod::Species::Dog).add_pet.species
      expect(species).to be_a(mod::Species)
      expect(mod.execute!(species:).add_pet.species).to eq species
    end

    it "hints when a result field is called by its camelCase wire name" do
      result = AddPetMutation.execute!(name: "Rex", species: "DOG")

      expect { result.addPet }.to raise_error(NoMethodError, /use 'add_pet'/)
      expect { result.add_pet.bogusField }.to raise_error(NoMethodError) do |e|
        expect(e.message).not_to include("use") # nothing to hint at
      end
    end

    it "suggests the nearest prop for a typo, in either casing" do
      result = AddPetMutation.execute!(name: "Rex", species: "DOG")

      expect { result.addPt }.to raise_error(NoMethodError, /did you mean 'add_pet'\?/)
      expect { result.add_pt }.to raise_error(NoMethodError, /did you mean 'add_pet'\?/)
      expect { result.add_pet.nmae }.to raise_error(NoMethodError, /did you mean 'name'\?/)
    end

    it "flattens a single input-object variable into typed kwargs" do
      pet = AdoptMutation.execute!(name: "Rex", species: AdoptMutation::Species::Dog).adopt
      expect(pet.name).to eq "Rex"
      expect(pet.species).to eq AdoptMutation::Species::Dog

      # enums accept their wire value; optional fields ride along when
      # set, stay off the wire when nil
      expect(AdoptMutation.execute!(name: "Rex", species: "DOG", nickname: "Rexy").adopt.name).to eq "Rexy"

      # bad shapes fail loudly at the boundary
      expect { AdoptMutation.execute!(species: "DOG") }.to raise_error(ArgumentError)
      expect { AdoptMutation.execute!(name: "Rex", species: "DRAGON") }.to raise_error(GraphWeaver::InputError)
    end

    describe "@oneOf inputs" do
      # nothing before serialize can enforce this: every @oneOf field is
      # nullable, so the struct's own types accept zero or many
      let(:mod) do
        schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
          input Ref @oneOf { id: ID name: String }
          type Query { thing(ref: Ref!): String }
        GRAPHQL
        GraphWeaver.parse(schema:, query: "query Q($ref: Ref!) { thing(ref: $ref) }")
      end

      it "puts the one supplied field on the wire" do
        expect(mod::Ref.coerce(id: "1").serialize).to eq("id" => "1")
      end

      it "rejects zero or many, naming what was supplied" do
        expect { mod::Ref.coerce({}).serialize }.to raise_error(GraphWeaver::InputError, /got none/)
        expect { mod.execute(nil, id: "1", name: "x") }
          .to raise_error(GraphWeaver::InputError, /got id, name/)
      end
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
      nicknamed = AdoptMutation::AdoptionInput.new(
        name: "Rex",
        species: AdoptMutation::Species::Dog,
        nickname: "Rexy",
      )
      expect(nicknamed.serialize).to include("nickname" => "Rexy", "species" => "DOG")
      expect(nicknamed.to_h).to eq nicknamed.serialize

      bare = AdoptMutation::AdoptionInput.new(name: "Rex", species: AdoptMutation::Species::Dog)
      expect(bare.serialize).not_to have_key("nickname")

      # coerce: underscored Symbol/String keys, enums as wire values
      coerced = AdoptMutation::AdoptionInput.coerce({ "name" => "Rex", species: "CAT" })
      expect(coerced.species).to eq AdoptMutation::Species::Cat

      # a typo'd key raises with a hint instead of silently dropping
      expect { AdoptMutation::AdoptionInput.coerce({ name: "Rex", species: "CAT", nickame: "Rexy" }) }
        .to raise_error(GraphWeaver::InputError, /nickame \(did you mean 'nickname'\?\)/)
    end

    it "raises a branded, structured InputError for bad input (rescue for a 422)" do
      # every bad-input shape lands under one rescuable error…
      bad = {
        "unknown key" => -> { AdoptMutation::AdoptionInput.coerce(name: "Rex", species: "CAT", nickame: "x") },
        "out-of-range enum" => -> { AdoptMutation::AdoptionInput.coerce(name: "Rex", species: "DRAGON") },
        "missing required field" => -> { AdoptMutation::AdoptionInput.coerce(species: "CAT") },
        "wrong-typed field" => -> { AdoptMutation::AdoptionInput.coerce(name: 123, species: "CAT") },
      }
      bad.each_value do |build|
        expect(&build).to raise_error(GraphWeaver::InputError)
        expect(&build).to raise_error(GraphWeaver::Error) # under the umbrella
      end

      # …and it carries a machine-readable to_h for the response body
      error = begin
        AdoptMutation::AdoptionInput.coerce(name: "Rex", species: "CAT", nickame: "x")
      rescue GraphWeaver::InputError => e
        e
      end
      expect(error.to_h).to include("error" => "GraphWeaver::InputError")
      expect(error.to_h["struct"]).to end_with("AdoptionInput")
      expect(error.to_h["field"]).to include("nickame")

      # a nested bad key reports the nested input type, not the outer one
      expect { FindPetsQuery::PetFilter.coerce(_and: [{ speces: "DOG" }]) }
        .to raise_error(GraphWeaver::InputError, /PetFilter.*speces/m)
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

        def execute(_query, variables:, operation_name: nil)
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
        define_method(:execute) do |query, variables:, operation_name: nil|
          @log << variables
          Demo::Schema.execute(query, variables:, operation_name:)
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
        GraphWeaver.client = Class.new { def execute(*, **) = { "errors" => [{ "message" => "wrong" }] } }.new
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

  describe "extend T::Sig emission (GraphWeaver.extend_t_sig)" do
    after { GraphWeaver.extend_t_sig = nil } # restore the auto-detect default

    def source
      described_class.generate(schema: Demo::Schema, query: "query People { people { name } }")
    end

    it "emits by default when T::Sig isn't globally injected (standalone safety)" do
      expect(source).to include("extend T::Sig")
    end

    it "omits it when set false — rely on a global `class Module; include T::Sig`" do
      GraphWeaver.extend_t_sig = false
      expect(source).not_to include("extend T::Sig")
    end

    it "auto-detects a global T::Sig injection and skips the redundant extend" do
      allow(GraphWeaver).to receive(:global_tsig?).and_return(true)
      expect(source).not_to include("extend T::Sig")
    end

    it "an explicit setting overrides auto-detect" do
      allow(GraphWeaver).to receive(:global_tsig?).and_return(true)
      GraphWeaver.extend_t_sig = true
      expect(source).to include("extend T::Sig")
    end
  end

  describe "per-field scalar override (register_scalar with a Type.field coordinate)" do
    let(:schema) do
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        scalar ISO8601DateTime
        type Query { event: Event }
        type Event { startsAt: ISO8601DateTime! createdOn: ISO8601DateTime! }
      GRAPHQL
    end

    after { GraphWeaver.reset_scalars! }

    it "maps the same scalar to different Ruby types across fields in one query" do
      GraphWeaver.register_scalar("ISO8601DateTime", Time, cast: :iso8601, requires: "time")
      GraphWeaver.register_scalar("Event.createdOn", Date, cast: :iso8601, requires: "date")

      src = described_class.generate(schema:, query: "query E { event { startsAt createdOn } }")
      expect(src).to include("const :starts_at, Time")   # the scalar-name default
      expect(src).to include("const :created_on, Date")  # the field override wins
    end

    it "deserializes each field to its own Ruby type end to end (client-scoped)" do
      executor = Class.new do
        def execute(_query, variables:, operation_name: nil)
          { "data" => { "event" => { "startsAt" => "2020-01-02T03:04:05Z", "createdOn" => "2021-06-15" } } }
        end
      end.new
      client = GraphWeaver::Client.new(schema, transport: executor)
      client.register_scalar("ISO8601DateTime", Time, cast: :iso8601, requires: "time")
      client.register_scalar("Event.createdOn", Date, cast: :iso8601, requires: "date")

      event = client.execute!("query E { event { startsAt createdOn } }").event
      expect(event.starts_at).to be_a(Time)
      expect(event.created_on).to be_a(Date)
    end

    it "validates the coordinate names a real scalar field" do
      client = GraphWeaver::Client.new(schema)
      expect { client.register_scalar("Event.nope", Date) }
        .to raise_error(GraphWeaver::Error, /no scalar field/)
    end
  end

  describe "@skip / @include on a fragment" do
    it "nilables the fields reached through a conditional inline fragment" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        query: 'query Q($s: Boolean!) { people { id ... on Person @skip(if: $s) { name } } }',
      )

      # name is String! in the schema, but the whole block may be skipped
      person = mod.from_response!("data" => { "people" => [{ "id" => "1" }] }).people.first
      expect(person&.name).to be_nil
    end

    it "nilables the fields reached through a conditional named spread" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        query: <<~GRAPHQL,
          query Q($s: Boolean!) { people { id ...Names @include(if: $s) } }
          fragment Names on Person { name }
        GRAPHQL
      )

      person = mod.from_response!("data" => { "people" => [{ "id" => "1" }] }).people.first
      expect(person&.name).to be_nil
    end

    it "keeps a field non-null when some other selection of it is unconditional" do
      mod = GraphWeaver.parse(
        schema: Demo::Schema,
        query: 'query Q($s: Boolean!) { people { name ... on Person @skip(if: $s) { name } } }',
      )

      expect { mod.from_response!("data" => { "people" => [{}] }) }.to raise_error(GraphWeaver::TypeError)
      expect(mod.from_response!("data" => { "people" => [{ "name" => "D" }] }).people.first&.name).to eq "D"
    end

    it "refuses to narrow when the fragment itself is conditional" do
      # the guard has to see the directive on the fragment, not just on fields
      expect {
        GraphWeaver.parse(
          schema: Demo::Schema,
          query: 'query Q($s: Boolean!) { search(term: "el") { ... on Pet @skip(if: $s) { name } } }',
        )
      }.to raise_error(GraphWeaver::Error, /at least one field not under @skip/)
    end

    it "keeps FakeClient's fabricated data castable through a conditional fragment" do
      # FakeClient walks the same Selection module — it must keep fabricating
      # the fields codegen still types, conditional or not
      query = 'query Q($s: Boolean!) { people { id ... on Person @skip(if: $s) { name } } }'
      mod = GraphWeaver.parse(schema: Demo::Schema, query:)
      fake = GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema, seed: 1)

      person = mod.from_response!(fake.execute(query, variables: { "s" => false })).people.first
      expect(person&.name).to be_a(String)
    end
  end

  describe "abstract selections are query-driven" do
    # an interface/union with many implementations — the shape that made
    # codegen emit a struct per schema member instead of per named condition
    members = (1..40).map { |n| "Thing#{n}" }
    let(:schema) do
      GraphQL::Schema.from_definition(<<~GRAPHQL)
        interface Node { id: ID! }
        #{members.map { |name| "type #{name} implements Node { id: ID! label: String! }" }.join("\n")}
        type Query { node(id: ID!): Node }
      GRAPHQL
    end
    let(:query) do
      'query Q($id: ID!) { node(id: $id) { __typename ... on Thing1 { label } ... on Thing2 { label } } }'
    end

    it "emits one struct per named condition plus one catch-all, whatever the schema's size" do
      src = described_class.generate(schema:, query:, module_name: "Q")

      # Result + Thing1 + Thing2 + Other: bounded by the query, not by the 40
      # types that implement Node
      expect(src.scan(/< T::Struct/).size).to be <= 4
      expect(src).to include("class Thing1 < T::Struct", "class Thing2 < T::Struct", "class Other < T::Struct")
      expect(src).not_to include("class Thing3 < T::Struct")
    end

    it "deserializes a member the query never named into the catch-all" do
      mod = GraphWeaver.parse(schema:, query:)
      node = mod.from_response!("data" => { "node" => { "__typename" => "Thing7", "id" => "x" } }).node

      expect(node).to be_a(mod::Result::Node::Other)
      expect(node.__typename).to eq "Thing7"
    end

    it "absorbs a union member the schema grew after generation" do
      v1 = <<~GRAPHQL
        union Feed = Post | Photo
        type Post { title: String! }
        type Photo { url: String! }
        type Query { feed: [Feed!]! }
      GRAPHQL
      mod = GraphWeaver.parse(
        schema: GraphQL::Schema.from_definition(v1),
        query: "query Q { feed { __typename ... on Post { title } ... on Photo { url } } }",
      )

      # upstream added `Video` to the union — a non-breaking schema change. The
      # fields this query selects are still valid, so the response must bend.
      item = mod.from_response!("data" => { "feed" => [{ "__typename" => "Video" }] }).feed.first

      expect(item).to be_a(mod::Result::Feed::Other)
      expect(item.__typename).to eq "Video"
    end
  end

  describe "union member-type dedup" do
    # The same union selected two ways collapses to one Ruby type family, so a
    # consumer gets a single exhaustive `case ... T.absurd`, not per-field families.
    def source(sdl, query)
      described_class.generate(schema: GraphQL::Schema.from_definition(sdl), query:)
    end

    let(:sdl) do
      <<~GRAPHQL
        union Contact = Email | Phone
        type Email { address: String! label: String! }
        type Phone { number: String! }
        type User { primary: Contact secondary: Contact! }
        type Query { user: User }
      GRAPHQL
    end
    let(:sel) { "{ __typename ... on Email { address } ... on Phone { number } }" }

    it "collapses the same union selected identically into one type family" do
      src = source(sdl, "query D { user { primary #{sel} secondary #{sel} } }")
      expect(src.scan(/module \w*Contact\b/).uniq).to eq(["module Contact"])
      expect(src).to include("const :primary, T.nilable(Contact::Type)")
      expect(src).to include("const :secondary, Contact::Type") # shared type, wrapper differs
    end

    it "keeps distinct types when the selections differ" do
      differ = "query D { user { primary #{sel} " \
               "secondary { __typename ... on Email { address label } ... on Phone { number } } } }"
      expect(source(sdl, differ).scan(/module \w*Contact\b/).uniq.size).to eq(2)
    end

    it "shares the core across a list and a single field (wrappers differ)" do
      list_sdl = sdl.sub("secondary: Contact!", "secondary: [Contact!]!")
      src = source(list_sdl, "query D { user { primary #{sel} secondary #{sel} } }")
      expect(src.scan(/module \w*Contact\b/).uniq.size).to eq(1)
      expect(src).to include("const :secondary, T::Array[Contact::Type]")
    end

    it "deserializes both fields into one member family — one dispatch handles both" do
      mod = Module.new
      mod.module_eval(source(sdl, "query D { user { primary #{sel} secondary #{sel} } }"))
      user = mod.const_get(:D).const_get(:Result).const_get(:User)
      u = user.from_h(
        "primary" => { "__typename" => "Email", "address" => "a" },
        "secondary" => { "__typename" => "Phone", "number" => "n" },
      )
      expect(u.primary).to be_a(user::Contact::Email)
      expect(u.secondary).to be_a(user::Contact::Phone)

      render = ->(opt) { opt.is_a?(user::Contact::Email) ? :email : :phone }
      expect([u.primary, u.secondary].map(&render)).to eq(%i[email phone])
    end
  end

  it "rejects a document holding more than one operation" do
    query = "query A { people { name } } query B { people { id } }"

    expect { GraphWeaver::Codegen.generate(schema: Demo::Schema, query:, module_name: "Q") }
      .to raise_error(GraphWeaver::Error, /2 operations \('A', 'B'\)/)
  end

  describe "hostile result keys" do
    let(:schema) do
      GraphQL::Schema.from_definition("type Query { person: Person }\ntype Person { name: String! class: String! }")
    end

    def generate(selection)
      GraphWeaver::Codegen.generate(schema:, query: "query Q { person { #{selection} } }", module_name: "Q")
    end

    it "rejects two result keys that underscore to the same prop" do
      expect { generate("name Name: name") }
        .to raise_error(GraphWeaver::Error, /both map to the prop 'name'/)
    end

    it "rejects a field whose prop is a method every struct already answers" do
      # T::Props refuses to redefine #class, so the file would raise at require
      expect { generate("class") }.to raise_error(GraphWeaver::Error, /alias it in the query/)
    end

    it "accepts the aliased spelling the error suggests" do
      expect(generate("classValue: class")).to include("const :class_value, String")
    end
  end

  it "rejects two variables that underscore to the same kwarg" do
    schema = GraphQL::Schema.from_definition("type Query { thing(userId: ID, alt: ID): String }")
    query = "query($userId: ID, $user_id: ID) { thing(userId: $userId, alt: $user_id) }"

    expect { GraphWeaver::Codegen.generate(schema:, query:, module_name: "Q") }
      .to raise_error(GraphWeaver::Error, /rename one/)
  end
end
