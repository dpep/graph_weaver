# typed: ignore — subgraph classes are invisible to srb
# frozen_string_literal: true

require "graph_weaver/testing"

# The matchers exist for their failure messages: the hand-rolled assertions
# they replace printed `expected: :a, got: :b` and left you re-running with a
# puts. So what each one prints when it fails is the thing pinned here — and
# it's what would have to hold if any of them is ever made public.
describe GraphWeaverMatchers do
  # matchers report through #failure_message, so read it rather than
  # asserting on the RSpec::Expectations::ExpectationNotMetError it wraps
  def failing(matcher, subject)
    expect(matcher.matches?(subject)).to be false
    matcher.failure_message
  end

  def passing(matcher, subject)
    expect(matcher.matches?(subject)).to be true
    matcher.failure_message_when_negated
  end

  describe "have_fetched" do
    subject(:router) do
      GraphWeaver::Testing::Router.new(
        supergraph: RouterGraph::SUPERGRAPH, subgraphs: RouterGraph::SUBGRAPHS,
      )
    end

    before { router.execute("{ me { username reviews { body } } }") }

    it "asks for exactly those subgraphs, in the order they were fetched" do
      expect(router).to have_fetched("accounts", "reviews")
      expect(router).not_to have_fetched("reviews", "accounts")
      expect(router).not_to have_fetched("accounts")
    end

    it "prints the fetch list it got, in order" do
      expect(failing(have_fetched("accounts", "products"), router))
        .to eq 'expected the router to have fetched ["accounts", "products"], but it fetched ["accounts", "reviews"]'
    end

    # the negated message says which reading is meant — "not that exact
    # list", not "never touched accounts"
    it "says the list matched exactly, when it shouldn't have" do
      expect(passing(have_fetched("accounts", "reviews"), router))
        .to eq 'expected the router not to have fetched ["accounts", "reviews"], but that is exactly what it fetched'
    end

    it "asks whether anything was fetched when no subgraph is named" do
      expect(router).to have_fetched
      expect(passing(have_fetched, router))
        .to eq 'expected the router to have fetched nothing, but it fetched ["accounts", "reviews"]'
    end

    it "is how a plan-time refusal says nothing ran" do
      expect { router.execute("{ me { id: username reviews { body } } }") }
        .to raise_error GraphWeaver::Testing::Unplannable
      expect(router).not_to have_fetched
      expect(failing(have_fetched, router))
        .to eq "expected the router to have fetched a subgraph, but it fetched none"
    end

    it "names what it wanted when handed something that isn't a router" do
      expect { expect(GraphWeaver::Testing::FakeClient.new(schema: Demo::Schema)).to have_fetched }
        .to raise_error(ArgumentError, /reads a GraphWeaver::Testing::Router's #trace.*graphql: :router/m)
    end

    it "describes itself for a one-liner" do
      expect(have_fetched("accounts").description).to eq 'have fetched ["accounts"]'
      expect(have_fetched.description).to eq "have fetched a subgraph"
    end
  end

  describe "refuse_to_plan" do
    subject(:router) do
      GraphWeaver::Testing::Router.new(
        supergraph: RouterGraph::SUPERGRAPH, subgraphs: RouterGraph::SUBGRAPHS,
      )
    end

    let(:shadowed) { -> { router.execute("{ me { id: username reviews { body } } }") } }

    it "matches the refusal's category, and optionally its detail" do
      expect(&shadowed).to refuse_to_plan(:shadowed_key)
      expect(&shadowed).to refuse_to_plan(:shadowed_key)
        .with_detail(a_string_starting_with("User.reviews is fetched"))
      expect(&shadowed).not_to refuse_to_plan(:no_key)
      expect(&shadowed).not_to refuse_to_plan(:shadowed_key).with_detail(/no key/)
    end

    # the detail prints whole, on its own line: it's the thing you paste
    # back into the spec, so a truncated one costs you another run
    it "prints the refusal it got instead" do
      expect(failing(refuse_to_plan(:no_key), shadowed))
        .to eq "expected the block to refuse to plan :no_key, but it refused :shadowed_key:\n" +
          %(  User.reviews is fetched on User's "id", and this selection aliases username as "id" over it)
    end

    it "prints the detail it got, and the matcher that wanted another" do
      expect(failing(refuse_to_plan(:shadowed_key).with_detail(a_string_including("no key")), shadowed))
        .to eq %(expected the block to refuse to plan :shadowed_key with detail a string including "no key", ) +
          "but it refused with detail:\n" +
          %(  User.reviews is fetched on User's "id", and this selection aliases username as "id" over it)
    end

    it "prints what the block answered when it planned after all" do
      expect(failing(refuse_to_plan(:no_key), -> { router.execute("{ me { username } }") }))
        .to eq "expected the block to refuse to plan :no_key, but it planned, returning:\n" \
          '  {"data" => {"me" => {"username" => "dpep"}}}'
    end

    it "says which refusal it got, when it shouldn't have" do
      expect(passing(refuse_to_plan(:shadowed_key), shadowed))
        .to start_with "expected the block not to refuse to plan :shadowed_key, but it refused:\n  User.reviews"
    end

    # rspec 3 only warns that the matcher wants a block, then hands it the
    # value anyway — so say it again, in the form the fix is written in
    it "says so rather than reading a value where a block belongs" do
      expect { expect(router).to refuse_to_plan(:no_key) }
        .to raise_error(ArgumentError, "refuse_to_plan takes a block — expect { … }.to refuse_to_plan(…)")
    end

    # a NoMethodError inside the planner is a bug, and swallowing it into
    # "didn't refuse" is how you spend an afternoon on it
    it "lets anything that isn't a refusal through" do
      expect { expect { raise "kaboom" }.to refuse_to_plan(:no_key) }.to raise_error "kaboom"
    end

    it "refuses a category that isn't one, naming the ones that are" do
      expect { refuse_to_plan(:typo) }
        .to raise_error(ArgumentError, /:typo is not a refusal category — :no_key, :abstract_boundary/)
    end
  end

  describe "have_graphql_error" do
    let(:response) do
      GraphWeaver::Response.new(data: nil, errors: [
        GraphWeaver::GraphQLError.from_h(
          "message" => "Throttled", "path" => %w[person email],
          "extensions" => { "code" => "THROTTLED" },
        ),
      ])
    end

    it "matches any of the response's errors, by code or message" do
      expect(response).to have_graphql_error(code: "THROTTLED")
      expect(response).to have_graphql_error(message: a_string_including("Throttl"))
      expect(response).to have_graphql_error(code: "THROTTLED", message: "Throttled")
      expect(response).not_to have_graphql_error(code: "PRIVATE")
    end

    # the path belongs to errors_at, which already knows how to read one —
    # so the matcher takes the errors it hands back
    it "reads an array of errors as readily as a response" do
      expect(response.errors_at("person")).to have_graphql_error(code: "THROTTLED")
      expect(response.errors_at("company")).not_to have_graphql_error(code: "THROTTLED")
    end

    it "reads a QueryError, which carries the same errors" do
      expect(GraphWeaver::QueryError.new(response.errors)).to have_graphql_error(code: "THROTTLED")
    end

    it "prints the errors that were there" do
      expect(failing(have_graphql_error(code: "PRIVATE"), response))
        .to eq "expected a GraphQL error with code \"PRIVATE\", but the errors were:\n" \
          "  Throttled (path: person.email) [THROTTLED]"
    end

    it "says so when there were none, rather than comparing against nil" do
      expect(failing(have_graphql_error(code: "PRIVATE"), GraphWeaver::Response.new(data: {})))
        .to eq 'expected a GraphQL error with code "PRIVATE", but there were none'
    end

    it "names the errors it found, when it shouldn't have found one" do
      expect(passing(have_graphql_error(code: "THROTTLED", message: "Throttled"), response))
        .to eq "expected no GraphQL error with code \"THROTTLED\" and message \"Throttled\", but " \
          "the errors were:\n  Throttled (path: person.email) [THROTTLED]"
    end

    it "points a path: at errors_at rather than growing a second way to spell one" do
      expect { have_graphql_error(path: "person") }
        .to raise_error(ArgumentError, /doesn't take :path — :code, :message \(for a path, match on response\.errors_at/)
      expect { have_graphql_error }.to raise_error(ArgumentError, /needs :code or :message to match on/)
      expect { expect("nope").to have_graphql_error(code: "X") }
        .to raise_error(ArgumentError, /reads a GraphWeaver::Response, a QueryError, or an array/)
    end
  end
end
