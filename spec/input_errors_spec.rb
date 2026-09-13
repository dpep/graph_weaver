# typed: false
require "json"
require "logger"
require "stringio"

require_relative "generated/adopt_mutation"
require_relative "generated/find_pets_query"
require_relative "generated/person_query"

# InputError as a machine-readable value: which of a closed set of things
# went wrong (#kind), where (#path, #coordinate), with what (#value,
# #details). The client half is raised before the request leaves; the
# server half arrives as a GraphQLError and becomes the same value object.
describe "input errors" do
  def refusal
    yield
    raise "expected a GraphWeaver::InputError"
  rescue GraphWeaver::InputError => e
    e
  end

  describe "the vocabulary" do
    it "is closed, and every kind is a Symbol" do
      expect(GraphWeaver::InputError::KINDS).to eq %i[
        type_mismatch unparseable not_a_member missing unknown out_of_range invalid_format refused
      ].to_set
    end

    it "refuses a kind outside it rather than inventing a ninth" do
      expect { GraphWeaver::InputError.new("nope", kind: :sideways) }
        .to raise_error(ArgumentError, /sideways.*not an input kind/)
    end

    it "defaults to :refused — the honest fallback, never a guess" do
      expect(GraphWeaver::InputError.new("nope").kind).to eq :refused
    end

    # a detail key with no declared type is silently dropped from a server's
    # error, so adding one to DETAILS has to add its type in the same breath
    it "declares a type for every detail key a server may state" do
      declared = GraphWeaver::Internal::ServerInput.const_get(:DETAIL_TYPES).keys.map(&:to_sym)

      expect(declared).to match_array GraphWeaver::InputError::DETAILS
    end

    # docs/i18n.md's recipe splats #details straight into I18n.t, so a detail
    # key I18n reserves raises I18n::ReservedInterpolationKey there rather
    # than translating — which `:format` did, on the page's own headline kind.
    it "names no detail key I18n reserves for itself" do
      require "i18n"

      expect(GraphWeaver::InputError::DETAILS & I18n::RESERVED_KEYS).to be_empty
    end
  end

  describe "client-side: the path is rooted at the variable" do
    it "reaches the field inside an input object" do
      error = refusal { AdoptMutation.execute(input: { name: "Rex", species: "LIZARD" }) }

      expect(error.kind).to eq :not_a_member
      expect(error.path).to eq ["input", "species"]
      expect(error.coordinate).to eq "AdoptionInput.species"
      expect(error.details[:members]).to eq %w[CAT DOG]
      expect(error.value).to eq "LIZARD"
      expect(error.field).to eq "species"
    end

    it "walks intermediate keys and list indices, which the message never showed" do
      error = refusal { FindPetsQuery.execute(where: { _and: [{ _not: { species: "LIZARD" } }] }) }

      expect(error.path).to eq ["where", "_and", 0, "_not", "species"]
      expect(error.coordinate).to eq "PetFilter.species"
    end

    # The index above rides on the nested input's own InputError. A list of
    # LEAVES has no nested struct: every leaf coercer raises a branded plain
    # ArgumentError/TypeError/KeyError, which the index wrapper used not to
    # catch — so a list of input objects was the one shape where #path held.
    describe "a list of leaves" do
      lists = GraphWeaver.parse(schema: GraphQL::Schema.from_definition(<<~GRAPHQL), query: <<~QUERY)
        enum Sp { CAT DOG }
        type Query { ok(ids: [Int!], names: [String!], kinds: [Sp!], grid: [[Int!]!]): Boolean }
        schema { query: Query }
      GRAPHQL
        query Lists($ids: [Int!], $names: [String!], $kinds: [Sp!], $grid: [[Int!]!]) {
          ok(ids: $ids, names: $names, kinds: $kinds, grid: $grid)
        }
      QUERY

      it "reaches the element that refused, for every leaf kind" do
        expect(refusal { lists.execute(ids: [1, 2, "x"]) })
          .to have_attributes(kind: :unparseable, path: ["ids", 2], value: "x")
        expect(refusal { lists.execute(names: ["a", 7]) }).to have_attributes(kind: :type_mismatch, path: ["names", 1])
        expect(refusal { lists.execute(kinds: %w[CAT LIZARD]) })
          .to have_attributes(kind: :not_a_member, path: ["kinds", 1], details: { members: %w[CAT DOG] })
      end

      # an index is a position, not a field — "2" is nothing a form can highlight
      it "still names the list itself as #field" do
        expect(refusal { lists.execute(ids: [1, 2, "x"]) }).to have_attributes(path: ["ids", 2], field: "ids")
      end

      it "reaches both indices of a list of lists" do
        expect(refusal { lists.execute(grid: [[1, 2], [3, "x"]]) })
          .to have_attributes(kind: :unparseable, path: ["grid", 1, 1])
      end

      # the inner .map was unguarded, so this came out as a raw NoMethodError
      # under kind: :refused — which reads as a graph_weaver bug rather than
      # as "element 1 should have been a list"
      it "names the element that wasn't a list at all" do
        expect(refusal { lists.execute(grid: [[1, 2], nil]) }).to have_attributes(path: ["grid", 1])
        expect(refusal { lists.execute(grid: [1, 2]) }).to have_attributes(path: ["grid", 0])
      end
    end

    # "supply exactly one field" is the wrong sentence when exactly one field
    # is what the caller supplied — and a form had nothing to highlight, since
    # all three @oneOf refusals carried an empty path
    it "says which @oneOf field was null, rather than counting the fields" do
      mod = GraphWeaver.parse(schema: GraphQL::Schema.from_definition(<<~GRAPHQL), query: <<~QUERY)
        input Ref @oneOf { id: ID name: String }
        type Query { thing(ref: Ref!): String }
      GRAPHQL
        query OneOf($ref: Ref!) { thing(ref: $ref) }
      QUERY

      error = refusal { mod.execute(client: nil, ref: { id: nil }) }

      expect(error.kind).to eq :missing
      expect(error.path).to eq ["ref", "id"]
      expect(error.coordinate).to eq "Ref.id"
      expect(error.message).to include "id was null"

      # the count is still the count when the count is what's wrong
      expect(refusal { mod.execute(client: nil, ref: {}) })
        .to have_attributes(kind: :refused, message: /got none/)
      expect(refusal { mod.execute(client: nil, ref: { id: "1", name: "x" }) })
        .to have_attributes(kind: :refused, message: /got id, name/)
    end

    it "names a required field that wasn't supplied" do
      error = refusal { AdoptMutation.execute(input: { name: "Rex" }) }

      expect(error.kind).to eq :missing
      expect(error.path).to eq ["input", "species"]
      expect(error.coordinate).to eq "AdoptionInput.species"
      expect(error.value).to be_nil
      expect(error.details).to eq({})
    end

    it "names a key the input type doesn't define, with the spellcheck as data" do
      error = refusal { AdoptMutation.execute(input: { name: "Rex", speceis: "DOG" }) }

      expect(error.kind).to eq :unknown
      expect(error.path).to eq ["input", "speceis"]
      expect(error.details[:suggestion]).to eq "species"
      # the type defines no such field, so there is no coordinate to give
      expect(error.coordinate).to be_nil
      # nor a value: the key is what was wrong, and it owns no slot to hold one
      expect(error.value).to be_nil
      expect(error.to_h).not_to have_key "value"
    end

    it "tells a wrong type from text that doesn't parse" do
      mismatch = refusal { AdoptMutation.execute(input: { name: 42, species: "DOG" }) }
      expect(mismatch.kind).to eq :type_mismatch
      expect(mismatch.details[:type]).to eq "String"
      expect(mismatch.value).to eq 42
      expect(mismatch.coordinate).to eq "AdoptionInput.name"

      unparseable = refusal do
        AdoptMutation.execute(input: { name: "Rex", species: "DOG", birthday: "not-a-date" })
      end
      expect(unparseable.kind).to eq :unparseable
      expect(unparseable.details[:type]).to eq "Date"
      expect(unparseable.path).to eq ["input", "birthday"]
    end

    it "carries a top-level scalar variable with no coordinate to give" do
      error = refusal do
        GraphWeaver::Coerce.variable("count", "Compute", "lots") { |v| GraphWeaver::Coerce.integer(v) }
      end

      expect(error.kind).to eq :unparseable
      expect(error.path).to eq ["count"]
      expect(error.value).to eq "lots"
      expect(error.details[:type]).to eq "Int"
      # a variable is not a schema coordinate — nothing in the schema is named "$count"
      expect(error.coordinate).to be_nil
    end

    it "puts a Hash where an Int goes under :type_mismatch, not :unparseable" do
      error = refusal do
        GraphWeaver::Coerce.variable("count", "Compute", { a: 1 }) { |v| GraphWeaver::Coerce.integer(v) }
      end

      expect(error.kind).to eq :type_mismatch
    end

    # an app's `cast:` — Date.iso8601, Money.parse — raises whatever it likes,
    # and Ruby's own convention says which: TypeError is a wrong class,
    # ArgumentError wrong content. Both used to arrive as :unparseable, which
    # sends a form to re-validate text that was never text.
    describe "a registration's own cast:" do
      after { GraphWeaver::Codegen.reset_scalars! }

      let(:adopt) do
        GraphWeaver.register_scalar("Date", Date, cast: :iso8601, serialize: :iso8601)
        GraphWeaver.parse(
          schema: Demo::Schema, client: Demo::Schema,
          query: "mutation Probe($input: AdoptionInput!) { adopt(input: $input) { name } }",
        )
      end

      def adopting(birthday)
        adopt.execute(input: { name: "Rex", species: "DOG", birthday: })
      end

      it "calls a wrong class a type mismatch, and carries the value" do
        expect(refusal { adopting(5) }).to have_attributes(
          kind: :type_mismatch, path: ["input", "birthday"],
          coordinate: "AdoptionInput.birthday", value: 5, details: { type: "Date" },
        )
      end

      it "calls wrong content unparseable, as the built-in Date does" do
        expect(refusal { adopting("nope") }).to have_attributes(
          kind: :unparseable, path: ["input", "birthday"], details: { type: "Date" },
        )
      end
    end

    it "routes a value through filter_parameters, as the message already is" do
      error = refusal do
        GraphWeaver::Coerce.variable("password", "Login", "hunter2") { |v| GraphWeaver::Coerce.integer(v) }
      end

      expect(error.value).to eq GraphWeaver::FILTERED
      expect(error.to_h["value"]).to eq GraphWeaver::FILTERED
      expect(JSON.generate(error.to_h)).not_to include "hunter2"
    end

    it "scrubs a filtered key nested inside the value it reports" do
      error = refusal { AdoptMutation.execute(input: "not a hash") }
      expect(error.value).to eq "not a hash"

      nested = refusal do
        GraphWeaver::Coerce.variable("creds", "Login", { "token" => "t0ps3cret" }) { |v| GraphWeaver::Coerce.string(v) }
      end
      expect(nested.value).to eq({ "token" => GraphWeaver::FILTERED })
      expect(nested.to_h["value"]).to eq({ "token" => GraphWeaver::FILTERED })
    end

    it "serializes to a JSON-safe hash for a 422 body" do
      error = refusal { AdoptMutation.execute(input: { name: "Rex", species: "LIZARD" }) }
      hash = error.to_h

      expect(hash).to include(
        "error" => "GraphWeaver::InputError",
        "kind" => "not_a_member",
        "path" => ["input", "species"],
        "coordinate" => "AdoptionInput.species",
        "field" => "species",
        "value" => "LIZARD",
        "details" => { "members" => %w[CAT DOG] },
      )
      expect(hash["message"]).to include "LIZARD"
      expect { JSON.generate(hash) }.not_to raise_error
    end

    # `render json: e.to_h` is the documented idiom, and the two refusals
    # Coerce.finite/whole exist for are exactly the values JSON can't spell —
    # so the crash landed inside the error handler and a 422 became a 500
    it "keeps #value JSON-generatable for the non-finite numbers it refuses" do
      nan = refusal { GraphWeaver::Coerce.variable("rating", "T", Float::NAN) { |v| GraphWeaver::Coerce.float(v) } }
      expect(nan.value).to eq "NaN"
      expect(JSON.generate(nan.to_h)).to include '"value":"NaN"'

      infinite = refusal do
        GraphWeaver::Coerce.variable("count", "T", Float::INFINITY) { |v| GraphWeaver::Coerce.integer(v) }
      end
      expect(infinite.value).to eq "Infinity"
      expect { JSON.generate(infinite.to_h) }.not_to raise_error
    end

    it "keeps a non-finite number nested inside a value JSON-generatable too" do
      error = refusal do
        GraphWeaver::Coerce.variable("stats", "T", { "mean" => Float::NAN }) { |v| GraphWeaver::Coerce.integer(v) }
      end

      expect(error.value).to eq({ "mean" => "NaN" })
      expect { JSON.generate(error.to_h) }.not_to raise_error
    end
  end

  # One rule, both directions. A server can spell an input field only the way
  # its schema does, so that is the spelling BOTH halves use — the prop is what
  # you type in Ruby, and it is the message (the developer's line) that names
  # it. Before this, a form doing errors[e.field] silently missed every
  # server-detected error, because the two halves disagreed.
  describe "the spelling of #path and #field" do
    let(:mod) do
      schema = GraphQL::Schema.from_definition(<<~GRAPHQL)
        input InvoiceInput { issuedOn: String!, externalId: Int }
        type Query { invoice(input: InvoiceInput!): String }
        schema { query: Query }
      GRAPHQL
      GraphWeaver.parse(schema:, client: Demo::Schema, name: "BillQuery",
        query: "query Bill($input: InvoiceInput!) { invoice(input: $input) }")
    end

    it "is the schema's, for a refusal raised here" do
      error = refusal { mod.execute(input: { issued_on: "2024-01-15", external_id: "lots" }) }

      expect(error.path).to eq %w[input externalId]
      expect(error.field).to eq "externalId"
      expect(error.coordinate).to eq "InvoiceInput.externalId"
      # the message is the developer's line, so it names the prop they typed
      expect(error.message).to include "external_id:"
    end

    it "is the schema's for a missing field too, not the prop it generates" do
      error = refusal { mod.execute(input: { external_id: 1 }) }

      expect(error.kind).to eq :missing
      expect(error.path).to eq %w[input issuedOn]
    end

    it "matches what the server sends back for the same field" do
      raised = refusal { mod.execute(input: { issued_on: "2024-01-15", external_id: "lots" }) }
      sent = GraphWeaver::GraphQLError.from_h(
        "message" => "Variable $input of type InvoiceInput! was provided invalid value",
        "extensions" => {
          "value" => { "externalId" => "lots" },
          "problems" => [{ "path" => ["externalId"], "explanation" => 'Could not coerce value "lots" to Int' }],
        },
      ).input_errors.first

      expect(sent.field).to eq raised.field
      expect(sent.path).to eq raised.path
    end

    # a typo names no field, so there is no schema spelling to give — the key
    # comes back exactly as it was written, and the suggestion is the prop to
    # type instead
    it "echoes an unknown key as spelled, and suggests the prop" do
      error = refusal { mod.execute(input: { issued_on: "x", externalId: 1 }) }

      expect(error.kind).to eq :unknown
      expect(error.path).to eq %w[input externalId]
      expect(error.details[:suggestion]).to eq "external_id"
    end
  end

  describe "server-side: a rejection becomes the same value" do
    def errors_for(hash) = GraphWeaver::GraphQLError.from_h(hash).input_errors
    def error_for(hash) = errors_for(hash).first

    it "is one InputError per problem — a coercion error carries several" do
      errors = errors_for(
        "message" => "Variable $input of type ValidatedInput! was provided invalid value",
        "extensions" => {
          "value" => { "qty" => "x", "mode" => "turbo" },
          "problems" => [
            { "path" => ["qty"], "explanation" => 'Could not coerce value "x" to Int' },
            { "path" => ["mode"], "explanation" => 'Expected "turbo" to be one of: fast, slow' },
          ],
        },
      )

      expect(errors.map(&:kind)).to eq %i[unparseable not_a_member]
      expect(errors.map(&:path)).to eq [%w[input qty], %w[input mode]]
    end

    # ---- the convention: extensions.input, taken verbatim (docs/errors.md)
    it "takes extensions.input verbatim when the server states it" do
      error = error_for(
        "message" => "min must be at least 1",
        "path" => ["createRange"],
        "extensions" => {
          "code" => "BAD_USER_INPUT",
          "input" => {
            "kind" => "out_of_range", "path" => ["input", "range", "min"],
            "coordinate" => "RangeInput.min", "value" => 0, "min" => 1
          },
        },
      )

      expect(error.kind).to eq :out_of_range
      expect(error.path).to eq ["input", "range", "min"]
      expect(error.coordinate).to eq "RangeInput.min"
      expect(error.value).to eq 0
      expect(error.details).to eq({ min: 1 })
      expect(error.message).to eq "min must be at least 1"
    end

    # a lenient JSON parser hands back Infinity, and #to_h is a 422 body
    it "keeps a non-finite value a server stated JSON-generatable" do
      error = error_for(
        "message" => "too big",
        "extensions" => { "input" => { "kind" => "out_of_range", "path" => ["n"], "value" => Float::INFINITY } },
      )

      expect(error.value).to eq "Infinity"
      expect { JSON.generate(error.to_h) }.not_to raise_error
    end

    it "carries invalid_format's pattern the same way" do
      error = error_for(
        "message" => "email is not an email",
        "extensions" => { "input" => { "kind" => "invalid_format", "pattern" => "email" } },
      )

      expect(error.kind).to eq :invalid_format
      expect(error.details).to eq({ pattern: "email" })
    end

    # closing the key set isn't enough: errors.rb promises members stays an
    # Array, so an app writing details[:members].join(", ") would raise on a
    # server that sent a String
    it "drops a detail whose type isn't the one its key means" do
      error = error_for(
        "message" => "nope",
        "extensions" => { "input" => {
          "kind" => "out_of_range", "members" => "not a list", "min" => { "deep" => [1, 2] }, "max" => 9,
        } },
      )

      expect(error.details).to eq({ max: 9 })
    end

    it "degrades a kind it has never heard of to :refused rather than guessing" do
      error = error_for(
        "message" => "nope",
        "extensions" => { "input" => { "kind" => "wildly_off", "path" => ["a"] } },
      )

      expect(error.kind).to eq :refused
      expect(error.path).to eq ["a"] # the facts it did state still stand
    end

    # ---- graphql-ruby's variable-coercion shape (measured, 2.6.10)
    it "reads a variable-coercion failure, one InputError per problem" do
      error = error_for(
        "message" => "Variable $input of type Level1Input! was provided invalid value for " \
          'level2.level3.count (Could not coerce value "nope" to Int)',
        "extensions" => {
          "value" => { "level2" => { "level3" => { "count" => "nope" } } },
          "problems" => [
            { "path" => ["level2", "level3", "count"], "explanation" => 'Could not coerce value "nope" to Int' },
          ],
        },
      )

      expect(error.kind).to eq :unparseable
      expect(error.details[:type]).to eq "Int"
      expect(error.path).to eq ["input", "level2", "level3", "count"]
      expect(error.value).to eq "nope"
      expect(error.coordinate).to be_nil
    end

    it "calls a non-String that wouldn't coerce a type mismatch" do
      error = error_for(
        "message" => "Variable $count of type Int! was provided invalid value",
        "extensions" => {
          "value" => { "a" => 1 },
          "problems" => [{ "path" => [], "explanation" => 'Could not coerce value {"a" => 1} to Int' }],
        },
      )

      expect(error.kind).to eq :type_mismatch
      expect(error.path).to eq ["count"]
    end

    it "reads the enum, required and unknown-field explanations" do
      enum = error_for(
        "message" => "Variable $color of type Color! was provided invalid value",
        "extensions" => {
          "value" => "BLUE",
          "problems" => [{ "path" => [], "explanation" => 'Expected "BLUE" to be one of: RED, GREEN' }],
        },
      )
      expect(enum.kind).to eq :not_a_member
      expect(enum.details[:members]).to eq %w[RED GREEN]

      missing = error_for(
        "message" => "Variable $range of type RangeInput! was provided invalid value for min " \
          "(Expected value to not be null)",
        "extensions" => {
          "value" => { "max" => 3 },
          "problems" => [{ "path" => ["min"], "explanation" => "Expected value to not be null" }],
        },
      )
      expect(missing.kind).to eq :missing
      expect(missing.path).to eq ["range", "min"]

      unknown = error_for(
        "message" => "Variable $range of type RangeInput! was provided invalid value for nope " \
          "(Field is not defined on RangeInput)",
        "extensions" => {
          "value" => { "min" => 1, "nope" => 3 },
          "problems" => [{ "path" => ["nope"], "explanation" => "Field is not defined on RangeInput" }],
        },
      )
      expect(unknown.kind).to eq :unknown
      expect(unknown.coordinate).to eq "RangeInput.nope"
    end

    # #path is the variable plus the problem's own path, so with an empty
    # problem path the last segment is the VARIABLE — and "RangeInput.range"
    # is a slot that does not exist. A gateway that rewrites problems, or a
    # non-graphql-ruby server, can send this.
    it "gives no coordinate when the problem names no field inside the variable" do
      unknown = error_for(
        "message" => "Variable $range of type RangeInput! was provided invalid value",
        "extensions" => {
          "value" => { "min" => 1 },
          "problems" => [{ "path" => [], "explanation" => "Field is not defined on RangeInput" }],
        },
      )

      expect(unknown.kind).to eq :unknown
      expect(unknown.path).to eq ["range"]
      expect(unknown.coordinate).to be_nil
    end

    it "falls back to :refused for an explanation it has no table for (a custom scalar, @oneOf)" do
      error = error_for(
        "message" => "Variable $hex of type Hex! was provided invalid value",
        "extensions" => {
          "value" => "nope",
          "problems" => [{ "path" => [], "explanation" => '"nope" is not a valid Hex color' }],
        },
      )

      expect(error.kind).to eq :refused
      expect(error.message).to eq '"nope" is not a valid Hex color'
    end

    it "prefers a problem's own extensions.input over the explanation table" do
      error = error_for(
        "message" => "Variable $hex of type HexExt! was provided invalid value",
        "extensions" => {
          "value" => "nope",
          "problems" => [{
            "path" => [], "explanation" => '"nope" is not a valid HexExt color',
            "extensions" => { "input" => { "kind" => "invalid_format", "pattern" => "#rrggbb" } },
          }],
        },
      )

      expect(error.kind).to eq :invalid_format
      expect(error.details[:pattern]).to eq "#rrggbb"
    end

    # ---- graphql-ruby's rule codes (literal arguments; GraphWeaver.run)
    it "maps the four input-shaped validation codes" do
      missing = error_for(
        "message" => "Argument 'min' on InputObject 'RangeInput' is required. Expected type Int!",
        "path" => %w[query rangeThing range min],
        "extensions" => { "code" => "missingRequiredInputObjectAttribute", "argumentName" => "min",
                          "argumentType" => "Int!", "inputObjectType" => "RangeInput" },
      )
      expect(missing.kind).to eq :missing
      expect(missing.path).to eq ["min"]
      expect(missing.coordinate).to eq "RangeInput.min"

      unknown = error_for(
        "message" => "InputObject 'RangeInput' doesn't accept argument 'nope'",
        "extensions" => { "code" => "argumentNotAccepted", "name" => "RangeInput",
                          "typeName" => "InputObject", "argumentName" => "nope" },
      )
      expect(unknown.kind).to eq :unknown
      expect(unknown.coordinate).to eq "RangeInput.nope"

      literal = error_for(
        "message" => "Argument 'count' on Field 'countThing' has an invalid value (\"lots\"). Expected type 'Int!'.",
        "extensions" => { "code" => "argumentLiteralsIncompatible", "typeName" => "Field",
                          "argumentName" => "count" },
      )
      expect(literal.kind).to eq :type_mismatch
      expect(literal.path).to eq ["count"]
      # "countThing.count" is not a schema coordinate — the parent type is unnamed
      expect(literal.coordinate).to be_nil

      mismatch = error_for(
        "message" => "Type mismatch on variable $count and argument count (String! / Int!)",
        "path" => %w[query countThing count],
        "extensions" => { "code" => "variableMismatch", "variableName" => "count",
                          "typeName" => "String!", "argumentName" => "count" },
      )
      expect(mismatch.kind).to eq :type_mismatch
    end

    # ---- the floor
    it "claims nothing from an error the server never marked as being about input" do
      # a graphql-ruby `validates:` failure: an execution error with no
      # extensions at all, indistinguishable from "the database is down"
      expect(error_for("message" => "qty must be greater than 0", "path" => ["validatedInput"])).to be_nil

      expect(error_for("message" => "boom", "extensions" => { "code" => "INTERNAL_SERVER_ERROR" })).to be_nil
    end

    # ---- Hasura: no input code, the argument named in extensions.path
    #
    # Every hash below is verbatim from https://beta.pokeapi.co/graphql/v1beta
    # (Hasura v2), one curl per row.
    describe "Hasura, which states the argument in extensions.path" do
      # limit: -5
      it "names the argument a value was rejected for" do
        error = error_for(
          "message" => "expected a non-negative 32-bit integer for type 'Int', but found a number",
          "extensions" => { "path" => "$.selectionSet.pokemon_v2_pokemon.args.limit",
                            "code" => "validation-failed" },
        )

        # :out_of_range would be a guess: the same sentence arrives for
        # limit: "lots", where the value is the wrong type, not out of range
        expect(error.kind).to eq :refused
        expect(error.path).to eq ["limit"]
        expect(error.field).to eq "limit"
        expect(error.message).to eq "expected a non-negative 32-bit integer for type 'Int', but found a number"
      end

      # limit: 3.5 — a different code for the same slot
      it "reads parse-failed the same way" do
        error = error_for(
          "message" => "The value 3.5 lies outside the bounds or is not an integer. " \
            "Maybe it is a float, or is there integer overflow?",
          "extensions" => { "path" => "$.selectionSet.pokemon_v2_pokemon.args.limit",
                            "code" => "parse-failed" },
        )

        expect(error.kind).to eq :refused
        expect(error.path).to eq ["limit"]
      end

      # order_by: [{ name: "sideways" }]
      it "reads the enum explanation, members and all, through a list index" do
        error = error_for(
          "message" => "expected one of the values ['asc', 'asc_nulls_first', 'asc_nulls_last', " \
            "'desc', 'desc_nulls_first', 'desc_nulls_last'] for type 'order_by', but found 'sideways'",
          "extensions" => { "path" => "$.selectionSet.pokemon_v2_pokemon.args.order_by[0].name",
                            "code" => "validation-failed" },
        )

        expect(error.kind).to eq :not_a_member
        expect(error.path).to eq ["order_by", 0, "name"]
        expect(error.details[:members])
          .to eq %w[asc asc_nulls_first asc_nulls_last desc desc_nulls_first desc_nulls_last]
      end

      # where: { nope: { _eq: 1 } }
      it "reads a key the input type doesn't define, with the coordinate it names" do
        error = error_for(
          "message" => "field 'nope' not found in type: 'pokemon_v2_pokemon_bool_exp'",
          "extensions" => { "path" => "$.selectionSet.pokemon_v2_pokemon.args.where.nope",
                            "code" => "validation-failed" },
        )

        expect(error.kind).to eq :unknown
        expect(error.path).to eq %w[where nope]
        expect(error.coordinate).to eq "pokemon_v2_pokemon_bool_exp.nope"
      end

      # where: { name: { _eq: null } }
      it "reads a null where the schema wants a value" do
        error = error_for(
          "message" => "unexpected null value for type 'String'",
          "extensions" => { "path" => "$.selectionSet.pokemon_v2_pokemon.args.where.name._eq",
                            "code" => "validation-failed" },
        )

        expect(error.kind).to eq :missing
        expect(error.path).to eq %w[where name _eq]
      end

      # a nested field's argument, which repeats selectionSet
      it "follows the argument down a nested selection" do
        error = error_for(
          "message" => "expected a non-negative 32-bit integer for type 'Int', but found a number",
          "extensions" => {
            "path" => "$.selectionSet.pokemon_v2_pokemon.selectionSet.pokemon_v2_pokemonmoves.args.limit",
            "code" => "validation-failed",
          },
        )

        expect(error.path).to eq ["limit"]
      end

      # validation-failed is Hasura's code for the query too, and a query that
      # doesn't parse is not the user's input — it's the .graphql file
      it "claims nothing when the path names no argument" do
        expect(error_for(
          "message" => "not a valid graphql query",
          "extensions" => { "path" => "$.query", "code" => "validation-failed" },
        )).to be_nil

        # `pokemon_v2_pokemon(bogus: 3)` — the field, no .args. segment at all
        expect(error_for(
          "message" => "'pokemon_v2_pokemon' has no argument named 'bogus'",
          "extensions" => { "path" => "$.selectionSet.pokemon_v2_pokemon", "code" => "validation-failed" },
        )).to be_nil

        # the database refusing a value it was handed, reported at the root
        expect(error_for(
          "message" => 'invalid input syntax for type integer: "lots"',
          "extensions" => { "path" => "$", "code" => "data-exception" },
        )).to be_nil
      end

      it "refuses a path it can't read rather than pointing a form at a guess" do
        expect(error_for(
          "message" => "nope",
          "extensions" => { "path" => "$.selectionSet.thing.args.what is this", "code" => "validation-failed" },
        )).to be_nil
      end

      # an argument really can be named `args`, and the first one wins
      it "splits on the first args segment, not the last" do
        error = error_for(
          "message" => "nope",
          "extensions" => { "path" => "$.selectionSet.thing.args.where.args", "code" => "validation-failed" },
        )

        expect(error.path).to eq %w[where args]
      end
    end

    it "takes a bare BAD_USER_INPUT as :refused with the server's own sentence" do
      error = error_for(
        "message" => "qty must be greater than 0",
        "path" => ["validatedInput"],
        "extensions" => { "code" => "BAD_USER_INPUT" },
      )

      expect(error.kind).to eq :refused
      expect(error.message).to eq "qty must be greater than 0"
      expect(error.path).to eq ["validatedInput"] # the response path — the honest floor
      expect(error.coordinate).to be_nil
    end

    it "is a value, not a raise — it writes no warn line" do
      io = StringIO.new
      GraphWeaver.logger = Logger.new(io, level: Logger::WARN)
      error_for("message" => "nope", "extensions" => { "code" => "BAD_USER_INPUT" })

      expect(io.string).to eq ""
    ensure
      GraphWeaver.logger = nil
    end
  end

  describe "the collection accessors" do
    let(:raw) do
      {
        "data" => nil,
        "errors" => [
          { "message" => "boom" },
          { "message" => "bad", "extensions" => { "input" => { "kind" => "missing", "path" => ["a"] } } },
        ],
      }
    end

    it "filters a response's errors down to the ones about input" do
      response = PersonQuery.from_response(raw)

      expect(response.errors.size).to eq 2
      expect(response.input_errors.map(&:kind)).to eq [:missing]
      expect(response.input_errors.first).to be_a GraphWeaver::InputError
    end

    it "asks the same question of the raised envelope" do
      expect { PersonQuery.from_response!(raw) }.to raise_error(GraphWeaver::QueryError) { |e|
        expect(e.input_errors.map(&:path)).to eq [["a"]]
      }
    end

    it "is [] when nothing was about input" do
      expect(PersonQuery.from_response("data" => nil, "errors" => [{ "message" => "boom" }]).input_errors).to eq []
    end
  end
end
