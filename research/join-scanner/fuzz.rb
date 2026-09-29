# frozen_string_literal: true

# Generate valid-but-hostile supergraph SDL and demand the two readers agree
# (or that the scanner refuses). Anything else is a silent misread.
#
#   bundle exec ruby tmp/exp/fuzz.rb [COUNT] [SEED]
require_relative "../../lib/graph_weaver"

Loader = GraphWeaver::SchemaLoader
Scan = Loader::JoinSource::Scan
Ast = Loader::JoinSource::Ast

class Gen
  MARKERS = [
    '@join__field(graph: GHOST)',
    '@join__type(graph: GHOST, key: "id")',
    "@join__graph(name: \"ghost\"",
    "unbalanced ( paren",
    "stray } brace and { another",
    "a colon : and an = equals",
    "type Ghost @join__type(graph: GHOST) { x: Int }",
    "#{'#'} a hash that is not a comment",
    "café ☕ 日本語 🚀",
    "quote \\\" inside",
    "three \\\"\\\"\\\" quotes",
    "",
    "   ",
  ].freeze

  WS = ["\n", " ", "\n  ", ", ", "\n\n", "\t", " ,\n "].freeze

  def initialize(seed)
    @r = Random.new(seed)
    @types = []
  end

  def pick(a) = a[@r.rand(a.size)]
  def maybe(p = 0.5) = @r.rand < p
  def ws = pick(WS)

  def comment = maybe(0.3) ? "# #{pick(MARKERS)}\n" : ""

  def description
    return "" unless maybe(0.55)

    if maybe(0.5)
      # a block string: may hold anything but an unescaped """
      "\"\"\"\n#{pick(MARKERS)}\n#{pick(MARKERS)}\n\"\"\"\n"
    else
      %("#{pick(MARKERS).gsub("\\", "\\\\\\\\").delete('"').delete("\n")}"\n)
    end
  end

  def name(prefix) = "#{prefix}#{@r.rand(6)}"

  def type_ref
    base = @types.empty? ? "String" : pick(@types + %w[String Int ID Boolean])
    depth = @r.rand(3)
    depth.times { base = "[#{base}#{maybe ? "!" : ""}]" }
    maybe ? "#{base}!" : base
  end

  # a type reference printed with hostile spacing — the signature must still
  # come out canonical
  def spaced(ref) = ref.chars.map { |c| "[]!".include?(c) ? "#{maybe(0.3) ? " " : ""}#{c}#{maybe(0.3) ? " " : ""}" : c }.join

  GRAPHS = %w[A B C].freeze

  def join_type
    args = ["graph: #{pick(GRAPHS)}"]
    args << %(key: "#{pick(['id', 'id sub { id }', 'a b c'])}") if maybe(0.6)
    args << "resolvable: #{pick([true, false])}" if maybe(0.2)
    args << "isInterfaceObject: true" if maybe(0.1)
    "@join__type(#{args.join(maybe ? ", " : "\n    ")})"
  end

  def join_field
    return "@join__#{pick(%w[tomorrow futureThing mystery])}(graph: #{pick(GRAPHS)})" if maybe(0.12)

    args = []
    args << "graph: #{pick(GRAPHS)}" if maybe(0.9)
    # an escaped value and a block-string value are shapes the scanner must
    # REFUSE rather than misread
    args << %(requires: "#{pick(['id', 'a { b }', 'x y', 'a\\tb', 'a\\u0041b'])}") if maybe(0.3)
    args << %(provides: """\nid\n""") if maybe(0.04)
    args << %(provides: "id") if maybe(0.2)
    args << %(override: "a") if maybe(0.15)
    args << %(overrideLabel: "percent(25)") if maybe(0.1)
    args << "external: true" if maybe(0.2)
    args << "usedOverridden: true" if maybe(0.1)
    if maybe(0.1)
      args << 'contextArguments: [{ context: "ctx", name: "lang", type: "String", selection: "language" }]'
    end
    return "@join__field" if args.empty?

    "@join__field(#{args.join(maybe ? ", " : "\n      ")})"
  end

  def other_directive
    pick(['@inaccessible', '@tag(name: "x")', '@deprecated(reason: "a ) b")',
      '@custom(n: 1, f: 1.5, b: false, l: [1, 2], o: { k: "v ) (" })', ""])
  end

  def field
    dirs = []
    @r.rand(3).times { dirs << join_field }
    dirs << other_directive if maybe(0.3)
    args = maybe(0.3) ? "(a: String = \"a ) b\", b: Int = 3 #{other_directive})" : ""
    "#{description}  #{name("f")}#{args}: #{spaced(type_ref)} #{dirs.join(" ")}\n"
  end

  def object
    n = "T#{@types.size}"
    @types << n
    impls = maybe(0.25) && @types.size > 1 ? " implements #{pick(@types[0..-2])}" : ""
    dirs = Array.new(1 + @r.rand(2)) { join_type }.join(ws)
    body = maybe(0.85) ? "{\n#{Array.new(1 + @r.rand(4)) { field }.join}}" : ""
    "#{comment}#{description}type #{n}#{impls}#{ws}#{dirs}#{ws}#{body}\n\n"
  end

  def other_def
    n = "O#{@r.rand(99)}"
    case @r.rand(5)
    when 0 then "#{description}scalar S#{n} @join__type(graph: A)\n\n"
    when 1 then "#{description}enum E#{n} @join__type(graph: A) {\n#{description}  V1\n  V2 @join__enumValue(graph: A)\n}\n\n"
    when 2 then "#{description}input I#{n} @join__type(graph: A) {\n  a: Int = 3\n  b: [String!] = [\"x ) y\"]\n}\n\n"
    when 3
      return "" if @types.size < 2

      "#{description}union U#{n} @join__type(graph: A) @join__unionMember(graph: A, member: \"#{@types[0]}\") =#{ws}#{@types[0]}#{ws}|#{ws}#{@types[1]}\n\n"
    else "#{description}interface If#{n} @join__type(graph: A) {\n  id: ID!\n}\n\n"
    end
  end

  HEADER = <<~SDL
    schema
      @link(url: "https://specs.apollo.dev/link/v1.0")
      @link(url: "https://specs.apollo.dev/join/v0.5", for: EXECUTION)
    { query: Query }

    directive @inaccessible on FIELD_DEFINITION | OBJECT
    directive @tag(name: String!) repeatable on FIELD_DEFINITION | OBJECT
    directive @custom(n: Int, f: Float, b: Boolean, l: [Int], o: CustomIn) on FIELD_DEFINITION
    directive @join__enumValue(graph: join__Graph!) repeatable on ENUM_VALUE
    directive @join__field(graph: join__Graph, requires: join__FieldSet, provides: join__FieldSet, external: Boolean, override: String, overrideLabel: String, usedOverridden: Boolean, contextArguments: [join__ContextArgument!]) repeatable on FIELD_DEFINITION | INPUT_FIELD_DEFINITION
    directive @join__graph(name: String!, url: String!) on ENUM_VALUE
    directive @join__implements(graph: join__Graph!, interface: String!) repeatable on OBJECT | INTERFACE
    directive @join__type(graph: join__Graph!, key: join__FieldSet, extension: Boolean! = false, resolvable: Boolean! = true, isInterfaceObject: Boolean! = false) repeatable on OBJECT | INTERFACE | UNION | ENUM | INPUT_OBJECT | SCALAR
    directive @join__unionMember(graph: join__Graph!, member: String!) repeatable on UNION
    directive @link(url: String, as: String, for: link__Purpose, import: [link__Import]) repeatable on SCHEMA

    input CustomIn { k: String }
    input join__ContextArgument { context: String! name: String! type: String! selection: join__FieldSet! }
    scalar join__FieldSet
    scalar link__Import
    enum link__Purpose { SECURITY EXECUTION }

    enum join__Graph {
      A @join__graph(name: "a", url: "http://a")
      B @join__graph(name: "b", url: "http://b")
      C @join__graph(name: "c", url: "http://c")
    }

  SDL

  def document
    body = Array.new(2 + @r.rand(6)) { maybe(0.7) ? object : other_def }.join
    query = "type Query @join__type(graph: A) {\n" +
      @types.first(3).map.with_index { |t, i| "  q#{i}: #{t} @join__field(graph: A)\n" }.join +
      "  ok: String\n}\n"
    extension = maybe(0.05) ? "\nextend type Query @join__type(graph: B) { extra: Int }\n" : ""
    HEADER + body + query + extension
  end
end

count = (ARGV[0] || 3000).to_i
seed0 = (ARGV[1] || 1).to_i

mismatched = 0
refused = Hash.new(0)
unparseable = 0
agreed = 0

(seed0...(seed0 + count)).each do |seed|
  sdl = Gen.new(seed).document

  begin
    expected = Ast.read(sdl)
  rescue GraphQL::ParseError
    unparseable += 1
    next
  end

  reason = +""
  got = Scan.read(sdl, reason:)
  if got.nil?
    refused[reason.sub(/ at line \d+\z/, "")] += 1
    next
  end

  if got.map(&:to_a) == expected.map(&:to_a)
    agreed += 1
    next
  end

  mismatched += 1
  next if mismatched > 3

  puts "=== MISMATCH seed #{seed} ==="
  got.zip(expected).each do |a, b|
    next if a&.to_a == b&.to_a

    puts "  scan: #{a.inspect[0, 300]}"
    puts "  ast:  #{b.inspect[0, 300]}"
  end
  File.write("/tmp/fuzz-#{seed}.graphql", sdl)
  puts "  (written to /tmp/fuzz-#{seed}.graphql)"
end

puts
puts "#{count} documents: #{agreed} agreed, #{mismatched} MISMATCHED, " \
  "#{refused.values.sum} refused, #{unparseable} not valid GraphQL"
refused.sort_by { |_, v| -v }.each { |r, v| puts "  refused x#{v}: #{r}" }
exit(mismatched.zero? ? 0 : 1)
