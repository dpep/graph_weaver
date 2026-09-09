# typed: ignore

require "shellwords"
require "tmpdir"

# srb tc proves the generated code is self-consistent, never that it matches
# the schema. These pin the three places it didn't.
describe "generated types tell the truth about the schema" do
  def generate(query)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "q.graphql"), query)
      out = File.join(dir, "generated")
      GraphWeaver.generate!(schema: Demo::Schema, queries: dir, output: out, client: Demo::Schema)
      File.read(Dir[File.join(out, "*.rb")].reject { |f| f.include?("types") }.first)
    end
  end

  # the server omits the guarded occurrence's children, so they can be absent
  # even where the schema says non-null
  it "widens a child reached only through a guarded occurrence" do
    source = generate(<<~GQL)
      query Cond($yes: Boolean!) {
        person(id: "1") { pets @include(if: $yes) { name } pets { species } }
      }
    GQL

    expect(source).to include "const :name, T.nilable(String)"
    expect(source).to include "const :species,"
  end

  it "keeps a child guaranteed when the only occurrence is guarded" do
    source = generate('query C($y: Boolean!) { person(id: "1") { pets @include(if: $y) { name } } }')

    # the key itself is nilable; what is inside it is not
    expect(source).to include "const :name, String\n"
  end

  it "widens both when every occurrence is guarded, differently" do
    source = generate(<<~GQL)
      query C($a: Boolean!, $b: Boolean!) {
        person(id: "1") {
          pets @include(if: $a) { name }
          pets @include(if: $b) { species }
        }
      }
    GQL

    expect(source).to include "const :name, T.nilable(String)"
    expect(source).to include "const :species, T.nilable("
  end

  # narrowing filters the elements; it does not remove the list
  it "narrows the member, not the list around it" do
    source = generate('{ search(term: "x") { ... on Person { name } } }')

    expect(source).to include "const :search, T::Array["
    expect(source).not_to include "const :search, T.nilable(T::Array["
  end
end

# execute coerces in its body under `.checked(:never)`, so nothing at
# runtime can tell a narrow kwarg from a widened one — only srb tc can, and
# the whole point of the design is that it still does. So ask it.
describe "execute's kwargs stay statically narrow" do
  def typecheck(*requires, body)
    Dir.mktmpdir do |dir|
      file = File.join(dir, "call_site.rb")
      lines = requires.map { |name| "require_relative #{File.expand_path("generated/#{name}", __dir__).inspect}" }
      File.write(file, "# typed: strict\n#{lines.join("\n")}\n\n#{body}\n")
      # sorbet/config adds the repo itself, so the generated modules and the
      # gem's own sigs come along
      `bundle exec srb tc #{file.shellescape} 2>&1`
    end
  end

  it "rejects a loose value where the schema says String" do
    expect(typecheck("person_query", "PersonQuery.execute(id: 42)"))
      .to match(/Expected `String` but found `Integer/)
  end

  it "accepts an untyped one — the value coercion exists for" do
    expect(typecheck("person_query", "PersonQuery.execute(id: T.unsafe(nil))")).to include "No errors!"
  end

  # The two widenings that are deliberate: a wire string for an enum and a
  # plain hash for an input object are how those are written by hand, not a
  # loophole for untyped input.
  it "keeps the enum and input-object kwargs wide" do
    expect(typecheck("add_pet_mutation", "adopt_mutation", <<~RUBY)).to include "No errors!"
      AddPetMutation.execute(name: "Rex", species: "DOG")
      AdoptMutation.execute(input: { name: "Rex", species: "DOG" })
    RUBY
  end
end
