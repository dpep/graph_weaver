# typed: true
# frozen_string_literal: true

require "graphql"

module GraphWeaver
  # What moved between two schemas — the dump you committed and the one the
  # server serves now.
  #
  #      rake graph_weaver:schema:diff
  #
  # Compares the two *schemas*, not their SDL: graphql-ruby reorders and
  # reformats what it prints, so a text diff reports churn no client can
  # break on, and buries the one line that matters in a 3 MB file.
  #
  # Breaking is judged from the client's side — a query that validates
  # against the dump and stops validating (or stops casting) against the
  # server. That makes nullability directional: an *output* going non-null
  # to nullable breaks a generated struct that expects a value, while an
  # *input* going nullable to non-null breaks a query that omits it. The
  # same signature change is breaking in one position and free in the other.
  #
  # This names what changed; it doesn't decide what to do about it.
  # `queries:check` answers the narrower question — which of *your* queries
  # a change actually reaches.
  class SchemaDiff
    # One difference. `coordinate` is the schema coordinate it happened at
    # ("User", "User.email", "Query.search(first:)"), so a CI log stays
    # greppable and a line can be pasted somewhere useful on its own.
    Change = Data.define(:coordinate, :description, :breaking) do
      def to_h = { "coordinate" => coordinate, "change" => description, "breaking" => breaking }

      def to_s = "#{coordinate}  #{description}"
    end

    # Every schema carries these whether or not anything uses them, so a
    # field newly typed Float would otherwise read as "type Float added".
    BUILT_IN = GraphQL::Schema::BUILT_IN_TYPES.keys.to_set.freeze
    private_constant :BUILT_IN

    # every change found, breaking ones first, then by coordinate
    attr_reader :changes

    # before/after: two GraphQL::Schema classes — the dump and the server.
    # source/target: what to call them in the headline (a path, a url).
    def initialize(before, after, source: nil, target: nil)
      @source = source
      @target = target
      @changes = []
      compare(before, after)
      @changes.sort_by! { |change| [change.breaking ? 0 : 1, change.coordinate] }
    end

    # the schemas agree — what CI gates on
    def empty? = @changes.empty?

    # the changes a query written against the dump can break on
    def breaking = @changes.select(&:breaking)

    # the rest: additions, deprecations, widenings a client absorbs
    def compatible = @changes.reject(&:breaking)

    # JSON-ready. One list, each entry saying whether it breaks — the
    # counts are derivable, and two places to read "breaking" from is one
    # too many.
    def to_h = { "changes" => @changes.map(&:to_h) }

    def report
      return "#{subject}no changes" if empty?

      [headline, *section("breaking:", breaking), *section("other:", compatible)].join("\n")
    end
    alias to_s report

    def inspect = "#<#{self.class.name} #{@changes.size} changes, #{breaking.size} breaking>"

    private

    def subject
      return "" unless @source

      @target ? "#{@source} vs #{@target}: " : "#{@source}: "
    end

    def headline
      count = "#{@changes.size} #{(@changes.size == 1) ? "change" : "changes"}"
      "#{subject}#{count}, #{breaking.any? ? "#{breaking.size} breaking" : "none breaking"}"
    end

    def section(title, changes)
      return [] if changes.empty?

      width = changes.map { |change| change.coordinate.length }.max
      ["", title, *changes.map { |change| "  #{change.coordinate.ljust(width)}  #{change.description}" }]
    end

    def change(coordinate, description, breaking: false)
      @changes << Change.new(coordinate:, description:, breaking:)
    end

    def compare(before, after)
      old_types = comparable_types(before)
      new_types = comparable_types(after)

      (old_types.keys - new_types.keys).each { |name| change(name, "removed", breaking: true) }
      (new_types.keys - old_types.keys).each { |name| change(name, "added #{kind(new_types[name])}") }
      (old_types.keys & new_types.keys).each { |name| compare_type(name, old_types[name], new_types[name]) }

      note_unnamed_drift(before, after)
    end

    def comparable_types(schema)
      schema.types.reject { |name, _| name.start_with?("__") || BUILT_IN.include?(name) }
    end

    def kind(type) = type.kind.name.downcase.tr("_", " ")

    def compare_type(name, old, new)
      # nothing below is comparable across kinds, and the kind change is
      # the only thing worth saying about it
      if old.kind.name != new.kind.name
        return change(name, "#{kind(old)} -> #{kind(new)}", breaking: true)
      end

      case new.kind.name
      when "OBJECT", "INTERFACE"
        compare_fields(name, old, new)
        compare_interfaces(name, old, new)
      when "INPUT_OBJECT" then compare_input_fields(name, old, new)
      when "ENUM" then compare_enum(name, old, new)
      when "UNION" then compare_union(name, old, new)
      end
    end

    def compare_fields(name, old, new)
      before = old.fields
      after = new.fields

      (before.keys - after.keys).each { |field| change("#{name}.#{field}", "removed", breaking: true) }
      (after.keys - before.keys).each do |field|
        change("#{name}.#{field}", "added: #{signature(after[field])}")
      end
      (before.keys & after.keys).each do |field|
        compare_field("#{name}.#{field}", before[field], after[field])
      end
    end

    def compare_field(coordinate, old, new)
      if signature(old) != signature(new)
        change(coordinate, "#{signature(old)} -> #{signature(new)}",
          breaking: breaks_output?(old.type, new.type))
      end
      compare_deprecation(coordinate, old, new)
      compare_arguments(coordinate, old.arguments, new.arguments)
    end

    def compare_arguments(coordinate, before, after)
      (before.keys - after.keys).each do |arg|
        change("#{coordinate}(#{arg}:)", "argument removed", breaking: true)
      end
      (after.keys - before.keys).each do |arg|
        change("#{coordinate}(#{arg}:)", "argument added: #{describe(after[arg])}",
          breaking: required?(after[arg]))
      end
      (before.keys & after.keys).each do |arg|
        compare_input(coordinate: "#{coordinate}(#{arg}:)", prefix: "argument ",
          old: before[arg], new: after[arg])
      end
    end

    # An input object's members are arguments, and break the same way — a
    # removed one fails a query that sends it, a newly required one fails a
    # query that doesn't.
    def compare_input_fields(name, old, new)
      before = old.arguments
      after = new.arguments

      (before.keys - after.keys).each { |field| change("#{name}.#{field}", "removed", breaking: true) }
      (after.keys - before.keys).each do |field|
        change("#{name}.#{field}", "added: #{describe(after[field])}", breaking: required?(after[field]))
      end
      (before.keys & after.keys).each do |field|
        compare_input(coordinate: "#{name}.#{field}", prefix: "", old: before[field], new: after[field])
      end
    end

    def compare_input(coordinate:, prefix:, old:, new:)
      if signature(old) != signature(new)
        # a default satisfies the new non-null, so the tightening reaches
        # no query
        breaking = breaks_input?(old.type, new.type) && !new.default_value?
        change(coordinate, "#{prefix}#{signature(old)} -> #{signature(new)}", breaking:)
      end
      compare_deprecation(coordinate, old, new)
    end

    def compare_enum(name, old, new)
      before = old.values
      after = new.values

      (before.keys - after.keys).each { |value| change("#{name}.#{value}", "enum value removed", breaking: true) }
      (after.keys - before.keys).each { |value| change("#{name}.#{value}", "enum value added") }
      (before.keys & after.keys).each { |value| compare_deprecation("#{name}.#{value}", before[value], after[value]) }
    end

    # A dropped member silently stops matching a `... on X` fragment, which
    # is the quiet half of this: the query still validates.
    def compare_union(name, old, new)
      before = old.possible_types.map(&:graphql_name)
      after = new.possible_types.map(&:graphql_name)

      (before - after).each { |member| change("#{name}.#{member}", "union member removed", breaking: true) }
      (after - before).each { |member| change("#{name}.#{member}", "union member added") }
    end

    def compare_interfaces(name, old, new)
      return unless old.respond_to?(:interfaces) && new.respond_to?(:interfaces)

      before = old.interfaces.map(&:graphql_name)
      after = new.interfaces.map(&:graphql_name)

      (before - after).each { |iface| change(name, "no longer implements #{iface}", breaking: true) }
      (after - before).each { |iface| change(name, "now implements #{iface}") }
    end

    def compare_deprecation(coordinate, old, new)
      return unless old.respond_to?(:deprecation_reason)

      was = old.deprecation_reason
      now = new.deprecation_reason
      return if was == now

      change(coordinate, now ? "deprecated: #{now}" : "no longer deprecated")
    end

    # The walk names what a client breaks on. A description, a directive
    # definition, an argument default moves the SDL without appearing
    # above — still drift, and a gate that went green on it would be worse
    # than one that admits it can't name it.
    def note_unnamed_drift(before, after)
      return unless @changes.empty?
      return if before.to_definition == after.to_definition

      change("(schema)", "changed in ways this summary doesn't name — compare the dumps")
    end

    def signature(member) = member.type.to_type_signature

    def describe(argument)
      "#{signature(argument)}#{" — required" if required?(argument)}"
    end

    def required?(argument) = argument.type.non_null? && !argument.default_value?

    # A signature split into its shape and where the `!`s sit: "[User!]!"
    # => ["[User]", [.., true(r), true(])]]. Comparing the two separately
    # is what lets nullability be read directionally.
    def shape(signature)
      bare = +""
      nullability = []
      signature.each_char do |char|
        if char == "!"
          nullability[-1] = true
        else
          bare << char
          nullability << false
        end
      end
      [bare, nullability]
    end

    # An output the client can no longer trust: a different type or list
    # depth, or a guarantee withdrawn — `String!` to `String` hands a
    # generated struct the nil it declared it wouldn't get.
    def breaks_output?(old, new)
      was, was_null = shape(old.to_type_signature)
      now, now_null = shape(new.to_type_signature)
      return true if was != now

      was_null.each_index.any? { |i| was_null[i] && !now_null[i] }
    end

    # An input the client can no longer satisfy: a different type, or a
    # guarantee demanded that wasn't demanded before.
    def breaks_input?(old, new)
      was, was_null = shape(old.to_type_signature)
      now, now_null = shape(new.to_type_signature)
      return true if was != now

      now_null.each_index.any? { |i| now_null[i] && !was_null[i] }
    end
  end
end
