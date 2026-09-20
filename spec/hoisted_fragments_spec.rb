# typed: ignore — loads generated modules eval'd/required at runtime
# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# The rule, one sentence: a whole field selected as exactly one named shared
# fragment — object or abstract — is one type in the shared types module, named
# for the fragment, which every query aliases. unions_spec.rb holds the abstract
# half; this is the object half.
RSpec.describe "hoisting a shared fragment on an object type" do
  GENERATED = %i[PeopleQuery MeQuery GraphQLTypes].freeze

  around do |example|
    Dir.mktmpdir do |base|
      @base = base
      prior = GENERATED.to_h { |c| [c, (Object.const_get(c) if Object.const_defined?(c))] }
      GraphWeaver.fragments_paths = ["#{base}/fragments"]
      example.run
    ensure
      GraphWeaver.fragments_paths = nil
      GraphWeaver::Codegen.reset_type_helpers!
      GENERATED.each do |c|
        Object.send(:remove_const, c) if Object.const_defined?(c)
        Object.const_set(c, prior[c]) if prior[c]
      end
    end
  end

  let(:schema) do
    GraphQL::Schema.from_definition(<<~GRAPHQL)
      type Query { people: [Person!]! me: Person }
      type Person { name: String! email: String! address: Address }
      type Address { city: String! }
    GRAPHQL
  end

  def write(dir, name, content)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), content)
  end

  # the shared fragment, plus a list query and a nullable single-field query
  QUERIES = {
    "people" => "query People { people { ...PersonFields } }",
    "me" => "query Me { me { ...PersonFields } }",
  }.freeze

  def generate(fragment: "fragment PersonFields on Person { name email }", queries: QUERIES)
    write("#{@base}/fragments", "person.graphql", fragment)
    queries.each { |name, source| write("#{@base}/queries", "#{name}.graphql", source) }
    FileUtils.mkdir_p("#{@base}/generated")
    GraphWeaver.generate!(schema:, queries: "#{@base}/queries", output: "#{@base}/generated")
  end

  def generated(name) = File.read("#{@base}/generated/#{name}")

  it "emits the struct once, named for the fragment" do
    generate

    hoisted = generated("types/person_fields.rb")
    expect(hoisted).to include("module GraphQLTypes", "class PersonFields < T::Struct")
    expect(hoisted).to include("const :name, String", "const :email, String")
    expect(generated("types.rb")).to include('require_relative "types/person_fields"')
  end

  it "aliases it from every query instead of generating a struct per query" do
    generate

    %w[people me].each do |name|
      src = generated("#{name}_query.rb")
      expect(src).to include('require_relative "types"')
      expect(src).to include("PersonFields = GraphQLTypes::PersonFields")
      expect(src).not_to include("class Person") # nothing local for the spread field
    end
    # the list field's element type falls out of the existing type-ref path
    expect(generated("people_query.rb")).to include("const :people, T::Array[PersonFields]")
    expect(generated("me_query.rb")).to include("const :me, T.nilable(PersonFields)")
  end

  it "resolves both queries to one Ruby type" do
    generate
    GraphWeaver.load_generated!("#{@base}/generated")

    row = { "name" => "Ada", "email" => "ada@example.com" }
    person = PeopleQuery.from_response!("data" => { "people" => [row] }).people.first
    me = MeQuery.from_response!("data" => { "me" => row }).me

    expect(person.class).to eq(me.class)
    expect(person.class).to eq(GraphQLTypes::PersonFields)
    expect(person.email).to eq("ada@example.com")
  end

  it "inlines a spread nested inside the fragment, as a hoisted union's member does" do
    generate(fragment: <<~GRAPHQL)
      fragment PersonFields on Person { name address { ...AddressFields } }
      fragment AddressFields on Address { city }
    GRAPHQL

    expect(generated("types/person_fields.rb")).to include("class Address < T::Struct", "const :city, String")
    expect(File.exist?("#{@base}/generated/types/address_fields.rb")).to be(false)
  end

  it "carries the mixins and alias: paths registered for the type" do
    GraphWeaver.extend_type("Person", AbstractMixin::PetFields, alias: { tag: "address.city" })
    generate(fragment: "fragment PersonFields on Person { name address { city } }")

    hoisted = generated("types/person_fields.rb")
    expect(hoisted).to include("include AbstractMixin::PetFields # registered for Person")
    expect(hoisted).to include("const :name, String, override: true")
    expect(hoisted).to include("sig { override.returns(T.nilable(String)) }", "def tag = address&.city")
  end

  describe "an alias: path meeting the hoisted struct" do
    it "types a path that ends on it as the shared type" do
      GraphWeaver.extend_type("Query", alias: { first_person: "people.first" })
      generate(queries: QUERIES.slice("people"))

      expect(generated("people_query.rb"))
        .to include("sig { returns(T.nilable(PersonFields)) }", "def first_person = people.first")
    end

    it "refuses a path that reads through it, naming the fragment" do
      GraphWeaver.extend_type("Query", alias: { first_name: "people.first.name" })

      expect { generate(queries: QUERIES.slice("people")) }.to raise_error(GraphWeaver::Error, <<~MSG.chomp)
        PeopleQuery: alias "first_name" on Query: 'name' is inside the shared fragment PersonFields, which hoists to GraphQLTypes::PersonFields — a path can't read into it. Register the alias on Person, or select a field beside the spread to keep the struct local — pass optional: true to skip selections that don't fit
      MSG
    end
  end

  describe "what stays a position-named struct" do
    it "a spread mixed with another field" do
      generate(queries: { "people" => "query People { people { ...PersonFields email } }" })

      expect(generated("people_query.rb")).to include("class People < T::Struct")
      expect(generated("people_query.rb")).not_to include("PersonFields = ")
    end

    it "two spreads" do
      generate(
        fragment: "fragment PersonFields on Person { name }\nfragment ContactBits on Person { email }",
        queries: { "people" => "query People { people { ...PersonFields ...ContactBits } }" },
      )

      expect(generated("people_query.rb")).to include("class People < T::Struct")
      expect(File.exist?("#{@base}/generated/types/person_fields.rb")).to be(false)
    end

    it "a fragment the query defines itself" do
      generate(queries: {
        "people" => "query People { people { ...PersonFields } }\nfragment PersonFields on Person { name }",
      })

      expect(generated("people_query.rb")).to include("class People < T::Struct")
      expect(generated("people_query.rb")).not_to include("GraphQLTypes")
    end

    # the shared type is built from the fragment's own type condition, so
    # hoisting it would give the field a type that isn't the field's
    it "a fragment written on a type other than the field's" do
      interfaced = GraphQL::Schema.from_definition(<<~GRAPHQL)
        type Query { people: [Person!]! }
        interface Named { name: String! }
        type Person implements Named { name: String! }
      GRAPHQL
      write("#{@base}/fragments", "person.graphql", "fragment PersonFields on Named { name }")
      write("#{@base}/queries", "people.graphql", "query People { people { ...PersonFields } }")
      FileUtils.mkdir_p("#{@base}/generated")
      GraphWeaver.generate!(schema: interfaced, queries: "#{@base}/queries", output: "#{@base}/generated")

      expect(generated("people_query.rb")).to include("class People < T::Struct")
      expect(File.exist?("#{@base}/generated/types/person_fields.rb")).to be(false)
    end

    it "dynamic parse, which has no shared module to hoist into" do
      src = GraphWeaver::Codegen.generate(
        schema:,
        query: "query People { people { ...PersonFields } }\n" \
          "fragment PersonFields on Person { name email }",
        name: "People",
      )

      expect(src).to include("class People < T::Struct", "const :email, String")
    end
  end
end
