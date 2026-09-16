# typed: ignore — exercises eval-defined (parse) modules
# frozen_string_literal: true

# docs/generated_modules.md recommends `abstract!` plus
# `sig { abstract.returns(String) }` as how a named helper module carries sigs
# srb tc can check: it declares the fields it leans on, and the generated
# struct satisfies them. Sorbet then demands that whatever satisfies an
# abstract sig say so — and neither thing generation writes can be corrected
# by hand, since a `const` has no sig to insert `override.` into. Codegen has
# the mixins in hand (registrations replay), so it derives this the same way
# it derives an alias's type.
RSpec.describe "a mixin declaring a struct's member abstract" do
  let(:schema) do
    GraphQL::Schema.from_definition(<<~GRAPHQL)
      type Query { pet: Pet }
      type Pet { name: String! meta: Meta }
      type Meta { tag: String! }
    GRAPHQL
  end

  let(:query) { "query P { pet { name meta { tag } } }" }

  after { GraphWeaver::Codegen.reset_type_helpers! }

  def generate(q = query, name: "P")
    GraphWeaver::Codegen.generate(schema:, query: q, name:)
  end

  it "declares the override on a selected field's prop" do
    GraphWeaver.extend_type("Pet", AbstractMixin::PetFields, alias: { tag: "meta.tag" })

    expect(generate).to include("const :name, String, override: true")
  end

  it "declares the override on an alias delegator's sig" do
    GraphWeaver.extend_type("Pet", AbstractMixin::PetFields, alias: { tag: "meta.tag" })

    expect(generate).to include("sig { override.returns(T.nilable(String)) }", "def tag = meta&.tag")
  end

  # `override` on a method that overrides nothing is its own error (5035), so
  # this is only said where a mixin asked for it
  it "says nothing where no mixin declares the member abstract" do
    GraphWeaver.extend_type("Pet", alias: { tag: "meta.tag" }) { def shout = "#{name}!" }
    src = generate

    expect(src).to include("const :name, String\n")
    expect(src).to include("sig { returns(T.nilable(String)) }", "def tag = meta&.tag")
    expect(src).not_to include("override")
  end

  # an abstract sig an ancestor declares is one Sorbet demands the override for
  # just the same
  it "sees an abstract sig the mixin inherits" do
    inheriting = Module.new { include AbstractMixin::PetFields }
    stub_const("InheritingPetFields", inheriting)
    GraphWeaver.extend_type("Pet", InheritingPetFields, alias: { tag: "meta.tag" })

    expect(generate).to include("const :name, String, override: true")
  end

  # sorbet-runtime validates `override: true` against the ancestors at prop
  # declaration, so a wrong answer here fails at load rather than in srb tc
  it "loads and runs, with the mixin reading both halves" do
    GraphWeaver.extend_type("Pet", AbstractMixin::PetFields, alias: { tag: "meta.tag" })
    mod = GraphWeaver::Codegen.parse(schema:, query:, name: "PLive")

    pet = mod.from_response!("data" => { "pet" => { "name" => "Shelby", "meta" => { "tag" => "good" } } }).pet

    expect(pet.shout).to eq "Shelby!good"
  end
end
