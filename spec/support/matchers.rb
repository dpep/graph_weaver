# typed: ignore — rspec matcher protocol
# frozen_string_literal: true

require "graph_weaver/testing"

# Three matchers, for the three assertions this suite kept hand-rolling: the
# subgraph list nineteen times over, two helpers to rescue a refusal, and
# `errors.first&.code`.
#
#      expect(router).to have_fetched("accounts", "reviews")
#      expect { router.execute(query) }.to refuse_to_plan(:shadowed_key)
#      expect(response).to have_graphql_error(code: "THROTTLED")
#
# **Spec-local on purpose.** A published matcher is a name to learn and a
# failure message to keep, and nothing yet says which of these survive real
# use. This suite is the proving ground; promote the ones that earn it.
#
# Each exists for its failure message. The hand-rolled versions printed
# `expected: :a, got: :b` — the question you already knew you were asking —
# so these print the fetch list in order, the refusal that came instead, and
# the errors the response actually carried.
module GraphWeaverMatchers
  Unplannable = GraphWeaver::Testing::Unplannable

  # Which subgraphs the router has fetched since its last `reset_trace`, in
  # order — the rspec tag resets per example, so this asks about the code
  # path the example ran, however many queries that took:
  #
  #      router.execute("{ me { username reviews { body } } }")
  #      expect(router).to have_fetched("accounts", "reviews")
  #
  # Exactly those, in that order — a stitched query's fetch *order* is what's
  # worth pinning (a `@requires` chain is reviews, products, reviews). Name no
  # subgraph and it asks whether anything was fetched at all, which is how a
  # plan-time refusal says nothing ran: `expect(router).not_to have_fetched`.
  def have_fetched(*subgraphs) = HaveFetched.new(subgraphs)

  # A query the local router won't plan, by {Unplannable} category. The
  # category is the assertion: it carries the advice the message ends with,
  # and it's what a coverage report groups on.
  #
  #      expect { router.execute(query) }.to refuse_to_plan(:shadowed_key)
  #
  # `.with_detail` pins what stopped this particular query — a String, a
  # Regexp, or any matcher:
  #
  #      .with_detail(a_string_starting_with("Review.shipment"))
  #
  # Anything that isn't an `Unplannable` propagates rather than failing the
  # expectation: a NoMethodError in the planner is a bug, not a refusal, and
  # swallowing it into "didn't refuse" costs an afternoon.
  def refuse_to_plan(category) = RefuseToPlan.new(category)

  # One of the response's top-level GraphQL errors matched. Takes whatever
  # a GraphQL call handed back — a {GraphWeaver::Response}, a
  # {GraphWeaver::QueryError}, the raw `{"data" => …, "errors" => …}` a
  # transport or the router returns, or any array of
  # {GraphWeaver::GraphQLError} — so a path comes from `errors_at`, which
  # already knows how to read one:
  #
  #      expect(response).to have_graphql_error(code: "THROTTLED")
  #      expect(response.errors_at("person.email")).to have_graphql_error(code: "PRIVATE")
  #
  # `code:` and `message:` each take a String, a Regexp, or a matcher.
  def have_graphql_error(**attributes) = HaveGraphQLError.new(attributes)

  class << self
    # rspec's own rule for "does this value match this expectation", so a
    # String, a Regexp and `a_string_starting_with(…)` all work wherever
    # these matchers take a value — RSpec::Support::FuzzyMatcher for a
    # scalar, inlined because it is lazily required and so absent from the
    # RBIs tapioca generates. A matcher matches through Composable#===,
    # which delegates to its #matches?.
    def value_matches?(expected, actual)
      expected == actual || expected === actual
    end

    # rspec's own renderer: it surfaces a nested matcher's description
    # rather than its object address, and truncates a payload that would
    # otherwise fill the screen
    def render(value) = RSpec::Support::ObjectFormatter.format(value)

    # the actual, indented under the sentence that wanted it — prose and
    # payloads are unreadable inline, and a truncated one you can't paste
    # back into the spec is worse than a long one
    def below(sentence, actual) = "#{sentence}:\n  #{actual}"
  end

  class HaveFetched
    def initialize(expected)
      @expected = expected
    end

    def matches?(router)
      unless router.respond_to?(:trace)
        raise ArgumentError, "have_fetched reads a GraphWeaver::Testing::Router's #trace, and " \
          "#{router.class} has none — in a `graphql: :router` example the router is GraphWeaver.client"
      end

      @actual = router.trace.map { |fetch| fetch[:subgraph] }
      @expected.empty? ? !@actual.empty? : @actual == @expected
    end

    def failure_message
      return "expected the router to have fetched a subgraph, but it fetched none" if @expected.empty?

      "expected the router to have fetched #{GraphWeaverMatchers.render(@expected)}, " \
        "but it fetched #{GraphWeaverMatchers.render(@actual)}"
    end

    # with subgraphs named, the negation is "not that exact list" — say so,
    # because "never touched accounts" is the other natural reading
    def failure_message_when_negated
      if @expected.empty?
        return "expected the router to have fetched nothing, but it fetched #{GraphWeaverMatchers.render(@actual)}"
      end

      "expected the router not to have fetched #{GraphWeaverMatchers.render(@expected)}, " \
        "but that is exactly what it fetched"
    end

    def description
      @expected.empty? ? "have fetched a subgraph" : "have fetched #{GraphWeaverMatchers.render(@expected)}"
    end
  end

  class RefuseToPlan
    # a detail nobody asked about — distinct from nil, which would be an
    # assertion that the detail *is* nil
    UNSET = Object.new
    private_constant :UNSET

    def initialize(category)
      unless Unplannable::CATEGORIES.key?(category)
        raise ArgumentError, "#{category.inspect} is not a refusal category — " \
          "#{Unplannable::CATEGORIES.keys.map(&:inspect).join(", ")}"
      end

      @category = category
      @detail = UNSET
    end

    def with_detail(detail)
      @detail = detail
      self
    end

    def supports_block_expectations? = true

    # not `supports_value_expectations? = false`: rspec 3 answers that with a
    # deprecation warning at the end of the run and hands the value over
    # anyway, so the guard below is the one that lands
    def matches?(block)
      raise ArgumentError, "refuse_to_plan takes a block — expect { … }.to refuse_to_plan(…)" unless block.is_a?(Proc)

      @refusal = nil
      @result = block.call
      false
    rescue Unplannable => e
      @refusal = e
      e.category == @category && detail_matches?
    end

    def failure_message
      wanted = "expected the block to #{description}, but it"
      unless @refusal
        return GraphWeaverMatchers.below("#{wanted} planned, returning", GraphWeaverMatchers.render(@result))
      end
      if @refusal.category != @category
        return GraphWeaverMatchers.below("#{wanted} refused #{@refusal.category.inspect}", @refusal.detail)
      end

      GraphWeaverMatchers.below("#{wanted} refused with detail", @refusal.detail)
    end

    def failure_message_when_negated
      GraphWeaverMatchers.below("expected the block not to #{description}, but it refused", @refusal.detail)
    end

    def description
      detail = " with detail #{GraphWeaverMatchers.render(@detail)}" unless @detail.equal?(UNSET)
      "refuse to plan #{@category.inspect}#{detail}"
    end

    private

    def detail_matches?
      @detail.equal?(UNSET) || GraphWeaverMatchers.value_matches?(@detail, @refusal.detail)
    end
  end

  class HaveGraphQLError
    ATTRIBUTES = %i[code message].freeze

    def initialize(attributes)
      unknown = attributes.keys - ATTRIBUTES
      unless unknown.empty?
        raise ArgumentError, "have_graphql_error doesn't take #{unknown.map(&:inspect).join(", ")} — " \
          "#{ATTRIBUTES.map(&:inspect).join(", ")} (for a path, match on response.errors_at(\"…\"))"
      end

      if attributes.empty?
        raise ArgumentError, "have_graphql_error needs #{ATTRIBUTES.map(&:inspect).join(" or ")} to match on"
      end

      @attributes = attributes
    end

    def matches?(subject)
      @errors = errors_in(subject)
      @errors.any? do |error|
        @attributes.all? { |name, want| GraphWeaverMatchers.value_matches?(want, error.public_send(name)) }
      end
    end

    def failure_message = "expected #{description}, but #{found}"

    def failure_message_when_negated = "expected no #{description.delete_prefix("a ")}, but #{found}"

    def description
      pairs = @attributes.map { |name, want| "#{name} #{GraphWeaverMatchers.render(want)}" }
      "a GraphQL error with #{pairs.join(" and ")}"
    end

    private

    # the errors that were there, whole — `errors.first&.code` printed
    # "expected THROTTLED, got nil", which never said whether there were
    # errors at all
    def found
      return "there were none" if @errors.empty?

      GraphWeaverMatchers.below("the errors were", @errors.map(&:to_s).join("\n  "))
    end

    def errors_in(subject)
      return subject if subject.is_a?(Array)
      return subject.errors if subject.is_a?(GraphWeaver::ErrorFiltering)
      # the wire shape, which is what a transport and the router hand back
      return (subject["errors"] || []).map { |e| GraphWeaver::GraphQLError.from_h(e) } if subject.is_a?(Hash)

      raise ArgumentError, "have_graphql_error reads a GraphWeaver::Response, a QueryError, a raw " \
        "response Hash, or an array of GraphQLError — got #{subject.class}"
    end
  end
end

RSpec.configure { |config| config.include(GraphWeaverMatchers) }
