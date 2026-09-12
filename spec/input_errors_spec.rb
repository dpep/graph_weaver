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

    it "carries invalid_format's format the same way" do
      error = error_for(
        "message" => "email is not an email",
        "extensions" => { "input" => { "kind" => "invalid_format", "format" => "email" } },
      )

      expect(error.kind).to eq :invalid_format
      expect(error.details).to eq({ format: "email" })
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
            "extensions" => { "input" => { "kind" => "invalid_format", "format" => "#rrggbb" } },
          }],
        },
      )

      expect(error.kind).to eq :invalid_format
      expect(error.details[:format]).to eq "#rrggbb"
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
