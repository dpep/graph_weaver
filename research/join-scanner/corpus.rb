# frozen_string_literal: true

require_relative "synth"

# Every supergraph this experiment can lay hands on.
module Corpus
  ROOT = File.expand_path("../..", __dir__)

  ADVERSARIAL = {
    "adv: description holds a directive application" => <<~'SDL',
      "A type. Do not read @join__field(graph: GHOST) out of this."
      schema @link(url: "https://specs.apollo.dev/join/v0.3") { query: Query }
      directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT
      scalar join__FieldSet
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      "Query root @join__type(graph: GHOST)"
      type Query @join__type(graph: A) {
        "a field @join__field(graph: GHOST) mentioned in prose"
        hi: String @join__field(graph: A)
      }
    SDL

    "adv: block string with an unbalanced paren and a marker" => <<~'SDL',
      schema @link(url: "https://specs.apollo.dev/join/v0.3") { query: Query }
      directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT
      scalar join__FieldSet
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      """
      An unbalanced ( paren, a stray } brace, and @join__field(graph: GHOST
      spanning lines.
      """
      type Query @join__type(graph: A) {
        """
        More prose ) with @join__type(graph: GHOST) inside.
        """
        hi: String @join__field(graph: A)
      }
    SDL

    "adv: escaped quote inside a block string" => <<~'SDL',
      schema @link(url: "https://specs.apollo.dev/join/v0.3") { query: Query }
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      """
      ends with \""" then keeps going @join__type(graph: GHOST)
      """
      type Query @join__type(graph: A) { hi: String }
    SDL

    "adv: renamed join spec" => <<~'SDL',
      schema @link(url: "https://specs.apollo.dev/join/v0.3", as: "j") { query: Query }
      directive @j__graph(name: String!, url: String!) on ENUM_VALUE
      directive @j__type(graph: j__Graph!) repeatable on OBJECT
      enum j__Graph { A @j__graph(name: "a", url: "http://a") }
      type Query @j__type(graph: A) { hi: String }
    SDL

    "adv: federation 1 @core form" => <<~'SDL',
      schema @core(feature: "https://specs.apollo.dev/core/v0.1")
             @core(feature: "https://specs.apollo.dev/join/v0.1") { query: Query }
      directive @join__field(graph: join__Graph, requires: join__FieldSet) on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__owner(graph: join__Graph!) on OBJECT
      directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT
      directive @core(feature: String!) repeatable on SCHEMA
      scalar join__FieldSet
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      type Query @join__owner(graph: A) @join__type(graph: A, key: "id") {
        id: ID!
        hi: String @join__field(graph: A)
      }
    SDL

    "adv: a @join__field split across lines" => <<~'SDL',
      schema @link(url: "https://specs.apollo.dev/join/v0.3") { query: Query }
      directive @join__field(
        graph: join__Graph
        requires: join__FieldSet
        external: Boolean
      ) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT
      scalar join__FieldSet
      enum join__Graph {
        A @join__graph(name: "a", url: "http://a")
        B @join__graph(
          name: "b"
          url: "http://b"
        )
      }
      type Query
        @join__type(graph: A, key: "id")
        @join__type(
          graph: B
          key: "id"
        )
      {
        id: ID!
        hi: String
          @join__field(
            graph: A
            requires: "id"
          )
          @join__field(graph: B, external: true)
      }
    SDL

    "adv: unicode names, prose and comments" => <<~'SDL',
      # café — a comment with @join__type(graph: GHOST) and an ( unbalanced paren
      schema @link(url: "https://specs.apollo.dev/join/v0.3") { query: Query }
      directive @join__field(graph: join__Graph) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT | ENUM
      enum join__Graph { A @join__graph(name: "résumé ☕", url: "http://a/ünïcode") }
      "Descriptions may hold ☕ and 日本語 and emoji 🚀"
      type Query @join__type(graph: A) {
        "café ☕"
        hi: String @join__field(graph: A)
      }
    SDL

    "adv: nested parens and a list in an argument value" => <<~'SDL',
      schema @link(url: "https://specs.apollo.dev/join/v0.3") { query: Query }
      directive @join__field(graph: join__Graph, contextArguments: [join__ContextArgument!]) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!, key: join__FieldSet) repeatable on OBJECT
      directive @custom(shape: String) on FIELD_DEFINITION
      scalar join__FieldSet
      input join__ContextArgument { context: String! name: String! type: String! selection: join__FieldSet! }
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      type Query @join__type(graph: A, key: "id organization { id }") {
        id: ID!
        hi(arg: String = "a ) string ) with parens"): String
          @custom(shape: "( ( (")
          @join__field(
            graph: A
            contextArguments: [{ context: "ctx", name: "lang", type: "String", selection: "language" }]
          )
      }
    SDL

    "adv: an unknown join directive on a field and a type" => <<~'SDL',
      schema @link(url: "https://specs.apollo.dev/join/v0.6") @join__futureThing { query: Query }
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      type Query @join__type(graph: A) @join__tomorrow(graph: A) {
        hi: String @join__someFutureDirective(graph: A)
      }
    SDL

    "adv: whitespace-mangled type references" => <<~'SDL',
      schema @link(url: "https://specs.apollo.dev/join/v0.3") { query: Query }
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      type Query @join__type(graph: A) {
        a : [  Thing !  ] !
        b: [[Thing]]
        c:[Thing!]!
      }
      type Thing @join__type(graph: A) { id: ID! }
    SDL

    "adv: interfaceObject, progressive override, resolvable false" => <<~'SDL',
      schema @link(url: "https://specs.apollo.dev/join/v0.5") { query: Query }
      directive @join__field(graph: join__Graph, override: String, overrideLabel: String, usedOverridden: Boolean, provides: join__FieldSet) repeatable on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__implements(graph: join__Graph!, interface: String!) repeatable on OBJECT | INTERFACE
      directive @join__type(graph: join__Graph!, key: join__FieldSet, resolvable: Boolean! = true, isInterfaceObject: Boolean! = false) repeatable on OBJECT | INTERFACE | UNION
      directive @join__unionMember(graph: join__Graph!, member: String!) repeatable on UNION
      scalar join__FieldSet
      enum join__Graph { A @join__graph(name: "a", url: "http://a") B @join__graph(name: "b", url: "http://b") }
      interface Media @join__type(graph: A, key: "id", isInterfaceObject: true) @join__type(graph: B, key: "id") { id: ID! }
      type Movie implements Media @join__type(graph: B, key: "id", resolvable: false) @join__implements(graph: B, interface: "Media") {
        id: ID!
        title: String @join__field(graph: B, override: "a", overrideLabel: "percent(25)")
        legacy: String @join__field(graph: A, usedOverridden: true) @join__field(graph: B, provides: "id")
      }
      union Thing @join__type(graph: A) @join__type(graph: B) @join__unionMember(graph: A, member: "Movie") = Movie
      type Query @join__type(graph: A) { media: Media }
    SDL

    "adv: empty bodies and a bare schema" => <<~'SDL',
      schema { query: Query }
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT | SCALAR | ENUM | UNION | INPUT_OBJECT
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      scalar Money @join__type(graph: A)
      enum Empty @join__type(graph: A)
      union None @join__type(graph: A)
      type Bare @join__type(graph: A)
      input Args @join__type(graph: A) { a: Int = 3, b: [String!] = ["x", "y"] }
      type Query @join__type(graph: A) { m: Money }
    SDL
  }.freeze

  REFUSABLE = {
    "refuse: escape in a @join__field argument" => <<~'SDL',
      schema @link(url: "https://specs.apollo.dev/join/v0.3") { query: Query }
      directive @join__field(graph: join__Graph, requires: join__FieldSet) on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT
      scalar join__FieldSet
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      type Query @join__type(graph: A) { hi: String @join__field(graph: A, requires: "a\tb") }
    SDL

    "refuse: type extension" => <<~'SDL',
      schema @link(url: "https://specs.apollo.dev/join/v0.3") { query: Query }
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      type Query @join__type(graph: A) { hi: String }
      extend type Query { bye: String }
    SDL

    "refuse: block string as an argument value" => <<~SDL,
      schema @link(url: "https://specs.apollo.dev/join/v0.3") { query: Query }
      directive @join__field(graph: join__Graph, requires: join__FieldSet) on FIELD_DEFINITION
      directive @join__graph(name: String!, url: String!) on ENUM_VALUE
      directive @join__type(graph: join__Graph!) repeatable on OBJECT
      scalar join__FieldSet
      enum join__Graph { A @join__graph(name: "a", url: "http://a") }
      type Query @join__type(graph: A) { hi: String @join__field(graph: A, requires: \"\"\"
      id
      \"\"\") }
    SDL
  }.freeze

  # Every heredoc in the suite that looks like supergraph SDL. Interpolated
  # ones are skipped: they are Ruby, not a document.
  def self.harvested
    Dir[File.join(ROOT, "spec/**/*.rb")].sort.flat_map do |path|
      src = File.read(path)
      src.scan(/<<[~-](\w+)\n(.*?)\n[ \t]*\1\b/m).filter_map do |(tag, body)|
        next unless body.include?("join__graph") || body.include?("join__type")
        next if body.include?('#{')

        indent = body.lines.reject { |l| l.strip.empty? }.map { |l| l[/\A */].size }.min || 0
        text = body.lines.map { |l| l[indent..] || "\n" }.join
        ["#{path.delete_prefix("#{ROOT}/")} <<#{tag}", text]
      end
    end
  end

  def self.files
    Dir[File.join(ROOT, "spec/support/federation/*.graphql")].sort
      .map { |p| [p.delete_prefix("#{ROOT}/"), File.read(p)] }
  end

  def self.synthesized(sizes = [500, 2000])
    sizes.map { |n| ["synthesized #{n} types", Synth.supergraph(n)] }
  end

  def self.each(&block)
    (files + harvested + ADVERSARIAL.to_a + REFUSABLE.to_a + synthesized).each(&block)
  end
end
