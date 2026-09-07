# Manual integration checks against Hasura's PokeAPI GraphQL endpoint
# (https://beta.pokeapi.co/graphql/v1beta — no auth needed). This is the
# field-test schema: 4,000+ snake_case types and a fully recursive
# bool_exp filter surface — the two things that broke 0.1.0. Run with:
#
#   make integration
describe "PokeAPI (Hasura)", :integration do
  let(:executor) { GraphWeaver::Transport::HTTP.new("https://beta.pokeapi.co/graphql/v1beta") }

  let(:schema) { integration_schema(:pokeapi, executor) }

  it "generates snake_case types and filters through a recursive bool_exp variable" do
    pokemon_query = GraphWeaver.parse(
      schema:,
      client: executor,
      query: <<~GRAPHQL,
        query($where: pokemon_v2_pokemon_bool_exp) {
          pokemon_v2_pokemon(where: $where, limit: 5, order_by: { id: asc }) {
            id
            name
          }
        }
      GRAPHQL
    )

    # snake_case type names camelize into valid constants
    expect(pokemon_query.const_defined?(:PokemonV2PokemonBoolExp)).to be true

    # a nested recursive filter (_and/_not), built from a plain hash
    where = pokemon_query::PokemonV2PokemonBoolExp.coerce(
      _and: [{ name: { _like: "%chu" } }],
      _not: { name: { _eq: "raichu" } },
    )

    names = pokemon_query.execute!(where:).pokemon_v2_pokemon.map(&:name)
    expect(names).to eq %w[pikachu pichu]
  end

  it "passes unregistered scalars (jsonb) through untyped" do
    # execute! takes a client-or-schema positionally; kwargs are query variables,
    # so the transport rides in on the client rather than beside it
    sprites = GraphWeaver.run!(
      GraphWeaver.new(schema, transport: executor),
      "query { pokemon_v2_pokemonsprites(limit: 1, order_by: { id: asc }) { sprites } }",
    ).pokemon_v2_pokemonsprites.first&.sprites

    expect(sprites).to be_a Hash # jsonb arrives as plain data
  end
end
